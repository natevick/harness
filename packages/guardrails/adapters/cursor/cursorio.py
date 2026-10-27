import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from guardrails import ALLOW, DENY, WARN, state_dir
from guardrails.comments import disk_text

# Permission hooks block when stdout is not JSON that matches the schema.
# beforeShellExecution and preToolUse are in that set; an allow must say so.
PERMISSION_EVENTS = (
    "beforeshellexecution",
    "beforemcpexecution",
    "beforereadfile",
    "beforetabfileread",
    "subagentstart",
    "pretooluse",
)

# additional_context is injected only for these. beforeShellExecution accepts
# agent_message in the schema and then ignores it on allow — verified in the
# exec daemon's runBeforeShellExecutionPermissionHook, and by a live warn that
# arrived only when preToolUse returned additional_context.
WARN_EVENTS = (
    "pretooluse",
    "posttooluse",
    "posttoolusefailure",
    "beforesubmitprompt",
    "sessionstart",
)

FOLLOWUP_EVENTS = ("stop", "subagentstop")


def event_key(name):
    return re.sub(r"[^a-z]", "", str(name or "").lower())


def coerce_output(value):
    if isinstance(value, dict):
        return value.get("output") or value.get("stdout") or ""
    if not isinstance(value, str):
        return ""
    stripped = value.strip()
    if stripped.startswith("{") and stripped.endswith("}"):
        try:
            parsed = json.loads(stripped)
        except ValueError:
            return value
        if isinstance(parsed, dict) and ("output" in parsed or "stdout" in parsed):
            return parsed.get("output") or parsed.get("stdout") or ""
    return value


def parse_tool_input(value):
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
        except ValueError:
            return {}
        if isinstance(parsed, dict):
            return parsed
    return {}


class Event:
    def __init__(self, raw):
        self.raw = raw
        self.wire = raw.get("hook_event_name") or ""
        self.name = event_key(self.wire)
        self.tool = raw.get("tool_name") or ""
        self.fields = parse_tool_input(raw.get("tool_input"))

    @property
    def session(self):
        return self.raw.get("session_id") or self.raw.get("conversation_id") or ""

    @property
    def cwd(self):
        for candidate in (
            self.raw.get("cwd"),
            self.fields.get("cwd"),
            self.fields.get("working_directory"),
        ):
            if isinstance(candidate, str) and candidate.strip():
                return candidate
        roots = self.raw.get("workspace_roots")
        if isinstance(roots, list) and roots and isinstance(roots[0], str) and roots[0].strip():
            return roots[0]
        return os.environ.get("CURSOR_PROJECT_DIR") or os.getcwd()

    @property
    def is_shell(self):
        if self.name in ("beforeshellexecution", "aftershellexecution"):
            return True
        return self.tool == "Shell"

    @property
    def is_write(self):
        # afterFileEdit runs after the write and cannot deny. preToolUse Write
        # carries the full new file in tool_input.content, including StrReplace.
        if self.name != "pretooluse" or self.tool != "Write":
            return False
        return bool(self.path)

    @property
    def is_mcp(self):
        if self.tool.startswith("MCP:"):
            return True
        return self.name == "beforemcpexecution" and bool(self.tool or self.fields)

    @property
    def command(self):
        if self.name in ("beforeshellexecution", "aftershellexecution"):
            value = self.raw.get("command") or ""
            return value if isinstance(value, str) else ""
        if not self.is_shell:
            return ""
        value = self.fields.get("command")
        if isinstance(value, list):
            return " ".join(str(item) for item in value)
        return value or ""

    @property
    def path(self):
        return (
            self.fields.get("file_path")
            or self.fields.get("path")
            or self.raw.get("file_path")
            or ""
        )

    @property
    def prompt(self):
        return self.raw.get("prompt") or ""

    @property
    def text(self):
        return (self.raw.get("text") or self.raw.get("last_assistant_message") or "").strip()

    @property
    def stdout(self):
        if self.name == "aftershellexecution":
            return coerce_output(self.raw.get("output"))
        return coerce_output(self.raw.get("tool_output"))

    @property
    def can_deny(self):
        return self.name in PERMISSION_EVENTS

    @property
    def can_warn(self):
        return self.name in WARN_EVENTS

    @property
    def can_followup(self):
        return self.name in FOLLOWUP_EVENTS

    @property
    def follow_up_ok(self):
        status = str(self.raw.get("status") or "completed").lower()
        return status == "completed"

    def write_units(self):
        path = self.path
        if not path:
            return []
        edits = self.fields.get("edits")
        if isinstance(edits, list) and edits:
            return [
                (path, edit.get("old_string") or "", edit.get("new_string") or "")
                for edit in edits
                if isinstance(edit, dict)
            ]
        if "new_string" in self.fields:
            return [(
                path,
                self.fields.get("old_string") or "",
                self.fields.get("new_string") or "",
            )]
        if "content" in self.fields:
            return [(path, disk_text(path), self.fields.get("content") or "")]
        return []


