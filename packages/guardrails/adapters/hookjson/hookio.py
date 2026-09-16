import hashlib
import json
import os
import re
import shlex
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from guardrails import ALLOW, DENY, WARN, state_dir, warn
from guardrails.comments import disk_text, patch_units

SHELL_TOOLS = ("Bash", "run_terminal_command")
WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "search_replace", "apply_patch")
PATCH_TOOLS = ("apply_patch",)

CAMEL_MARKERS = (
    "hookEventName", "toolName", "toolInput", "toolResult", "toolUseId",
    "lastAssistantMessage", "stopHookActive", "sessionId",
)
GROK_TOOLS = ("run_terminal_command", "search_replace")

FIELD_ALIASES = {
    "tool_result": "tool_response",
    "tool_output": "tool_response",
    "tool_call_id": "tool_use_id",
}

WIRE_EVENTS = {
    "pretooluse": "PreToolUse",
    "posttooluse": "PostToolUse",
    "stop": "Stop",
    "userpromptsubmit": "UserPromptSubmit",
}

GROK_SHAPE = ("grok",)


def snake(key):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower()


NESTED = ("tool_input", "tool_response")


def rename_keys(value):
    if isinstance(value, dict):
        return {snake(key): rename_keys(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rename_keys(item) for item in value]
    return value


def normalize(raw):
    out = {}
    for key, value in raw.items():
        name = FIELD_ALIASES.get(snake(key), snake(key))
        out[name] = rename_keys(value) if name in NESTED else value
    return out


def detect(raw):
    forced = os.environ.get("GUARDRAILS_HARNESS")
    if forced:
        return forced.strip().lower()
    if any(marker in raw for marker in CAMEL_MARKERS):
        return "grok"

    tool = raw.get("tool_name") or ""
    if tool in GROK_TOOLS:
        return "grok"
    if tool in PATCH_TOOLS:
        return "codex"
    if "tool_call_id" in raw or "tool_output" in raw:
        return "kimi"

    fields = raw.get("tool_input")
    if isinstance(fields, dict) and "path" in fields and "file_path" not in fields:
        return "kimi"
    return "claude"


def event_key(name):
    return re.sub(r"[^a-z]", "", str(name or "").lower())


def join_command_list(items):
    items = [str(item) for item in items]
    # Whitespace in an item means this is argv, not a tokenized shell line.
    # Quote those so a --body mentioning "pkill -f" stays one token (issue #3).
    # Otherwise space-join so a list that already split on "|" still scans.
    if any(any(char.isspace() for char in item) for item in items):
        return shlex.join(items)
    return " ".join(items)


class Event:
    def __init__(self, raw, expected):
        self.raw = raw
        self.harness = detect(raw)
        self.data = normalize(raw)
        self.wire = WIRE_EVENTS.get(
            event_key(self.data.get("hook_event_name")), expected
        )
        self.name = event_key(self.wire)
        self.tool = self.data.get("tool_name") or ""
        self.fields = self.data.get("tool_input") or {}
        if not isinstance(self.fields, dict):
            self.fields = {}

    @property
    def session(self):
        return self.data.get("session_id") or ""

    @property
    def cwd(self):
        return self.data.get("cwd") or os.getcwd()

    @property
    def prompt(self):
        return self.data.get("prompt") or ""

    @property
    def command(self):
        value = self.fields.get("command")
        if isinstance(value, list):
            return join_command_list(value)
        return value or ""

    @property
    def truncated(self):
        return bool(self.data.get("tool_input_truncated"))

    @property
    def path(self):
        return self.fields.get("file_path") or self.fields.get("path") or ""

    @property
    def is_shell(self):
        return self.tool in SHELL_TOOLS

    @property
    def is_write(self):
        if self.is_shell:
            return False
        return self.tool in WRITE_TOOLS or bool(self.path or self.fields.get("edits"))

    @property
    def stop_hook_active(self):
        return bool(self.data.get("stop_hook_active"))

    @property
    def stdout(self):
        response = self.data.get("tool_response")
        if isinstance(response, str):
            return response
        if isinstance(response, dict):
            return response.get("stdout") or response.get("output") or ""
        return ""

    def write_units(self):
        if self.tool in PATCH_TOOLS:
            return patch_units(self.command, self.cwd)

        path = self.path
        if not path or path == "-":
            return []

        edits = self.fields.get("edits")
        if isinstance(edits, list):
            return [
                (path, edit.get("old_string") or "", edit.get("new_string") or "")
                for edit in edits
                if isinstance(edit, dict)
            ]
        if "new_string" in self.fields:
            return [(path, self.fields.get("old_string") or "",
                     self.fields.get("new_string") or "")]
        return [(path, disk_text(path), self.fields.get("content") or "")]


def read(expected):
    try:
        raw = json.load(sys.stdin)
    except Exception:
        return None
    if not isinstance(raw, dict):
        return None
    return Event(raw, expected)


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def append(name, entry):
    directory = state_dir()
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
        descriptor = os.open(
            os.path.join(directory, name), os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600
        )
    except OSError:
        return
    try:
        with os.fdopen(descriptor, "a") as handle:
            handle.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def digest(text):
    if not text:
        return ""
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:12]


