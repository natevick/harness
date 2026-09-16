import os
from dataclasses import dataclass

ALLOW = "allow"
DENY = "deny"
WARN = "warn"


@dataclass(frozen=True)
class Verdict:
    decision: str
    reason: str = ""


PASS = Verdict(ALLOW)


def deny(reason):
    return Verdict(DENY, reason)


def warn(reason):
    return Verdict(WARN, reason)


def state_dir():
    configured = os.environ.get("GUARDRAILS_STATE_DIR")
    if configured:
        return configured
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(base, "harness-guardrails")
