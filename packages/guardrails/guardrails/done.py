import hashlib
import json
import os
import subprocess
from datetime import datetime, timezone
from fnmatch import fnmatch
from pathlib import Path

from .goals import vague_clause, vague_prompt

KEYS = {"task", "done", "checks", "paths", "ci", "human", "tests"}
CHECK_KEYS = {"id", "run", "fail_first", "sabotage"}
PATH_KEYS = {"must_change", "must_not_change"}
REVIEW_FLAGS = ("observable", "testable", "scoped", "stopping_point")


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


def receipt_path(spec):
    return os.path.splitext(spec)[0] + ".receipt.jsonl"


def sabotage_path(spec):
    return os.path.splitext(spec)[0] + ".sabotage.json"


def package_root():
    return Path(__file__).resolve().parents[1]


def allowed_write(cwd, path):
    spec = os.path.abspath(locate(cwd))
    allowed = {
        os.path.normpath(spec),
        os.path.normpath(review_path(spec)),
        os.path.normpath(receipt_path(spec)),
        os.path.normpath(sabotage_path(spec)),
    }
    candidate = path if os.path.isabs(path) else os.path.join(cwd or ".", path)
    return os.path.normpath(candidate) in allowed


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
        "a fail verdict blocks; human entries are not checked",
    ]


def string_list(value, label, problems):
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        problems.append("%s entries must be non-empty strings" % label)
        return []
    return value


def schema_problems(data):
    problems = []
    extra = set(data) - KEYS
    if extra:
        problems.append("unknown keys: %s" % ", ".join(sorted(extra)))

    task = data.get("task")
    if not isinstance(task, str) or not task.strip():
        problems.append("task is missing")
    elif task.strip() == "REPLACE":
        problems.append("task is still the template placeholder")
    elif vague_clause(task):
        problems.append("task is vague: %s" % vague_clause(task))

    done = data.get("done")
    if not isinstance(done, str) or not done.strip():
        problems.append("done is missing")
    elif "REPLACE" in done:
        problems.append("done is still the template placeholder")
    else:
        reason = vague_prompt(done)
        if reason:
            problems.append("done is vague: %s" % reason)

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
        run = check.get("run")
        if not isinstance(run, str) or not run.strip():
            problems.append("checks[%d] has no run command" % index)
        else:
            reason = vague_clause(run)
            if reason:
                problems.append("checks[%d] run is vague: %s" % (index, reason))
            elif "REPLACE" in run:
                problems.append("checks[%d] run is still the template placeholder" % index)
            else:
                runnable += 1
        if "fail_first" in check and not isinstance(check.get("fail_first"), bool):
            problems.append("checks[%d] fail_first is not a boolean" % index)
        if "sabotage" in check and not isinstance(check.get("sabotage"), bool):
            problems.append("checks[%d] sabotage is not a boolean" % index)

    must_change = []
    paths = data.get("paths", {})
    if "paths" in data:
        if not isinstance(paths, dict) or set(paths) - PATH_KEYS:
            problems.append("paths must contain only must_change and must_not_change")
            paths = {}
        else:
            for key in ("must_change", "must_not_change"):
                if key in paths:
                    string_list(paths.get(key), "paths.%s" % key, problems)
            must_change = paths.get("must_change") or []
            if not isinstance(must_change, list):
                must_change = []

    ci = data.get("ci", [])
    if "ci" in data:
        ci = string_list(ci, "ci", problems)

    if "human" in data:
        string_list(data.get("human"), "human", problems)

    if "tests" in data:
        string_list(data.get("tests"), "tests", problems)

    if runnable == 0 and not must_change and not ci:
        problems.append("no runnable check")
    return problems


