import os
import re
import time

from . import state_dir

FRESH_SECONDS = 6 * 60 * 60
STOP_CAP = 3

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


def _session_file(prefix, session):
    safe = _safe(session)
    if not safe:
        return ""
    return os.path.join(state_dir(), prefix + safe)


def note_hook(session):
    path = _session_file(HOOK_LIVE + "-", session)
    if not path:
        return None
    directory = state_dir()
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
        descriptor = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    except OSError:
        return None
    try:
        os.write(descriptor, str(time.time()).encode())
    except OSError:
        return None
    finally:
        os.close(descriptor)
    return None


def hooks_live(session=""):
    path = _session_file(HOOK_LIVE + "-", session)
    if not path or not os.path.isfile(path):
        return False
    try:
        seen = float(open(path, errors="replace").read().strip())
    except (OSError, ValueError):
        return False
    return time.time() - seen <= FRESH_SECONDS


def stop_denies(session):
    path = _session_file("stop-denies-", session)
    if not path or not os.path.isfile(path):
        return 0
    try:
        return int(open(path, errors="replace").read().strip() or "0")
    except (OSError, ValueError):
        return 0


def record_stop_deny(session):
    path = _session_file("stop-denies-", session)
    if not path:
        return None
    count = stop_denies(session) + 1
    try:
        os.makedirs(state_dir(), mode=0o700, exist_ok=True)
        descriptor = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
        os.write(descriptor, str(count).encode())
        os.close(descriptor)
    except OSError:
        return None
    return None


def note_spec(session):
    safe = _safe(session) or "unknown"
    _touch(SPEC_SEEN + safe)


def spec_seen(session):
    safe = _safe(session) or "unknown"
    return os.path.isfile(os.path.join(state_dir(), SPEC_SEEN + safe))
