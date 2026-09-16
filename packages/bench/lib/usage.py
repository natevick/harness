"""Normalise each harness's own usage accounting into one comparable record.

Every harness reports tokens in its own shape, so this is where the shapes are
reconciled — and where the reconciliation is documented, because a benchmark
whose accounting you cannot audit is a benchmark you cannot trust.

* **codex** emits JSONL events; usage arrives on ``turn.completed``. Cost is not
  reported, so ``cost_usd`` stays ``None`` unless a rate is supplied.
* **grok** and **claude** both emit a single JSON result object carrying a
  cumulative ``modelUsage`` map plus a self-reported dollar cost. The top-level
  ``usage`` block on a claude result describes only its final assistant message,
  so ``modelUsage`` — which is cumulative and per-model — is what gets summed.
"""

from __future__ import annotations

import json
from pathlib import Path

EMPTY = {
    "input_tokens": 0,
    "cache_read_tokens": 0,
    "cache_write_tokens": 0,
    "output_tokens": 0,
    "reasoning_tokens": 0,
    "model_calls": None,
    "model_calls_source": None,
    "tool_calls": None,
    "cost_usd": None,
    "models": {},
    "parse_error": None,
}


def _blank() -> dict:
    record = dict(EMPTY)
    record["models"] = {}
    return record


def _finish(record: dict) -> dict:
    """Fill in the derived totals every arm shares."""
    record["billed_context_tokens"] = (
        record["input_tokens"] + record["cache_read_tokens"] + record["cache_write_tokens"]
    )
    record["total_tokens"] = record["billed_context_tokens"] + record["output_tokens"]
    return record


def parse_codex(path: Path) -> dict:
    """Sum usage across every ``turn.completed`` event in a codex JSONL log."""
    record = _blank()
    turns = 0
    tool_calls = 0
    final_text = None
    if not path.exists():
        record["parse_error"] = "no raw.jsonl"
        return _finish(record)

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("type")
        if kind == "turn.completed":
            turns += 1
            usage = event.get("usage") or {}
            record["input_tokens"] += usage.get("input_tokens", 0)
            record["cache_read_tokens"] += usage.get("cached_input_tokens", 0)
            record["output_tokens"] += usage.get("output_tokens", 0)
            record["reasoning_tokens"] += usage.get("reasoning_output_tokens", 0)
        elif kind == "item.completed":
            item = event.get("item") or {}
            if item.get("type") in {"command_execution", "file_change", "mcp_tool_call", "web_search"}:
                tool_calls += 1
            elif item.get("type") == "agent_message":
                final_text = item.get("text")

    # codex counts a cached prefix inside input_tokens; keep the shared
    # `input_tokens` field meaning "uncached input" across all arms.
    record["input_tokens"] = max(0, record["input_tokens"] - record["cache_read_tokens"])
    record["tool_calls"] = tool_calls
    # codex reports one `turn.completed` per exec, not one per API request, so
    # round trips are inferred: an initial request plus one per tool result.
    record["model_calls"] = tool_calls + 1 if turns else None
    record["model_calls_source"] = "estimated (tool calls + 1)" if turns else None
    record["turns"] = turns
    record["final_text"] = final_text
    record["models"] = {"gpt-5.6-sol": {"turns": turns}}
    if turns == 0:
        record["parse_error"] = "no turn.completed event"
    return _finish(record)


def _from_model_usage(blob: dict, record: dict) -> dict:
    """Sum a grok/claude ``modelUsage`` map into the shared record."""
    calls = 0
    for name, usage in (blob.get("modelUsage") or {}).items():
        record["input_tokens"] += usage.get("inputTokens", 0)
        record["cache_read_tokens"] += usage.get("cacheReadInputTokens", 0)
        record["cache_write_tokens"] += usage.get("cacheCreationInputTokens", 0)
        record["output_tokens"] += usage.get("outputTokens", 0)
        calls += usage.get("modelCalls", 0) or 0
        record["models"][name] = {
            "input": usage.get("inputTokens", 0),
            "cache_read": usage.get("cacheReadInputTokens", 0),
            "cache_write": usage.get("cacheCreationInputTokens", 0),
            "output": usage.get("outputTokens", 0),
            "calls": usage.get("modelCalls"),
            "cost_usd": usage.get("costUSD"),
        }
    if calls:
        record["model_calls"] = calls
        record["model_calls_source"] = "reported (modelUsage.modelCalls)"
    record["cost_usd"] = blob.get("total_cost_usd")
    return record


def parse_grok(path: Path) -> dict:
    record = _blank()
    if not path.exists():
        record["parse_error"] = "no raw.json"
        return _finish(record)
    try:
        blob = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except json.JSONDecodeError as exc:
        record["parse_error"] = f"unparseable raw.json: {exc}"
        return _finish(record)

    _from_model_usage(blob, record)
    record["reasoning_tokens"] = (blob.get("usage") or {}).get("reasoning_tokens", 0)
    record["turns"] = blob.get("num_turns")
    record["stop_reason"] = blob.get("stopReason")
    record["final_text"] = blob.get("text")
    if blob.get("stopReason") not in (None, "EndTurn"):
        record["parse_error"] = f"stopReason={blob.get('stopReason')}"
    return _finish(record)


def parse_claude(path: Path) -> dict:
    """Read a claude ``stream-json`` transcript: the last line is the result."""
    record = _blank()
    if not path.exists():
        record["parse_error"] = "no raw.json"
        return _finish(record)

    result = None
    assistant_messages = 0
    tool_calls = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result":
            result = event
        elif event.get("type") == "assistant":
            assistant_messages += 1
            content = (event.get("message") or {}).get("content") or []
            tool_calls += sum(1 for block in content if block.get("type") == "tool_use")

    if result is None:
        record["parse_error"] = "no result object in raw.json"
        return _finish(record)

    _from_model_usage(result, record)
    record["tool_calls"] = tool_calls or None
    if assistant_messages:
        record["model_calls"] = assistant_messages
        record["model_calls_source"] = "counted (assistant messages)"
    elif result.get("num_turns"):
        record["model_calls"] = result["num_turns"]
        record["model_calls_source"] = "reported (num_turns)"
    record["turns"] = result.get("num_turns")
    record["stop_reason"] = result.get("stop_reason")
    record["final_text"] = result.get("result")
    record["api_duration_s"] = round((result.get("duration_api_ms") or 0) / 1000, 2)
    if result.get("is_error"):
        record["parse_error"] = f"is_error, subtype={result.get('subtype')}"
    return _finish(record)


def parse_run(arm: str, run_dir: Path) -> dict:
    """Parse whichever raw artefact ``arm`` produced in ``run_dir``."""
    if arm == "codex":
        return parse_codex(run_dir / "raw.jsonl")
    if arm == "grok":
        return parse_grok(run_dir / "raw.json")
    if arm.startswith("claude"):
        return parse_claude(run_dir / "raw.json")
    record = _blank()
    record["parse_error"] = f"unknown arm {arm}"
    return _finish(record)
