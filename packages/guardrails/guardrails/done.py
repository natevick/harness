import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from fnmatch import fnmatch
from pathlib import Path

from .goals import vague_clause, vague_prompt

KEYS = {"task", "done", "checks", "paths", "human", "tests"}
CHECK_KEYS = {"id", "run", "sabotage"}
PATH_KEYS = {"must_change", "must_not_change"}
REVIEW_FLAGS = ("observable", "testable", "scoped", "stopping_point")
TEST_DIRS = {"test", "tests", "__tests__", "spec", "specs"}
TEST_NAMES = ("test_*", "spec_*", "*_test", "*.test.*", "*.spec.*", "*_test.*", "*_spec.*")


def stood_down():
    return os.environ.get("GUARDRAILS_DONE_MEANS") == "off"


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

    must_change = []
    if "paths" in data:
        paths = data.get("paths")
        if not isinstance(paths, dict) or set(paths) - PATH_KEYS:
            problems.append("paths must contain only must_change and must_not_change")
        else:
            if "must_change" in paths:
                must_change = string_list(paths["must_change"], "paths.must_change", problems)
            if "must_not_change" in paths:
                string_list(paths["must_not_change"], "paths.must_not_change", problems)

    if "human" in data:
        string_list(data.get("human"), "human", problems)
    if "tests" in data:
        string_list(data.get("tests"), "tests", problems)

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
    for key in ("gaps", "spec_sha256") + REVIEW_FLAGS:
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
    return problems


def matches(pattern, path):
    if pattern.endswith("/**"):
        prefix = pattern[:-3].rstrip("/")
        return path == prefix or path.startswith(prefix + "/")
    return fnmatch(path, pattern) or fnmatch(os.path.basename(path), pattern)


def default_base(cwd):
    chosen = os.environ.get("GUARDRAILS_DONE_BASE")
    if chosen:
        return chosen
    for candidate in ("origin/main", "main"):
        probe = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--verify", "--quiet", candidate],
            capture_output=True,
        )
        if probe.returncode == 0:
            return candidate
    return "HEAD"


def changed_paths(cwd, base):
    collected = set()
    head = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--verify", "--quiet", "HEAD"],
        capture_output=True,
    )
    commands = [["git", "-C", cwd, "ls-files", "--others", "--exclude-standard"]]
    if head.returncode == 0:
        commands = [
            ["git", "-C", cwd, "diff", "--name-only", "%s...HEAD" % base],
            ["git", "-C", cwd, "diff", "--name-only", "HEAD"],
        ] + commands
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
    found, error = changed_paths(cwd, default_base(cwd))
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


def run_exit(command, cwd):
    completed = subprocess.run(command, shell=True, cwd=cwd, capture_output=True, text=True)
    return completed.returncode


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
    base = default_base(cwd)
    changed, error = changed_paths(cwd, base)
    if changed is None:
        return None, error
    patterns = data.get("tests")
    meta = meta_paths(cwd, spec)
    tests, product = [], []
    for path in sorted(changed):
        if path in meta:
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
            put(full, git_bytes(cwd, base, rel))
        reds = [run_exit(check["run"], tree) for check in checks]
        for full, current in saved:
            put(full, current)
        greens = [run_exit(check["run"], tree) for check in checks]
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
    if not tests and not explicit:
        return []
    checks = sabotage_checks(data)
    if not checks:
        return ["sabotage: changed tests have no check to run"]
    if not product:
        return ["sabotage: no non-test diff to revert"]
    try:
        reds, greens = cycle(cwd, product, base, checks)
    except OSError as error:
        return ["sabotage: could not stage a copy: %s" % error]
    problems = []
    for check, red, green in zip(checks, reds, greens):
        if red == 0:
            problems.append(
                "sabotage: check %s still passed after reverting %s" % (check["id"], ", ".join(product))
            )
        if green != 0:
            problems.append("sabotage: check %s failed after restore (exit %s)" % (check["id"], green))
    return problems


def execute(spec, cwd, data):
    return command_problems(cwd, data) + path_problems(cwd, data) + sabotage_problems(spec, cwd, data)


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


def finish_problems(cwd, spec=None):
    spec = spec or locate(cwd)
    problems, data = spec_problems(spec)
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


def main(argv):
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
