import ast
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from fnmatch import fnmatch
from pathlib import Path

from .goals import vague_clause, vague_prompt
from .live import hooks_live
from .protected import is_protected

KEYS = {"task", "done", "checks", "paths", "human", "tests", "author", "base"}
_TRUST = None
_ENFORCE = True
_REQUIRE_LIVE = True
_SESSION = ""
_CI_BASE = ""
CHECK_KEYS = {"id", "run", "sabotage", "reason"}
PATH_KEYS = {"must_change", "must_not_change", "allow_protected"}
REVIEW_FLAGS = ("observable", "testable", "scoped", "stopping_point")
TEST_DIRS = {"test", "tests", "__tests__", "spec", "specs"}
TEST_NAMES = ("test_*", "spec_*", "*_test", "*.test.*", "*.spec.*", "*_test.*", "*_spec.*")


def bind_trust(path, enforce_ownership=True):
    global _TRUST, _ENFORCE
    _TRUST = path
    _ENFORCE = bool(enforce_ownership)


def release_trust():
    global _TRUST, _ENFORCE, _REQUIRE_LIVE, _SESSION, _CI_BASE
    _TRUST = None
    _ENFORCE = True
    _REQUIRE_LIVE = True
    _SESSION = ""
    _CI_BASE = ""


def configure(trust=None, enforce_ownership=True, require_live=True, session=None, ci_base_ref=""):
    global _REQUIRE_LIVE, _SESSION, _CI_BASE
    if trust is None:
        release_trust()
    else:
        bind_trust(trust, enforce_ownership)
    _REQUIRE_LIVE = bool(require_live)
    _SESSION = session if session is not None else os.environ.get("GUARDRAILS_SESSION", "")
    _CI_BASE = ci_base_ref or ""


def active_trust_path():
    if _TRUST:
        return _TRUST
    return "/etc/harness/reviewers.json"


def locate(cwd):
    override = os.environ.get("GUARDRAILS_DONE_MEANS")
    if override and override != "off":
        if os.path.isabs(override):
            return override
        return os.path.join(cwd or ".", override)
    return os.path.join(cwd or ".", "done-means.json")


def review_path(spec):
    return os.path.splitext(spec)[0] + ".review.json"


def package_root():
    return Path(__file__).resolve().parents[1]


def meta_files(spec):
    return [spec, review_path(spec)]


def allowed_write(cwd, path):
    spec = os.path.abspath(locate(cwd))
    allowed = {os.path.normpath(item) for item in meta_files(spec)}
    return os.path.normpath(os.path.join(cwd or ".", path)) in allowed


def spec_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def missing_problems(spec):
    root = package_root()
    return [
        "no done-means spec at %s" % spec,
        "write it from %s" % (root / "templates" / "done-means.json"),
        "done must name an observable end state and checks must include a command",
        "then write %s using %s" % (
            review_path(spec),
            root / "templates" / "done-means-review.md",
        ),
        "set spec_sha256 from: python3 %s hash %s" % (root / "done_means.py", spec),
        "set reviewer to an id in /etc/harness/reviewers.json and signature to the ed25519 signature of the canonical review JSON with the signature field removed",
        "the trust file must be owned by root and not writable by this user; the private key stays off this machine",
        "a review with a false flag or a gap blocks; human entries are not checked",
    ]


def string_list(value, label, problems):
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        problems.append("%s entries must be non-empty strings" % label)
        return []
    return value


def text_problem(label, value, vague):
    if not isinstance(value, str) or not value.strip():
        return "%s is missing" % label
    if "REPLACE" in value:
        return "%s is still the template placeholder" % label
    reason = vague(value)
    if reason:
        return "%s is vague: %s" % (label, reason)
    return None


def base_sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None