def review_problems(spec):
    path = review_path(spec)
    root = package_root()
    if not os.path.isfile(path):
        return [
            "no review verdict at %s" % path,
            "judge observable, testable, scoped, and stopping_point using %s" % (
                root / "templates" / "done-means-review.md"
            ),
            "bind spec_sha256 to %s" % spec_hash(spec),
        ]
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return ["review verdict at %s is not JSON" % path]
    if not isinstance(data, dict):
        return ["review verdict at %s is not a JSON object" % path]

    problems = []
    for key in ("verdict", "gaps", "spec_sha256") + REVIEW_FLAGS:
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
        if not isinstance(data.get(flag), bool):
            problems.append("review %s is not a boolean" % flag)
    verdict = data.get("verdict")
    if verdict not in ("pass", "fail"):
        problems.append("review verdict must be pass or fail")
    elif verdict == "fail":
        listed = "; ".join(gaps) if gaps else "no gaps listed"
        problems.append("review failed: %s" % listed)
    elif verdict == "pass":
        for flag in REVIEW_FLAGS:
            if data.get(flag) is False:
                problems.append("review says pass but %s is false" % flag)
        if gaps:
            problems.append("review says pass but lists gaps")
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
    if not isinstance(must, list):
        must = []
    if not isinstance(must_not, list):
        must_not = []
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


