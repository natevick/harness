import re

from . import PASS, warn
from .shell_text import executable_text

LIMIT_PATTERNS = (
    r"\bhead\s+-(?:n\s*)?(\d+)",
    r"\btail\s+-(?:n\s*)?(\d+)",
    r"\bgrep\b[^|;]*?-m\s*(\d+)",
    r"\bLIMIT\s+(\d+)",
)

COMPOUND = re.compile(r"(;|&&|\|\||\becho\b|\bprintf\b)")

CAUTION = (
    "TRUNCATION - this command capped output at {limit} and returned {lines} non-empty "
    "lines, so matches were almost certainly cut off.\n\n"
    "You have NOT seen every match. Do not conclude that something is absent, complete, or "
    "unique from this output. Re-run without the cap, or count first (grep -c / wc -l), "
    "before claiming anything about what does not exist."
)


def check_output(command, stdout):
    stdout = stdout or ""
    if not (command or "").strip() or not stdout:
        return PASS

    command = executable_text(command)
    if not command.strip() or COMPOUND.search(command):
        return PASS

    limits = []
    for pattern in LIMIT_PATTERNS:
        limits += [int(n) for n in re.findall(pattern, command, re.I) if int(n) > 0]
    if not limits:
        return PASS

    limit = min(limits)
    lines = len([line for line in stdout.splitlines() if line.strip()])
    if lines < limit:
        return PASS

    return warn(CAUTION.format(limit=limit, lines=lines))
