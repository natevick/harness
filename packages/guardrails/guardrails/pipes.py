import re

from . import PASS, deny
from .shell_text import scannable

FILTERS = "head|tail|wc|cut|column|less|more|tee|nl|fold|rev|expand"

STATUS = re.compile(r"\$\{?\?\}?")
PIPED_FILTER = re.compile(r"\|\s*(?:/\S*/)?(%s)(?=\s|$|;|\||&)" % FILTERS)
PIPEFAIL = re.compile(r"set\s+-[a-zA-Z]*o[a-zA-Z]*\s+pipefail|set\s+-o\s+pipefail")
PIPESTATUS = re.compile(r"\$\{PIPESTATUS")
OPT_OUT = re.compile(r"pipe-exit-ok")

DENIAL = """DENIED — this reads $? after piping into `%(filter)s`.

$? is the exit status of the LAST element of a pipeline. `%(filter)s` almost always exits 0, so the
status you are about to report belongs to the filter, not to the command you care about. pipefail is
off by default in POSIX shells (verified: `false | head` gives $? = 0), so nothing rescues this.

Rewrite one of these ways:
  cmd >/tmp/out 2>&1; rc=$?; head -20 /tmp/out     # capture status, then look
  cmd | head -20; rc=${PIPESTATUS[0]}              # read the right element
  if cmd; then …                                     # test directly, no $? at all
  set -o pipefail; cmd | head -20; rc=$?            # make the pipeline inherit the failure

Deliberate and genuinely want the filter's status? Add `# pipe-exit-ok` to the command.

The general rule this enforces: a check that cannot fail proves nothing. Before reporting a probe as
passing, confirm it CAN go red."""


def segment_around(text, position):
    start = max(
        (text.rfind(mark, 0, position) for mark in (";", "\n", "&&", "||")), default=-1
    )
    ends = [index for index in
            (text.find(mark, position) for mark in (";", "\n")) if index != -1]
    return text[start + 1: min(ends) if ends else len(text)]


def offending_filter(text):
    cursor = 0
    for status in STATUS.finditer(text):
        window = text[cursor: status.start()]
        cursor = status.end()

        piped = None
        for match in PIPED_FILTER.finditer(window):
            piped = match
        if piped is None:
            continue

        segment = segment_around(text, status.start())
        if OPT_OUT.search(segment) or PIPESTATUS.search(segment):
            continue
        if PIPEFAIL.search(window[: piped.start()]):
            continue
        return piped.group(1)
    return None


def check_command(command):
    text = scannable(command)
    if not text.strip():
        return PASS

    filter_name = offending_filter(text)
    if filter_name is None:
        return PASS

    return deny(DENIAL % {"filter": filter_name})
