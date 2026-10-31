import os
import re

from . import state_dir

HOOK_LIVE = "hook-live"
SPEC_SEEN = "spec-seen-"


def _safe(session):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(session or ""))[:64]


def _touch(name):
    directory = state_dir()
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
        path = os.path.join(directory, name)
        descriptor = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        os.close(descriptor)
    except OSError:
        return None


def note_tool_event(name, session):
    if name in ("stop", "subagentstop"):
        return None
    note_hook(session)
    return None


def note_hook(session):
    _touch(HOOK_LIVE)
    safe = _safe(session)
    if safe:
        _touch(HOOK_LIVE + "-" + safe)


def hooks_live(session=""):
    directory = state_dir()
    if os.path.isfile(os.path.join(directory, HOOK_LIVE)):
        return True
    safe = _safe(session)
    if safe and os.path.isfile(os.path.join(directory, HOOK_LIVE + "-" + safe)):
        return True
    return False


def note_spec(session):
    safe = _safe(session) or "unknown"
    _touch(SPEC_SEEN + safe)


def spec_seen(session):
    safe = _safe(session) or "unknown"
    return os.path.isfile(os.path.join(state_dir(), SPEC_SEEN + safe))
