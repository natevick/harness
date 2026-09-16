import os
import re

from . import PASS, deny, warn
from .shell_text import segments, strip_prefixes, strip_prefixes

FULL_FLAG = re.compile(r"^-[a-zA-Z]*f$|^--full$")

DENIAL = """DENIED - pkill -f matches the shell running it.

The pattern you are searching for is, by construction, part of this command's own argv, so pkill
signals your own shell call. That terminates the tool call mid-run (exit 144) and leaves the
processes it was meant to replace still running.

Instead:
  * kill the recorded pid:  kill $(cat /path/to/pidfile)   or  kill <pid from ps>
  * to LOOK, not kill:      /bin/ps -eo pid,etime,cmd | grep -E '[m]ypattern'

Override when you are certain: GUARDRAILS_ALLOW_PKILL_F=1"""

CAUTION = (
    "pgrep -f also matches this shell's own argv, so a hit may be your own command rather "
    "than the process you are checking. A count of 0 or 1 here is not evidence. Prefer: "
    "/bin/ps -eo pid,etime,cmd | grep -E '[m]ypattern'"
)


def matches_full(argv):
    return any(FULL_FLAG.match(token) for token in argv[1:])


def calls(command, name):
    for segment in segments(command):
        argv = strip_prefixes(segment)
        if not argv:
            continue
        if argv[0].rsplit("/", 1)[-1] == name and matches_full(argv):
            return True
    return False


def check_command(command):
    if not (command or "").strip():
        return PASS

    if calls(command, "pkill") and not os.environ.get("GUARDRAILS_ALLOW_PKILL_F"):
        return deny(DENIAL)
    if calls(command, "pgrep"):
        return warn(CAUTION)
    return PASS
