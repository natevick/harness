#!/usr/bin/env python3
"""Score every harness seat: tokens, wall time, and whether the work is actually correct.

Reads logs/<seat>/{stdout.log,meta.json}, re-runs the suite in runs/<seat>, and checks
that the seat did not cheat by touching test/.
"""
import json
import pathlib
import re
import subprocess
import sys

BENCH = pathlib.Path(__file__).parent
SEATS = ["claude", "claude-cfg", "codex", "grok"]


def sh(args, cwd=None):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def parse_claude(log_text):
    """claude -p --output-format json emits one JSON object."""
    d = json.loads(log_text)
    u = d.get("usage", {})
    inp = u.get("input_tokens", 0)
    cw = u.get("cache_creation_input_tokens", 0)
    cr = u.get("cache_read_input_tokens", 0)
    out = u.get("output_tokens", 0)
    # Side-model calls (e.g. Haiku for internal bookkeeping) are billed too.
    side_in = side_out = 0
    for model, mu in (d.get("modelUsage") or {}).items():
        if "opus" not in model and "sonnet" not in model:
            side_in += mu.get("inputTokens", 0) + mu.get("cacheReadInputTokens", 0) \
                + mu.get("cacheCreationInputTokens", 0)
            side_out += mu.get("outputTokens", 0)
    return {
        "prompt_tokens": inp + cw + cr,
        "input_fresh": inp,
        "cache_write": cw,
        "cache_read": cr,
        "output_tokens": out,
        "side_model_tokens": side_in + side_out,
        "total_tokens": inp + cw + cr + out + side_in + side_out,
        "turns": d.get("num_turns"),
        "reported_cost_usd": d.get("total_cost_usd"),
        "harness_duration_ms": d.get("duration_ms"),
        "final_text": (d.get("result") or "").strip(),
        "models": sorted((d.get("modelUsage") or {}).keys()),
    }


def parse_codex(log_text):
    """codex exec --json emits JSONL; one turn.completed per model turn."""
    prompt = out = reasoning = cached = 0
    turns = 0
    peak_prompt = 0
    final_text = ""
    for line in log_text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "turn.completed":
            u = ev.get("usage", {})
            p = u.get("input_tokens", 0)
            prompt += p
            peak_prompt = max(peak_prompt, p)
            cached += u.get("cached_input_tokens", 0)
            out += u.get("output_tokens", 0)
            reasoning += u.get("reasoning_output_tokens", 0)
            turns += 1
        if ev.get("type") == "item.completed":
            item = ev.get("item", {})
            if item.get("type") in ("agent_message", "assistant_message"):
                final_text = item.get("text", item.get("content", "")) or final_text
    return {
        "prompt_tokens": prompt,
        "input_fresh": prompt - cached,
        "cache_write": None,
        "cache_read": cached,
        "output_tokens": out + reasoning,
        "side_model_tokens": 0,
        "total_tokens": prompt + out + reasoning,
        "turns": turns,
        "peak_prompt_tokens": peak_prompt,
        "reported_cost_usd": None,
        "harness_duration_ms": None,
        "final_text": final_text.strip()[:4000],
        "models": ["gpt-5.6-sol (xhigh)"],
    }


def parse_grok(log_text):
    """grok -p --output-format json emits one JSON object."""
    d = json.loads(log_text)
    u = d.get("usage", {})
    inp = u.get("input_tokens", 0)
    cr = u.get("cache_read_input_tokens", 0)
    out = u.get("output_tokens", 0)
    reasoning = u.get("reasoning_tokens", 0)
    return {
        "prompt_tokens": inp + cr,
        "input_fresh": inp,
        "cache_write": None,
        "cache_read": cr,
        "output_tokens": out,
        "reasoning_tokens": reasoning,
        "side_model_tokens": 0,
        "total_tokens": u.get("total_tokens", inp + cr + out),
        "turns": d.get("num_turns"),
        "reported_cost_usd": d.get("total_cost_usd"),
        "harness_duration_ms": None,
        "final_text": (d.get("text") or "").strip(),
        "models": sorted((d.get("modelUsage") or {}).keys()),
    }


