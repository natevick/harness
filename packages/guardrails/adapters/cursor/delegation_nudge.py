#!/usr/bin/env python3
import sys

import cursorio
from guardrails import delegation


def main():
    event = cursorio.read()
    if event is None:
        return 1
    # beforeShellExecution fires for the same call as preToolUse Shell. Counting
    # both would nudge at 15 real commands. Only the preToolUse registration counts.
    if event.name == "subagentstart" or event.tool == "Task":
        delegation.reset(event.session)
        return cursorio.allow(event)
    if event.name != "pretooluse" or not event.is_shell:
        return cursorio.allow(event)
    return cursorio.decide(event, "delegation", delegation.record_call(event.session))


if __name__ == "__main__":
    sys.exit(main())