def schema_problems(data):
    problems = []
    extra = set(data) - KEYS
    if extra:
        problems.append("unknown keys: %s" % ", ".join(sorted(extra)))

    for label, vague in (("task", vague_clause), ("done", vague_prompt)):
        reason = text_problem(label, data.get(label), vague)
        if reason:
            problems.append(reason)

    checks = data.get("checks")
    runnable = 0
    if not isinstance(checks, list):
        problems.append("checks is missing")
        checks = []
    for index, check in enumerate(checks):
        if not isinstance(check, dict):
            problems.append("checks[%d] is not an object" % index)
            continue
        unknown = set(check) - CHECK_KEYS
        if unknown:
            problems.append("checks[%d] has unknown keys: %s" % (index, ", ".join(sorted(unknown))))
        if not isinstance(check.get("id"), str) or not check.get("id", "").strip():
            problems.append("checks[%d] has no id" % index)
        run_problem = text_problem("checks[%d] run" % index, check.get("run"), vague_clause)
        if run_problem:
            problems.append(run_problem)
        else:
            runnable += 1
        if "sabotage" in check and not isinstance(check.get("sabotage"), bool):
            problems.append("checks[%d] sabotage is not a boolean" % index)
        if check.get("sabotage") is False:
            reason = check.get("reason")
            if not isinstance(reason, str) or not reason.strip():
                problems.append("checks[%d] sabotage opt-out needs a reason" % index)

    must_change = []
    if "paths" in data:
        paths = data.get("paths")
        if not isinstance(paths, dict) or set(paths) - PATH_KEYS:
            problems.append("paths must contain only must_change, must_not_change, and allow_protected")
        else:
            if "must_change" in paths:
                must_change = string_list(paths["must_change"], "paths.must_change", problems)
            if "must_not_change" in paths:
                string_list(paths["must_not_change"], "paths.must_not_change", problems)
            if "allow_protected" in paths:
                string_list(paths["allow_protected"], "paths.allow_protected", problems)

    if "human" in data:
        string_list(data.get("human"), "human", problems)
    if "tests" in data:
        string_list(data.get("tests"), "tests", problems)
    if "author" in data:
        reason = text_problem("author", data.get("author"), vague_clause)
        if reason:
            problems.append(reason)
    if not base_sha(data.get("base")):
        problems.append("base must be a 40-character lowercase hex SHA")

    if runnable == 0 and not must_change:
        problems.append("no runnable check")
    return problems


def review_problems(spec):
    path = review_path(spec)
    root = package_root()
    if not os.path.isfile(path):
        return [
            "no review at %s" % path,
            "judge observable, testable, scoped, and stopping_point using %s" % (
                root / "templates" / "done-means-review.md"
            ),
            "bind spec_sha256 to %s" % spec_hash(spec),
        ]
    data = load(path)
    if not isinstance(data, dict):
        return ["review at %s is not a JSON object" % path]

    problems = []
    for key in ("gaps", "spec_sha256", "reviewer", "signature") + REVIEW_FLAGS:
        if key not in data:
            problems.append("review missing %s" % key)
    if problems:
        return problems
    if data.get("spec_sha256") != spec_hash(spec):
        problems.append("review spec_sha256 does not match the spec")
    gaps = data.get("gaps")
    if not isinstance(gaps, list) or not all(isinstance(item, str) for item in gaps):
        problems.append("review gaps must be a list of strings")
        gaps = []
    for flag in REVIEW_FLAGS:
        if data.get(flag) is not True:
            problems.append("review failed: %s is not true" % flag)
    if gaps:
        problems.append("review failed: %s" % "; ".join(gaps))
    problems.extend(identity_problems(spec, data))
    return problems


def canonical_review(data):
    body = {key: value for key, value in data.items() if key != "signature"}
    return json.dumps(body, sort_keys=True, separators=(",", ":")).encode()


def load_trust():
    path = active_trust_path()
    if not os.path.isfile(path):
        return None
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    clean = {}
    for key, value in data.items():
        if isinstance(key, str) and isinstance(value, str) and value.strip():
            clean[key] = value
    return clean


def signature_ok(public_pem, message, signature_hex):
    try:
        signature = bytes.fromhex(signature_hex.strip())
    except ValueError:
        return False
    parent = tempfile.mkdtemp(prefix="done-means-sig-")
    try:
        public_path = os.path.join(parent, "pub.pem")
        message_path = os.path.join(parent, "msg")
        signature_path = os.path.join(parent, "sig")
        pem = public_pem if public_pem.endswith("\n") else public_pem + "\n"
        Path(public_path).write_text(pem)
        Path(message_path).write_bytes(message)
        Path(signature_path).write_bytes(signature)
        verified = subprocess.run(
            [
                "openssl", "pkeyutl", "-verify", "-pubin", "-inkey", public_path,
                "-rawin", "-in", message_path, "-sigfile", signature_path,
            ],
            capture_output=True,
        )
        return verified.returncode == 0
    except OSError:
        return False
    finally:
        shutil.rmtree(parent, ignore_errors=True)


