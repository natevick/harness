#!/usr/bin/env python3
"""Grade one candidate working tree against the hidden acceptance suite.

Usage: ``grade.py <candidate_dir> [--out grade.json] [--baseline-tests N]``

Nothing is written into the candidate tree — the hidden suite is imported from
this directory via ``PYTHONPATH`` while the candidate stays the working
directory. Requirements R1–R4 are scored as the fraction of their hidden tests
that pass; R5 scores the candidate's own suite staying green and gaining tests.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REQUIREMENT_CLASSES = {
    "R1": "R1SplitConservesMoney",
    "R2": "R2ParserIsLossless",
    "R3": "R3SplitSubcommand",
    "R4": "R4TopBuckets",
}
TIMEOUT_S = 300
THIRD_PARTY = re.compile(
    r"^\s*(?:import|from)\s+(requests|numpy|pandas|pytest|yaml|httpx|attr|click|rich|pydantic)\b",
    re.MULTILINE,
)


def run_suite(candidate: Path, mode: str) -> dict:
    """Run the hidden or visible suite inside ``candidate`` and return its report."""
    env_path = f"{candidate}:{HERE}"
    try:
        completed = subprocess.run(
            [sys.executable, str(HERE / "_runner.py"), mode],
            cwd=candidate,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_S,
            env={"PYTHONPATH": env_path, "PATH": "/usr/bin:/bin", "HOME": str(candidate)},
        )
    except subprocess.TimeoutExpired:
        return {"mode": mode, "load_error": f"timed out after {TIMEOUT_S}s", "collected": [],
                "passed": [], "failed": {}, "errored": {}, "skipped": []}
    line = completed.stdout.strip().splitlines()[-1] if completed.stdout.strip() else ""
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return {"mode": mode, "load_error": f"runner produced no report: {completed.stderr[-400:]}",
                "collected": [], "passed": [], "failed": {}, "errored": {}, "skipped": []}


def score_requirements(hidden: dict) -> dict:
    """Bucket hidden-test outcomes into a per-requirement score."""
    scores = {}
    for key, class_name in REQUIREMENT_CLASSES.items():
        collected = [name for name in hidden["collected"] if class_name in name]
        passed = [name for name in hidden["passed"] if class_name in name]
        scores[key] = {
            "tests": len(collected),
            "passed": len(passed),
            "score": round(len(passed) / len(collected), 4) if collected else 0.0,
            "failures": sorted(
                name.rsplit(".", 1)[-1]
                for name in collected
                if name not in set(hidden["passed"])
            ),
        }
    return scores


def git_facts(candidate: Path) -> dict:
    """Diff size and whether the candidate honoured 'no commits, no branches'."""

    def git(*args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(candidate), *args], capture_output=True, text=True
        )
        return result.stdout.strip()

    numstat = git("diff", "--numstat", "HEAD")
    added = removed = 0
    for row in numstat.splitlines():
        parts = row.split("\t")
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            added += int(parts[0])
            removed += int(parts[1])
    # bench.sh runs `git add -A -N` after each arm, so brand new files show up in
    # `git diff HEAD` as additions rather than hiding in the untracked list.
    files_added = [
        name
        for name in git("diff", "--name-only", "--diff-filter=A", "HEAD").splitlines()
        if name
    ]
    untracked = [
        name for name in git("ls-files", "--others", "--exclude-standard").splitlines() if name
    ]
    return {
        "commits": len(git("log", "--oneline").splitlines()),
        "branches": len(git("branch", "--format=%(refname:short)").splitlines()),
        "tags": len([t for t in git("tag").splitlines() if t]),
        "files_changed": len([r for r in numstat.splitlines() if r]),
        "lines_added": added,
        "lines_removed": removed,
        "files_added": files_added,
        "untracked_files": untracked,
    }


def dependency_smells(candidate: Path) -> list[str]:
    """Flag anything that looks like a third-party dependency creeping in."""
    smells = []
    for name in ("requirements.txt", "pyproject.toml", "setup.py", "Pipfile", "poetry.lock"):
        if (candidate / name).exists():
            smells.append(f"added {name}")
    for path in candidate.rglob("*.py"):
        if ".git" in path.parts:
            continue
        for match in THIRD_PARTY.finditer(path.read_text(encoding="utf-8", errors="replace")):
            smells.append(f"{path.relative_to(candidate)} imports {match.group(1)}")
    return sorted(set(smells))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("candidate", type=Path)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument(
        "--baseline-tests",
        type=int,
        default=30,
        help="how many tests the seed repository shipped with (default: 30)",
    )
    args = ap.parse_args()
    candidate = args.candidate.resolve()

    hidden = run_suite(candidate, "hidden")
    visible = run_suite(candidate, "visible")

    requirements = score_requirements(hidden)
    visible_total = len(visible["collected"])
    visible_green = (
        visible["load_error"] is None
        and visible_total > 0
        and not visible["failed"]
        and not visible["errored"]
    )
    tests_added = max(0, visible_total - args.baseline_tests)
    if not visible_green:
        r5 = 0.0
    elif tests_added > 0:
        r5 = 1.0
    else:
        r5 = 0.5
    requirements["R5"] = {
        "tests": visible_total,
        "passed": len(visible["passed"]),
        "score": r5,
        "failures": sorted(
            name.rsplit(".", 1)[-1]
            for name in set(visible["failed"]) | set(visible["errored"])
        ),
    }

    hidden_total = len(hidden["collected"])
    report = {
        "candidate": str(candidate),
        "requirements": requirements,
        "score": round(sum(item["score"] for item in requirements.values()) / 5, 4),
        "hidden_tests": {"total": hidden_total, "passed": len(hidden["passed"])},
        "hidden_pass_rate": round(len(hidden["passed"]) / hidden_total, 4) if hidden_total else 0.0,
        "visible_suite": {
            "total": visible_total,
            "passed": len(visible["passed"]),
            "green": visible_green,
            "tests_added": tests_added,
        },
        "load_errors": {"hidden": hidden["load_error"], "visible": visible["load_error"]},
        "git": git_facts(candidate),
        "dependency_smells": dependency_smells(candidate),
    }

    text = json.dumps(report, indent=2)
    if args.out:
        args.out.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
