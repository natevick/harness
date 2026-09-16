#!/usr/bin/env python3
"""Turn a run directory into results.csv, results.json and report.md.

Usage: ``report.py <run_dir>``

Re-runnable at any time: it reads only artefacts already on disk, so a run that
was interrupted still reports on whatever finished.
"""

from __future__ import annotations

import csv
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from usage import parse_run  # noqa: E402

FIELDS = [
    "arm",
    "rep",
    "score",
    "hidden_passed",
    "hidden_total",
    "visible_green",
    "tests_added",
    "wall_s",
    "total_tokens",
    "input_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "output_tokens",
    "reasoning_tokens",
    "model_calls",
    "tool_calls",
    "cost_usd",
    "lines_added",
    "lines_removed",
    "files_changed",
    "exit_code",
    "timed_out",
    "commits",
    "dependency_smells",
    "notes",
]


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def collect(run_dir: Path) -> list[dict]:
    rows = []
    for arm_dir in sorted(p for p in run_dir.iterdir() if p.is_dir()):
        for rep_dir in sorted(arm_dir.glob("rep*")):
            meta = read_json(rep_dir / "meta.json")
            grade = read_json(rep_dir / "grade.json")
            if not meta:
                continue
            arm = meta.get("arm", arm_dir.name)
            usage = parse_run(arm, rep_dir)
            git = grade.get("git", {})
            notes = [note for note in (usage.get("parse_error"),) if note]
            if grade.get("load_errors", {}).get("visible"):
                notes.append("visible suite would not load")
            rows.append(
                {
                    "arm": arm,
                    "rep": meta.get("rep"),
                    "score": grade.get("score"),
                    "hidden_passed": grade.get("hidden_tests", {}).get("passed"),
                    "hidden_total": grade.get("hidden_tests", {}).get("total"),
                    "visible_green": grade.get("visible_suite", {}).get("green"),
                    "tests_added": grade.get("visible_suite", {}).get("tests_added"),
                    "wall_s": meta.get("wall_s"),
                    "total_tokens": usage["total_tokens"],
                    "input_tokens": usage["input_tokens"],
                    "cache_read_tokens": usage["cache_read_tokens"],
                    "cache_write_tokens": usage["cache_write_tokens"],
                    "output_tokens": usage["output_tokens"],
                    "reasoning_tokens": usage["reasoning_tokens"],
                    "model_calls": usage["model_calls"],
                    "tool_calls": usage["tool_calls"],
                    "cost_usd": usage["cost_usd"],
                    "lines_added": git.get("lines_added"),
                    "lines_removed": git.get("lines_removed"),
                    "files_changed": git.get("files_changed"),
                    "exit_code": meta.get("exit_code"),
                    "timed_out": meta.get("timed_out"),
                    "commits": git.get("commits"),
                    "dependency_smells": "; ".join(grade.get("dependency_smells", [])),
                    "notes": "; ".join(notes),
                    "_requirements": grade.get("requirements", {}),
                    "_models": usage.get("models", {}),
                }
            )
    return rows


def median(values):
    clean = [v for v in values if isinstance(v, (int, float))]
    return round(statistics.median(clean), 2) if clean else None


def summarise(rows: list[dict]) -> dict:
    by_arm: dict[str, list[dict]] = {}
    for row in rows:
        by_arm.setdefault(row["arm"], []).append(row)
    summary = {}
    for arm, arm_rows in by_arm.items():
        summary[arm] = {
            "reps": len(arm_rows),
            "score_median": median([r["score"] for r in arm_rows]),
            "score_min": min((r["score"] for r in arm_rows if r["score"] is not None), default=None),
            "score_max": max((r["score"] for r in arm_rows if r["score"] is not None), default=None),
            "wall_s_median": median([r["wall_s"] for r in arm_rows]),
            "total_tokens_median": median([r["total_tokens"] for r in arm_rows]),
            "output_tokens_median": median([r["output_tokens"] for r in arm_rows]),
            "cache_read_median": median([r["cache_read_tokens"] for r in arm_rows]),
            "model_calls_median": median([r["model_calls"] for r in arm_rows]),
            "cost_usd_median": median([r["cost_usd"] for r in arm_rows]),
            "diff_lines_median": median(
                [
                    (r["lines_added"] or 0) + (r["lines_removed"] or 0)
                    for r in arm_rows
                ]
            ),
            "all_green": all(r["visible_green"] for r in arm_rows),
        }
    return summary


def fmt(value, unit: str = "") -> str:
    if value is None:
        return "—"
    if unit == "k":
        return f"{value / 1000:,.1f}k"
    if unit == "$":
        return f"${value:,.3f}"
    if unit == "s":
        return f"{value:,.0f}s"
    if unit == "%":
        return f"{value * 100:,.1f}%"
    return f"{value:,}" if isinstance(value, (int, float)) else str(value)