def _walk_writable(path):
    uid = os.geteuid()
    current = path
    seen = set()
    while current and current not in seen:
        seen.add(current)
        try:
            info = os.stat(current)
        except OSError:
            return True
        if info.st_uid == uid or os.access(current, os.W_OK):
            return True
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return True
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    return False


def trust_writable(path):
    try:
        real = os.path.realpath(path)
    except OSError:
        return True
    if _walk_writable(path) or (real != path and _walk_writable(real)):
        return True
    return False


def identity_problems(spec, data):
    reviewer = data.get("reviewer")
    if not isinstance(reviewer, str) or not reviewer.strip():
        return ["review missing reviewer"]
    reviewer = reviewer.strip()
    signature = data.get("signature")
    if not isinstance(signature, str) or not signature.strip():
        return ["review missing signature"]
    path = active_trust_path()
    if not os.path.isfile(path):
        return ["no reviewer trust store at %s" % path]
    if _ENFORCE and trust_writable(path):
        return ["trust store is writable by this user"]
    trust = load_trust()
    if trust is None:
        return ["no reviewer trust store at %s" % path]
    pem = trust.get(reviewer)
    if not pem:
        return ["reviewer %s is not in the trust store" % reviewer]
    if not signature_ok(pem, canonical_review(data), signature):
        return ["review signature is not valid"]
    return []


def matches(pattern, path):
    if pattern.endswith("/**"):
        prefix = pattern[:-3].rstrip("/")
        return path == prefix or path.startswith(prefix + "/")
    return fnmatch(path, pattern) or fnmatch(os.path.basename(path), pattern)


def resolve_base(cwd, data):
    raw = data.get("base") if isinstance(data, dict) else None
    if not base_sha(raw):
        return None, "base must be a 40-character lowercase hex SHA"
    base = raw
    if _CI_BASE:
        ref = "origin/%s" % _CI_BASE
        merged = subprocess.run(
            ["git", "-C", cwd, "merge-base", ref, "HEAD"],
            capture_output=True,
            text=True,
        )
        if merged.returncode != 0:
            return None, "base: cannot merge-base %s with HEAD" % ref
        expected = merged.stdout.strip()
        if base != expected:
            return None, "base is not the merge-base with %s" % ref
        return base, ""
    ancestor = subprocess.run(
        ["git", "-C", cwd, "merge-base", "--is-ancestor", base, "HEAD"],
        capture_output=True,
    )
    if ancestor.returncode != 0:
        return None, "base is not an ancestor of HEAD"
    return base, ""


def default_base(cwd, data=None):
    base, _error = resolve_base(cwd, data or {})
    return base or ""


def override_missing(cwd):
    raw = os.environ.get("GUARDRAILS_DONE_MEANS")
    if not raw or raw == "off":
        return False
    return not os.path.isfile(locate(cwd))


def _ref_exists(cwd, ref):
    probe = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--verify", "--quiet", ref],
        capture_output=True,
    )
    return probe.returncode == 0


def spec_removed(cwd):
    name = os.path.basename(locate(cwd))
    if os.path.isfile(os.path.join(cwd or ".", name)):
        return False
    present = subprocess.run(
        ["git", "-C", cwd, "cat-file", "-e", "HEAD:%s" % name],
        capture_output=True,
    )
    if present.returncode == 0:
        return True
    for ref in ("origin/main", "main"):
        if not _ref_exists(cwd, ref):
            continue
        log = subprocess.run(
            ["git", "-C", cwd, "log", "--diff-filter=D", "--pretty=%H", "%s..HEAD" % ref, "--", name],
            capture_output=True,
            text=True,
        )
        return log.returncode == 0 and bool(log.stdout.strip())
    return False


def changed_paths(cwd, base, untracked=True):
    collected = set()
    head = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--verify", "--quiet", "HEAD"],
        capture_output=True,
    )
    commands = []
    if head.returncode == 0:
        commands = [
            ["git", "-C", cwd, "diff", "--name-only", "%s...HEAD" % base],
            ["git", "-C", cwd, "diff", "--name-only", "HEAD"],
        ]
    if untracked:
        commands.append(["git", "-C", cwd, "ls-files", "--others", "--exclude-standard"])
    if not commands:
        return set(), ""
    for command in commands:
        probe = subprocess.run(command, capture_output=True, text=True)
        if probe.returncode != 0:
            return None, (probe.stderr or "git failed").strip()
        for line in probe.stdout.splitlines():
            if line.strip():
                collected.add(line.strip())
    return collected, ""


