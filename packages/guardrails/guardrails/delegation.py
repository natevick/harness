import os
import re

from . import PASS, state_dir, warn

NUDGE_EVERY = 30

NUDGE = (
    "{count} consecutive shell calls with no delegation — if this is a grind chain, spawn a "
    "worker. Heavy or parallelisable work belongs in a subagent; the threshold worth watching "
    "is around 10 consecutive calls. If this really is one sequential job, carry on — a "
    "reminder, not a gate."
)


def counter_path(session):
    safe = re.sub(r"[^A-Za-z0-9_-]", "", str(session or ""))[:64] or "unknown"
    return os.path.join(state_dir(), "delegation-%s.count" % safe)


def reset(session):
    try:
        os.remove(counter_path(session))
    except OSError:
        pass


def record_call(session):
    path = counter_path(session)
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        os.chmod(os.path.dirname(path), 0o700)
    except OSError:
        return PASS

    try:
        with open(path) as handle:
            previous = handle.read().strip()
    except OSError:
        previous = ""

    count = int(previous) + 1 if previous.isdigit() else 1

    try:
        descriptor = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(str(count))
    except OSError:
        return PASS

    if count % NUDGE_EVERY:
        return PASS
    return warn(NUDGE.format(count=count))
