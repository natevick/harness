#!/usr/bin/env python3
import sys

import hookio
from guardrails import delegation

DELEGATION_TOOLS = ("Agent", "Workflow", "SendMessage", "Task", "spawn_subagent")


def main():
    event = hookio.read("PreToolUse")
    if event is None or not event.tool:
        return 0

    if event.tool in DELEGATION_TOOLS:
        delegation.reset(event.session)
        return 0
    if not event.is_shell:
        return 0

    return hookio.decide(event, "delegation", delegation.record_call(event.session))


if __name__ == "__main__":
    sys.exit(main())