def log_decision(event, guard, verdict):
    if verdict.decision == ALLOW and not os.environ.get("GUARDRAILS_LOG_DECISIONS"):
        return
    append("decisions.jsonl", {
        "ts": now(), "harness": event.harness, "event": event.wire, "guard": guard,
        "tool": event.tool, "subject_digest": digest(event.command or event.path),
        "decision": verdict.decision,
        "reason": verdict.reason.split("\n")[0][:200],
    })


UNMEASURABLE = (
    "The harness truncated this tool input before the guard saw it, so the guard read a clipped "
    "command and its allow proves nothing. Re-run the call with the full input, or treat this "
    "call as unchecked."
)


def decide(event, guard, verdict):
    if event.truncated and verdict.decision == ALLOW and event.name != "stop":
        verdict = warn(UNMEASURABLE)
    log_decision(event, guard, verdict)

    if verdict.decision == DENY:
        sys.stderr.write(verdict.reason + "\n")
        if event.name == "stop":
            return 2
        if event.harness in GROK_SHAPE:
            print(json.dumps({"decision": "deny", "reason": verdict.reason}))
            return 2
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": event.wire,
            "permissionDecision": "deny",
            "permissionDecisionReason": verdict.reason,
        }}))
        return 0

    if verdict.decision == WARN:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": event.wire,
            "additionalContext": verdict.reason,
        }}))
    return 0


def stop_message(event):
    return (event.data.get("last_assistant_message") or "").strip() or None


def transcript_path(event):
    return event.data.get("transcript_path") or ""


def note_missing_stop_text(event):
    marker = os.path.join(
        state_dir(),
        "no-stop-text-%s-%s.marker" % (
            event.harness, re.sub(r"[^A-Za-z0-9_-]", "", event.session)[:64] or "unknown"
        ),
    )
    try:
        os.makedirs(state_dir(), exist_ok=True)
        if os.path.exists(marker):
            return
        with open(marker, "w") as handle:
            handle.write(now())
    except OSError:
        return
    append("decisions.jsonl", {
        "ts": now(), "harness": event.harness, "event": event.wire, "guard": "stop",
        "tool": "", "decision": "unmeasured",
        "reason": "harness sent no assistant text and no transcript path on stop",
    })


def records(path):
    try:
        with open(path, errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            out.append(parsed)
    return out


def assistant_text(record):
    if record.get("type") != "assistant":
        return None
    content = record.get("message", {}).get("content", [])
    if not isinstance(content, list):
        return None
    text = "".join(
        chunk.get("text", "")
        for chunk in content
        if isinstance(chunk, dict) and chunk.get("type") == "text"
    ).strip()
    return text or None


def last_assistant(path):
    for record in reversed(records(path)):
        text = assistant_text(record)
        if text:
            return text, record.get("uuid") or record.get("message", {}).get("id")
    return None, None


def final_assistant_text(path, attempts=10, delay=0.15):
    fallback, previous_size = None, -1
    for attempt in range(attempts):
        try:
            size = os.path.getsize(path)
        except OSError:
            size = -1
        found = records(path)
        if found:
            tail = assistant_text(found[-1])
            if tail:
                return tail
            for record in reversed(found):
                text = assistant_text(record)
                if text:
                    fallback = text
                    break
        if fallback is not None and size == previous_size:
            return fallback
        previous_size = size
        if attempt < attempts - 1:
            time.sleep(delay)
    return fallback