def path_problems(cwd, data):
    paths = data.get("paths") or {}
    must = paths.get("must_change") or []
    must_not = paths.get("must_not_change") or []
    if not must and not must_not:
        return []
    found, error = changed_paths(cwd, default_base(cwd, data))
    if found is None:
        return ["paths: %s" % error]
    problems = []
    for pattern in must:
        if not any(matches(pattern, path) for path in found):
            problems.append("paths: %s did not change" % pattern)
    for pattern in must_not:
        hit = [path for path in found if matches(pattern, path)]
        if hit:
            problems.append("paths: %s changed (%s)" % (pattern, ", ".join(sorted(hit))))
    return problems


def run_result(command, cwd):
    completed = subprocess.run(
        command,
        shell=True,
        cwd=cwd,
        capture_output=True,
        text=True,
        errors="replace",
    )
    return completed.returncode, (completed.stdout or "") + (completed.stderr or "")


def run_exit(command, cwd):
    code, _output = run_result(command, cwd)
    return code


DOC_BASENAMES = {
    "changelog", "changelog.md", "changelog.rst", "license", "licence", "copying",
    "readme", "readme.md", "readme.rst", "version", "version.txt",
}


def final_exception(output):
    found = None
    for line in (output or "").splitlines():
        stripped = line.strip()
        marked = re.match(r"^E\s+([A-Za-z_]\w*)", stripped)
        if marked:
            found = marked.group(1)
            continue
        plain = re.match(r"^([A-Za-z_]\w*(?:Error|Exception))\b", stripped)
        if plain:
            found = plain.group(1)
    return found


def assertion_red(code, output):
    if code == 0:
        return False
    kind = final_exception(output)
    if kind is None:
        return True
    return kind in ("AssertionError", "assert")


def is_doc_path(path):
    parts = [part for part in path.replace("\\", "/").split("/") if part and part != "."]
    if not parts:
        return False
    if parts[0].lower() in {"doc", "docs"}:
        return True
    base = parts[-1].lower()
    if base.startswith("changelog"):
        return True
    return base in DOC_BASENAMES


def is_noise_path(path):
    parts = path.replace("\\", "/").split("/")
    if "__pycache__" in parts:
        return True
    if parts and parts[-1].endswith(".pyc"):
        return True
    return bool(parts) and parts[-1] == "done-means.sabotage.json"


def command_problems(cwd, data):
    problems = []
    for check in data["checks"]:
        code = run_exit(check["run"], cwd)
        if code != 0:
            problems.append("check %s exited %s" % (check["id"], code))
    return problems


def is_test_path(path, patterns):
    if patterns is not None:
        return any(matches(pattern, path) for pattern in patterns)
    dirs, base = path.split("/")[:-1], path.split("/")[-1]
    return any(part in TEST_DIRS for part in dirs) or any(fnmatch(base, name) for name in TEST_NAMES)


def meta_paths(cwd, spec):
    return {os.path.relpath(os.path.abspath(path), cwd) for path in meta_files(spec)}


def sabotage_checks(data):
    return [check for check in data["checks"] if check.get("sabotage", True)]


def split_changes(cwd, spec, data):
    base = default_base(cwd, data)
    changed, error = changed_paths(cwd, base)
    if changed is None:
        return None, error
    patterns = data.get("tests")
    meta = meta_paths(cwd, spec)
    tests, product = [], []
    for path in sorted(changed):
        if path in meta or is_protected(cwd, path) or is_noise_path(path):
            continue
        if is_test_path(path, patterns):
            tests.append(path)
        else:
            product.append(path)
    return (base, tests, product), ""


def git_bytes(cwd, base, rel):
    probe = subprocess.run(
        ["git", "-C", cwd, "show", "%s:%s" % (base, rel)],
        capture_output=True,
    )
    if probe.returncode != 0:
        return None
    return probe.stdout


def put(full, content):
    if os.path.lexists(full) and not os.path.isdir(full):
        os.remove(full)
    if content is None:
        return
    parent = os.path.dirname(full)
    if parent:
        os.makedirs(parent, exist_ok=True)
    Path(full).write_bytes(content)