def ci_problems(cwd, data):
    names = data.get("ci") or []
    if not isinstance(names, list) or not names:
        return []
    try:
        probe = subprocess.run(
            ["gh", "pr", "checks", "--json", "name,state"],
            cwd=cwd,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return ["ci: gh is not on PATH"]
    if probe.returncode != 0:
        detail = (probe.stderr or probe.stdout or "gh failed").strip()
        return ["ci: gh pr checks failed: %s" % detail]
    try:
        rows = json.loads(probe.stdout or "[]")
    except ValueError:
        return ["ci: gh pr checks did not return JSON"]
    if not isinstance(rows, list):
        return ["ci: gh pr checks did not return a list"]
    problems = []
    for wanted in names:
        hits = [
            row for row in rows
            if isinstance(row, dict) and (
                row.get("name") == wanted
                or str(row.get("name") or "").startswith(wanted + " (")
            )
        ]
        if not hits:
            problems.append("ci: %s is not reported" % wanted)
        elif any(row.get("state") != "SUCCESS" for row in hits):
            problems.append("ci: %s is not SUCCESS" % wanted)
    return problems


def read_receipt(path):
    if not os.path.isfile(path):
        return []
    rows = []
    for line in Path(path).read_text().splitlines():
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            rows.append(parsed)
    return rows


def append_receipt(path, ident, command, code):
    row = {
        "id": ident,
        "run": command,
        "exit": code,
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    with open(path, "a") as handle:
        handle.write(json.dumps(row) + "\n")


def command_problems(spec, cwd, data):
    prior = read_receipt(receipt_path(spec))
    problems = []
    for check in data.get("checks") or []:
        command = check["run"]
        ident = check["id"]
        completed = subprocess.run(command, shell=True, cwd=cwd, capture_output=True, text=True)
        append_receipt(receipt_path(spec), ident, command, completed.returncode)
        if completed.returncode != 0:
            problems.append("check %s exited %s" % (ident, completed.returncode))
            continue
        if check.get("fail_first"):
            earlier = [
                row for row in prior
                if row.get("id") == ident and row.get("run") == command and row.get("exit") != 0
            ]
            if not earlier:
                problems.append("check %s passed but has no recorded failing run" % ident)
    return problems


TEST_DIRS = {"test", "tests", "__tests__", "spec", "specs"}
OUTPUT_CAP = 4000
SABOTAGE_METHOD = "revert-nontest-diff"


def is_test_path(path, patterns):
    if patterns is not None:
        return any(matches(pattern, path) for pattern in patterns)
    parts = path.split("/")
    if any(part in TEST_DIRS for part in parts[:-1]):
        return True
    base = parts[-1]
    return (
        base.startswith("test_")
        or base.startswith("spec_")
        or base.endswith("_test")
        or ".test." in base
        or ".spec." in base
        or "_test." in base
        or "_spec." in base
    )


def meta_paths(cwd, spec):
    found = set()
    for path in (spec, review_path(spec), receipt_path(spec), sabotage_path(spec)):
        found.add(os.path.relpath(os.path.abspath(path), cwd))
    return found


def sabotage_checks(data):
    return [check for check in data.get("checks") or [] if check.get("sabotage", True)]


def split_changes(cwd, spec, data):
    base = default_base(cwd)
    changed, error = changed_paths(cwd, base)
    if changed is None:
        return None, error
    patterns = data.get("tests") if isinstance(data.get("tests"), list) else None
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


def fix_sha(cwd, product):
    digest = hashlib.sha256()
    for rel in product:
        digest.update(rel.encode())
        digest.update(b"\0")
        full = os.path.join(cwd, rel)
        if os.path.isfile(full):
            digest.update(Path(full).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def git_bytes(cwd, base, rel):
    probe = subprocess.run(
        ["git", "-C", cwd, "show", "%s:%s" % (base, rel)],
        capture_output=True,
    )
    if probe.returncode != 0:
        return None
    return probe.stdout


def run_captured(command, cwd):
    completed = subprocess.run(command, shell=True, cwd=cwd, capture_output=True, text=True)
    output = (completed.stdout or "") + (completed.stderr or "")
    if len(output) > OUTPUT_CAP:
        output = output[:OUTPUT_CAP] + "\n...[truncated]"
    if not output.strip():
        output = "exit %s with no output" % completed.returncode
    return completed.returncode, output


def cycle(cwd, product, base, checks):
    saved = []
    try:
        for rel in product:
            full = os.path.join(cwd, rel)
            current = Path(full).read_bytes() if os.path.isfile(full) else None
            saved.append((full, current))
            previous = git_bytes(cwd, base, rel)
            if previous is None:
                if os.path.isfile(full):
                    os.remove(full)
            else:
                parent = os.path.dirname(full)
                if parent:
                    os.makedirs(parent, exist_ok=True)
                Path(full).write_bytes(previous)
        reds = [run_captured(check["run"], cwd) for check in checks]
    finally:
        for full, current in saved:
            if current is None:
                if os.path.isfile(full):
                    os.remove(full)
            else:
                parent = os.path.dirname(full)
                if parent:
                    os.makedirs(parent, exist_ok=True)
                Path(full).write_bytes(current)
    greens = [run_captured(check["run"], cwd) for check in checks]
    rows = []
    for check, red, green in zip(checks, reds, greens):
        rows.append({
            "id": check["id"],
            "run": check["run"],
            "red": {"exit": red[0], "output": red[1]},
            "green": {"exit": green[0], "output": green[1]},
        })
    return rows


def evidence_problems(evidence, checks, product, digest):
    problems = []
    if evidence.get("method") != SABOTAGE_METHOD:
        problems.append("sabotage: method must be revert-nontest-diff")
    if evidence.get("reverted") != product:
        problems.append("sabotage: reverted files do not match the non-test diff")
    if evidence.get("fix_sha256") != digest:
        problems.append("sabotage: fix_sha256 does not match the non-test diff")
    rows = evidence.get("checks")
    if not isinstance(rows, list) or len(rows) != len(checks):
        problems.append("sabotage: evidence checks do not match the spec")
        return problems
    for check, row in zip(checks, rows):
        if not isinstance(row, dict) or row.get("id") != check["id"] or row.get("run") != check["run"]:
            problems.append("sabotage: evidence is not for check %s" % check["id"])
            continue
        red = row.get("red") if isinstance(row.get("red"), dict) else {}
        green = row.get("green") if isinstance(row.get("green"), dict) else {}
        red_exit = red.get("exit")
        if type(red_exit) is not int or red_exit == 0:
            problems.append("sabotage: check %s has no failing red run" % check["id"])
        elif not isinstance(red.get("output"), str) or not red.get("output").strip():
            problems.append("sabotage: check %s red output is empty" % check["id"])
        green_exit = green.get("exit")
        if type(green_exit) is not int or green_exit != 0:
            problems.append("sabotage: check %s did not pass after restore" % check["id"])
        elif not isinstance(green.get("output"), str):
            problems.append("sabotage: check %s green output is missing" % check["id"])
    return problems


def sabotage_scope(cwd, spec, data):
    split, error = split_changes(cwd, spec, data)
    if split is None:
        return None, error
    base, tests, product = split
    checks = sabotage_checks(data)
    explicit = any(check.get("sabotage") is True for check in data.get("checks") or [])
    if not tests and not explicit:
        return ("skip",), ""
    if not checks:
        return ("block", "sabotage: changed tests have no check to run"), ""
    if not product:
        return ("block", "sabotage: no non-test diff to revert"), ""
    return ("run", base, product, checks), ""


def record_sabotage(spec, cwd, data):
    scope, error = sabotage_scope(cwd, spec, data)
    if scope is None:
        return ["sabotage: %s" % error]
    if scope[0] == "skip":
        return ["sabotage: no changed test to prove"]
    if scope[0] == "block":
        return [scope[1]]
    _kind, base, product, checks = scope
    rows = cycle(cwd, product, base, checks)
    problems = []
    for row in rows:
        if row["red"]["exit"] == 0:
            problems.append(
                "sabotage: check %s still passed after reverting %s"
                % (row["id"], ", ".join(product))
            )
        if row["green"]["exit"] != 0:
            problems.append(
                "sabotage: check %s failed after restore (exit %s)"
                % (row["id"], row["green"]["exit"])
            )
    if problems:
        return problems
    payload = {
        "method": SABOTAGE_METHOD,
        "base": base,
        "reverted": product,
        "fix_sha256": fix_sha(cwd, product),
        "checks": rows,
    }
    Path(sabotage_path(spec)).write_text(json.dumps(payload, indent=2) + "\n")
    return []


def sabotage_problems(spec, cwd, data):
    scope, error = sabotage_scope(cwd, spec, data)
    if scope is None:
        explicit = any(check.get("sabotage") is True for check in data.get("checks") or [])
        if not explicit:
            return []
        return ["sabotage: %s" % error]
    if scope[0] == "skip":
        return []
    if scope[0] == "block":
        return [scope[1]]
    _kind, base, product, checks = scope
    path = sabotage_path(spec)
    root = package_root()
    if not os.path.isfile(path):
        return [
            "no sabotage evidence at %s" % path,
            "run: python3 %s sabotage %s" % (root / "done_means.py", spec),
            "playbook: %s" % (root / "templates" / "done-means-sabotage.md"),
        ]
    evidence = load(path)
    if evidence is None:
        return ["sabotage evidence at %s is not JSON" % path]
    problems = evidence_problems(evidence, checks, product, fix_sha(cwd, product))
    if problems:
        return problems
    live = cycle(cwd, product, base, checks)
    recorded = evidence.get("checks") or []
    for row, fresh in zip(recorded, live):
        if row["red"]["exit"] != fresh["red"]["exit"]:
            problems.append(
                "sabotage: check %s recorded red exit %s but reverting the non-test diff now exits %s"
                % (row["id"], row["red"]["exit"], fresh["red"]["exit"])
            )
        if row["green"]["exit"] != fresh["green"]["exit"]:
            problems.append(
                "sabotage: check %s recorded green exit %s but the restored tree now exits %s"
                % (row["id"], row["green"]["exit"], fresh["green"]["exit"])
            )
    return problems


def execute(spec, cwd, data):
    return (
        command_problems(spec, cwd, data)
        + path_problems(cwd, data)
        + ci_problems(cwd, data)
        + sabotage_problems(spec, cwd, data)
    )


def start_problems(cwd, spec=None):
    spec = spec or locate(cwd)
    if not os.path.isfile(spec):
        return missing_problems(spec), None
    data = load(spec)
    if data is None:
        return ["%s is not JSON" % spec], None
    problems = schema_problems(data)
    if problems:
        return problems, data
    return review_problems(spec), data


def finish_problems(cwd, spec=None):
    spec = spec or locate(cwd)
    if not os.path.isfile(spec):
        return missing_problems(spec), None
    data = load(spec)
    if data is None:
        return ["%s is not JSON" % spec], None
    problems = schema_problems(data)
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
    human = data.get("human") if isinstance(data, dict) else None
    if human:
        print("UNENFORCED")
        for item in human:
            print(item)
    return 0


USAGE = """usage: done_means.py validate|run|sabotage|hash [spec-or-dir]

validate   schema, vagueness, and a passing review verdict
run        validate, then checks, paths, CI, and sabotage evidence
sabotage   revert the non-test diff, record red, restore, record green
hash       print the spec sha256 a review verdict must cite
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
    if command == "sabotage":
        if not os.path.isfile(spec):
            return report(missing_problems(spec), None)
        data = load(spec)
        if data is None:
            return report(["%s is not JSON" % spec], None)
        problems = schema_problems(data)
        if problems:
            return report(problems, data)
        return report(record_sabotage(spec, cwd, data), data)
    if command == "run":
        problems, data = finish_problems(cwd, spec)
        return report(problems, data)
    print(USAGE.strip())
    return 2