def read():
    try:
        raw = json.load(sys.stdin)
    except Exception:
        return None
    if not isinstance(raw, dict):
        return None
    return Event(raw)


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
        "ts": now(),
        "harness": "cursor",
        "event": event.wire,
        "guard": guard,
        "tool": event.tool or ("Shell" if event.is_shell else ""),
        "subject_digest": digest(event.command or event.path or event.prompt),
        "decision": verdict.decision,
        "reason": verdict.reason.split("\n")[0][:200],
    })


def emit(payload):
    sys.stdout.write(json.dumps(payload) + "\n")


def allow(event):
    if event is not None and event.can_deny:
        emit({"permission": "allow"})
    return 0


def decide(event, guard, verdict):
    if verdict.decision == DENY and event.name == "beforesubmitprompt":
        log_decision(event, guard, verdict)
        sys.stderr.write(verdict.reason + "\n")
        emit({"continue": False, "user_message": verdict.reason})
        return 0

    if verdict.decision == DENY and event.can_followup:
        if not event.follow_up_ok:
            return 0
        log_decision(event, guard, verdict)
        sys.stderr.write(verdict.reason + "\n")
        emit({"followup_message": verdict.reason})
        return 0

    if verdict.decision == DENY and event.can_deny:
        log_decision(event, guard, verdict)
        sys.stderr.write(verdict.reason + "\n")
        emit({
            "permission": "deny",
            "user_message": verdict.reason,
            "agent_message": verdict.reason,
        })
        return 0

    # beforeShellExecution accepts agent_message and then drops it on allow.
    # Print permission allow so the empty-stdout rule does not block the call.
    # The preToolUse registration is what delivers the warn text.
    if verdict.decision == WARN and event.can_warn:
        log_decision(event, guard, verdict)
        payload = {"additional_context": verdict.reason}
        if event.can_deny:
            payload["permission"] = "allow"
        if event.name == "beforesubmitprompt":
            payload["continue"] = True
        emit(payload)
        return 0

    if verdict.decision == ALLOW and os.environ.get("GUARDRAILS_LOG_DECISIONS"):
        log_decision(event, guard, verdict)
    return allow(event)


def session_key(session):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(session or ""))[:64] or "unknown"


def stash_path(session):
    return os.path.join(state_dir(), "cursor-assistant-%s.txt" % session_key(session))


def stash_assistant(session, text):
    if not text:
        return
    directory = state_dir()
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
        descriptor = os.open(stash_path(session), os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    except OSError:
        return
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(text)
    except OSError:
        pass


def read_stash(session):
    try:
        with open(stash_path(session), errors="replace") as handle:
            text = handle.read().strip()
    except OSError:
        return ""
    return text


def transcript_text(event):
    path = event.raw.get("transcript_path") or os.environ.get("CURSOR_TRANSCRIPT_PATH") or ""
    if not path:
        return ""
    hookjson = Path(__file__).resolve().parents[1] / "hookjson"
    sys.path.insert(0, str(hookjson))
    try:
        import hookio
    except Exception:
        return ""
    found = hookio.final_assistant_text(path)
    return found or ""


def assistant_text(event):
    if event.text:
        return event.text, "payload"
    stashed = read_stash(event.session)
    if stashed:
        return stashed, "cursor-stash"
    transcript = transcript_text(event)
    if transcript:
        return transcript, "transcript"
    return None, "absent"


def note_missing_stop_text(event, guard):
    marker = os.path.join(
        state_dir(),
        "no-stop-text-cursor-%s-%s.marker" % (guard, session_key(event.session)),
    )
    try:
        os.makedirs(state_dir(), mode=0o700, exist_ok=True)
        if os.path.exists(marker):
            return
        with open(marker, "w") as handle:
            handle.write(now())
    except OSError:
        return
    append("decisions.jsonl", {
        "ts": now(),
        "harness": "cursor",
        "event": event.wire,
        "guard": guard,
        "tool": "",
        "decision": "unmeasured",
        "reason": "cursor sent no assistant text on stop",
    })
