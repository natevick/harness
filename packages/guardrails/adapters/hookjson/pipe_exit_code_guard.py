#!/usr/bin/env python3
import sys

import hookio
from guardrails import pipes


def main():
    event = hookio.read("PreToolUse")
    if event is None or not event.is_shell:
        return 0
    return hookio.decide(event, "pipes", pipes.check_command(event.command))


if __name__ == "__main__":
    sys.exit(main())