def write_report(run_dir: Path, rows: list[dict], summary: dict) -> None:
    run = read_json(run_dir / "run.json")
    lines = [
        f"# Harness benchmark — {run.get('run_id', run_dir.name)}",
        "",
        f"Task: `task/PROMPT.md` against seed `{run.get('seed_sha', '?')[:8]}` "
        f"(5 requirements, {rows[0]['hidden_total'] if rows else '?'} hidden acceptance tests).",
        f"Host: {run.get('host', '?')}, {run.get('cpus', '?')} CPUs. "
        f"codex {run.get('codex_version', '?')} · grok {run.get('grok_version', '?')} · "
        f"claude {run.get('claude_version', '?')}.",
        f"Arms ran sequentially, {run.get('reps', '?')} rep(s) each, "
        f"{run.get('timeout_s', '?')}s timeout, scratch config homes (no persona, skills, hooks or MCP).",
        "",
        "## Summary (median across reps)",
        "",
        "| arm | score | visible suite | wall | total tokens | output | cache read | model calls | self-reported cost | diff lines |",
        "| --- | ----- | ------------- | ---- | ------------ | ------ | ---------- | ----------- | ------------------ | ---------- |",
    ]
    for arm, stats in sorted(summary.items(), key=lambda kv: -(kv[1]["score_median"] or 0)):
        lines.append(
            "| `{arm}` | {score} | {green} | {wall} | {total} | {out} | {cache} | {calls} | {cost} | {diff} |".format(
                arm=arm,
                score=fmt(stats["score_median"], "%"),
                green="green" if stats["all_green"] else "**RED**",
                wall=fmt(stats["wall_s_median"], "s"),
                total=fmt(stats["total_tokens_median"], "k"),
                out=fmt(stats["output_tokens_median"], "k"),
                cache=fmt(stats["cache_read_median"], "k"),
                calls=fmt(stats["model_calls_median"]),
                cost=fmt(stats["cost_usd_median"], "$"),
                diff=fmt(stats["diff_lines_median"]),
            )
        )

    lines += [
        "",
        "`score` is the mean of five per-requirement scores; R1–R4 are the fraction of that",
        "requirement's hidden tests that pass, R5 rewards keeping the shipped suite green and",
        "adding tests. A **RED** visible suite means the candidate broke tests it was told to keep",
        "passing — read that column before the token columns.",
        "",
        "## Per requirement",
        "",
        "| arm | rep | R1 split | R2 parser | R3 subcommand | R4 --top | R5 tests | score |",
        "| --- | --- | -------- | --------- | ------------- | -------- | -------- | ----- |",
    ]
    for row in rows:
        req = row["_requirements"]
        cells = [
            fmt(req.get(key, {}).get("score"), "%") for key in ("R1", "R2", "R3", "R4", "R5")
        ]
        lines.append(
            f"| `{row['arm']}` | {row['rep']} | " + " | ".join(cells) + f" | {fmt(row['score'], '%')} |"
        )

    lines += [
        "",
        "## Every run",
        "",
        "| arm | rep | score | wall | total tokens | in | cache r | cache w | out | reasoning | calls | tools | cost | diff | exit | notes |",
        "| --- | --- | ----- | ---- | ------------ | -- | ------- | ------- | --- | --------- | ----- | ----- | ---- | ---- | ---- | ----- |",
    ]
    for row in rows:
        lines.append(
            "| `{arm}` | {rep} | {score} | {wall} | {total} | {inp} | {cr} | {cw} | {out} | {reason} | {calls} | {tools} | {cost} | +{la}/-{lr} | {exit} | {notes} |".format(
                arm=row["arm"],
                rep=row["rep"],
                score=fmt(row["score"], "%"),
                wall=fmt(row["wall_s"], "s"),
                total=fmt(row["total_tokens"], "k"),
                inp=fmt(row["input_tokens"], "k"),
                cr=fmt(row["cache_read_tokens"], "k"),
                cw=fmt(row["cache_write_tokens"], "k"),
                out=fmt(row["output_tokens"], "k"),
                reason=fmt(row["reasoning_tokens"], "k"),
                calls=fmt(row["model_calls"]),
                tools=fmt(row["tool_calls"]),
                cost=fmt(row["cost_usd"], "$"),
                la=row["lines_added"],
                lr=row["lines_removed"],
                exit=row["exit_code"],
                notes=row["notes"] or "",
            )
        )

    failures = [
        (row, key, req)
        for row in rows
        for key, req in row["_requirements"].items()
        if req.get("failures")
    ]
    if failures:
        lines += ["", "## What each arm got wrong", ""]
        for row, key, req in failures:
            lines.append(
                f"- `{row['arm']}` rep{row['rep']} **{key}** "
                f"({req['passed']}/{req['tests']}): {', '.join(req['failures'])}"
            )

    lines += [
        "",
        "## Caveats",
        "",
        "- Cost is each harness's own self-report. codex reports no dollar figure, so its cell is",
        "  blank rather than guessed; compare it on tokens.",
        "- Reasoning effort is not equalised: codex runs `gpt-5.6-sol` at `xhigh`, grok and claude",
        "  run their defaults. Token counts include that choice.",
        "- Cached input is billed far below fresh input on every one of these providers, so",
        "  `total tokens` overstates relative cost for whichever arm leans hardest on its cache.",
        "- One task is one task. It exercises reading a small codebase, two bug fixes, two CLI",
        "  features and test authoring — not long-context work, not a large repo.",
        "",
    ]
    (run_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    run_dir = Path(sys.argv[1]).resolve()
    rows = collect(run_dir)
    if not rows:
        print(f"no completed runs under {run_dir}", file=sys.stderr)
        return 1
    summary = summarise(rows)

    with (run_dir / "results.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    (run_dir / "results.json").write_text(
        json.dumps({"summary": summary, "runs": rows}, indent=2) + "\n", encoding="utf-8"
    )
    write_report(run_dir, rows, summary)
    print((run_dir / "report.md").read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