def mirror_worktree(src, dst):
    present = set()
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [name for name in dirnames if name != ".git"]
        rel_dir = os.path.relpath(dirpath, src)
        if rel_dir == ".":
            rel_dir = ""
        for name in filenames:
            rel = os.path.join(rel_dir, name) if rel_dir else name
            present.add(rel)
            target = os.path.join(dst, rel)
            folder = os.path.dirname(target)
            if folder:
                os.makedirs(folder, exist_ok=True)
            if os.path.lexists(target) and not os.path.isdir(target):
                os.remove(target)
            shutil.copyfile(os.path.join(dirpath, name), target)
    for dirpath, dirnames, filenames in os.walk(dst):
        dirnames[:] = [name for name in dirnames if name != ".git"]
        rel_dir = os.path.relpath(dirpath, dst)
        if rel_dir == ".":
            rel_dir = ""
        for name in list(filenames):
            if name == ".git":
                continue
            rel = os.path.join(rel_dir, name) if rel_dir else name
            if rel not in present:
                os.remove(os.path.join(dirpath, name))


def fill_tree(cwd, tree):
    head = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--verify", "--quiet", "HEAD"],
        capture_output=True,
    )
    if head.returncode == 0:
        added = subprocess.run(
            ["git", "-C", cwd, "worktree", "add", "--detach", "--quiet", tree, "HEAD"],
            capture_output=True,
            text=True,
        )
        if added.returncode == 0:
            mirror_worktree(cwd, tree)
            return True
        subprocess.run(
            ["git", "-C", cwd, "worktree", "remove", "--force", tree],
            capture_output=True,
        )
    if os.path.isdir(tree):
        shutil.rmtree(tree)
    shutil.copytree(cwd, tree, symlinks=False, ignore=shutil.ignore_patterns(".git"))
    return False


def _function_nodes(tree):
    found = {}
    for node in getattr(tree, "body", []):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            found[node.name] = node
        elif isinstance(node, ast.ClassDef):
            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    found["%s.%s" % (node.name, item.name)] = item
    return found


def _stub_function(node):
    node.body = [ast.Return(value=ast.Name(id="_SABOTAGE", ctx=ast.Load()))]
    node.decorator_list = []
    return node


def stub_python_sources(current, base_bytes):
    try:
        current_tree = ast.parse(current.decode("utf-8"))
    except (UnicodeError, SyntaxError, ValueError):
        return None
    base_dump = {}
    if base_bytes is not None:
        try:
            base_dump = {
                name: ast.dump(node)
                for name, node in _function_nodes(ast.parse(base_bytes.decode("utf-8"))).items()
            }
        except (UnicodeError, SyntaxError, ValueError):
            base_dump = {}
    changed = False
    for name, node in _function_nodes(current_tree).items():
        if base_bytes is None or ast.dump(node) != base_dump.get(name):
            _stub_function(node)
            changed = True
    if not changed:
        return current
    current_tree.body.insert(0, ast.parse("_SABOTAGE = object()").body[0])
    try:
        return ast.unparse(ast.fix_missing_locations(current_tree)).encode()
    except (ValueError, TypeError):
        return None


def cycle(cwd, product, base, checks):
    parent = tempfile.mkdtemp(prefix="done-means-")
    tree = os.path.join(parent, "tree")
    linked = False
    try:
        linked = fill_tree(cwd, tree)
        saved = []
        for rel in product:
            full = os.path.join(tree, rel)
            current = Path(full).read_bytes() if os.path.isfile(full) else None
            saved.append((full, current))
            base_bytes = git_bytes(cwd, base, rel)
            if rel.endswith(".py") and current is not None:
                put(full, stub_python_sources(current, base_bytes) or current)
            else:
                put(full, base_bytes)
        reds = [run_result(check["run"], tree) for check in checks]
        for full, current in saved:
            put(full, current)
        greens = [run_result(check["run"], tree) for check in checks]
        return reds, greens
    finally:
        if linked:
            subprocess.run(
                ["git", "-C", cwd, "worktree", "remove", "--force", tree],
                capture_output=True,
            )
        shutil.rmtree(parent, ignore_errors=True)