PARSERS = {
    "claude": parse_claude,
    "claude-cfg": parse_claude,
    "codex": parse_codex,
    "grok": parse_grok,
}


def score_seat(seat):
    logdir = BENCH / "logs" / seat
    rundir = BENCH / "runs" / seat
    row = {"seat": seat}

    meta_path = logdir / "meta.json"
    if meta_path.exists():
        row.update(json.loads(meta_path.read_text()))

    log = logdir / "stdout.log"
    if log.exists() and log.stat().st_size:
        try:
            row["usage"] = PARSERS[seat](log.read_text())
        except Exception as exc:  # noqa: BLE001 - surface, do not hide
            row["usage_error"] = f"{type(exc).__name__}: {exc}"
    else:
        row["usage_error"] = "no stdout captured"

    # --- correctness gate: the suite is the oracle ---
    _, test_out = sh(["node", "--test"], cwd=rundir)
    m_pass = re.search(r"^# pass (\d+)", test_out, re.M)
    m_fail = re.search(r"^# fail (\d+)", test_out, re.M)
    m_tests = re.search(r"^# tests (\d+)", test_out, re.M)
    row["tests_total"] = int(m_tests.group(1)) if m_tests else None
    row["tests_pass"] = int(m_pass.group(1)) if m_pass else None
    row["tests_fail"] = int(m_fail.group(1)) if m_fail else None
    row["suite_green"] = row["tests_fail"] == 0 and (row["tests_pass"] or 0) > 0

    # --- integrity gate: did it modify the oracle? ---
    _, changed = sh(["git", "diff", "--name-only", "HEAD"], cwd=rundir)
    _, untracked = sh(["git", "ls-files", "--others", "--exclude-standard"], cwd=rundir)
    changed_files = [f for f in changed.split() if f]
    new_files = [f for f in untracked.split() if f]
    row["files_changed"] = changed_files
    row["files_added"] = new_files
    row["touched_tests"] = [f for f in changed_files + new_files if f.startswith("test/")]
    row["touched_package_json"] = "package.json" in changed_files
    row["clean_fix"] = not row["touched_tests"] and not row["touched_package_json"]

    _, stat = sh(["git", "diff", "--shortstat", "HEAD"], cwd=rundir)
    row["diff_shortstat"] = stat.strip()
    return row


def main():
    rows = [score_seat(s) for s in SEATS]
    (BENCH / "results.json").write_text(json.dumps(rows, indent=2))

    hdr = f"{'seat':<11} {'wall':>8} {'total tok':>10} {'prompt':>9} {'out':>7} " \
          f"{'turns':>6} {'tests':>8} {'clean':>6} {'cost':>9}"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        u = r.get("usage", {})
        wall = f"{r.get('wall_ms', 0) / 1000:.1f}s" if r.get("wall_ms") else "-"
        cost = u.get("reported_cost_usd")
        cost_s = f"${cost:.4f}" if isinstance(cost, (int, float)) else "n/r"
        tests = f"{r.get('tests_pass')}/{r.get('tests_total')}"
        print(
            f"{r['seat']:<11} {wall:>8} {u.get('total_tokens', 0):>10,} "
            f"{u.get('prompt_tokens', 0):>9,} {u.get('output_tokens', 0):>7,} "
            f"{str(u.get('turns')):>6} {tests:>8} "
            f"{('yes' if r['clean_fix'] else 'NO'):>6} {cost_s:>9}"
        )
        if r.get("usage_error"):
            print(f"{'':<11}   ! {r['usage_error']}")
        if r["touched_tests"]:
            print(f"{'':<11}   ! MODIFIED ORACLE: {r['touched_tests']}")
    print("\nwrote results.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