def sabotage_problems(spec, cwd, data):
    explicit = any(check.get("sabotage") is True for check in data["checks"])
    split, error = split_changes(cwd, spec, data)
    if split is None:
        return ["sabotage: %s" % error] if explicit else []
    base, tests, product = split
    code = [path for path in product if not is_doc_path(path)]
    checks = sabotage_checks(data)
    if not checks:
        return []
    if code and not tests:
        return ["sabotage: non-doc change has no test diff (%s)" % ", ".join(code)]
    if not tests and not explicit:
        return []
    if not product:
        return ["sabotage: no non-test diff to revert"]
    try:
        reds, greens = cycle(cwd, product, base, checks)
    except OSError as error:
        return ["sabotage: could not stage a copy: %s" % error]
    problems = []
    reverted = ", ".join(product)
    for check, red, green in zip(checks, reds, greens):
        red_code, red_out = red
        green_code, _green_out = green
        if red_code == 0:
            problems.append(
                "sabotage: check %s still passed after reverting %s" % (check["id"], reverted)
            )
        elif not assertion_red(red_code, red_out):
            problems.append(
                "sabotage: check %s failed by crash or import, not an assertion, after reverting %s"
                % (check["id"], reverted)
            )
        if green_code != 0:
            problems.append("sabotage: check %s failed after restore (exit %s)" % (check["id"], green_code))
    return problems


def allowed_protected(data):
    if not isinstance(data, dict):
        return set()
    paths = data.get("paths") or {}
    if not isinstance(paths, dict):
        return set()
    listed = paths.get("allow_protected") or []
    if not isinstance(listed, list):
        return set()
    return {item for item in listed if isinstance(item, str)}


def protected_problems(cwd, data=None):
    found, error = changed_paths(cwd, default_base(cwd, data), untracked=False)
    if found is None:
        return ["protected: %s" % error]
    allowed = allowed_protected(data)
    hits = [path for path in sorted(found) if is_protected(cwd, path) and path not in allowed]
    if not hits:
        return []
    return ["protected: %s changed" % ", ".join(hits)]


def execute(spec, cwd, data):
    _base, error = resolve_base(cwd, data)
    if error:
        return [error]
    return (
        command_problems(cwd, data)
        + path_problems(cwd, data)
        + protected_problems(cwd, data)
        + sabotage_problems(spec, cwd, data)
    )


def spec_problems(spec):
    if not os.path.isfile(spec):
        return missing_problems(spec), None
    data = load(spec)
    if data is None:
        return ["%s is not JSON" % spec], None
    return schema_problems(data), data


def start_problems(cwd, spec=None):
    spec = spec or locate(cwd)
    problems, data = spec_problems(spec)
    return problems or review_problems(spec), data


def finish_problems(cwd, spec=None, session=None):
    spec = spec or locate(cwd)
    who = _SESSION if session is None else session
    problems, data = spec_problems(spec)
    if _REQUIRE_LIVE and not hooks_live(who):
        return ["hooks not live for this session"], data
    if problems:
        return problems, data
    return review_problems(spec) + execute(spec, cwd, data), data


def format_block(problems):
    return "DONE-MEANS GATE\n" + "\n".join(problems)


def report(problems, data):
    if problems:
        print(format_block(problems))
        return 1
    print("ok")
    human = (data or {}).get("human")
    if human:
        print("UNENFORCED")
        for item in human:
            print(item)
    return 0


USAGE = """usage: done_means.py validate|run|hash [spec-or-dir]

validate   schema, vagueness, and a passing review
run        validate, then checks, paths, and a live revert of the non-test diff
hash       print the spec sha256 a review must cite
"""


def main(argv, trust=None, enforce_ownership=True, require_live=True, ci_base_ref=""):
    configure(
        trust=trust,
        enforce_ownership=enforce_ownership,
        require_live=require_live,
        ci_base_ref=ci_base_ref,
    )
    try:
        return _main(argv)
    finally:
        release_trust()


def _main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(USAGE.strip())
        return 0 if len(argv) > 1 else 2
    command = argv[1]
    explicit = argv[2] if len(argv) > 2 else None
    cwd = os.getcwd()
    if explicit and os.path.isdir(explicit):
        cwd = os.path.abspath(explicit)
        spec = locate(cwd)
    elif explicit:
        spec = os.path.abspath(explicit)
        cwd = os.path.dirname(spec)
    else:
        spec = locate(cwd)
    if command == "hash":
        if not os.path.isfile(spec):
            print("no done-means spec at %s" % spec)
            return 1
        print(spec_hash(spec))
        return 0
    if command == "validate":
        problems, data = start_problems(cwd, spec)
        return report(problems, data)
    if command == "run":
        problems, data = finish_problems(cwd, spec)
        return report(problems, data)
    print(USAGE.strip())
    return 2
