#!/usr/bin/env python3
import sys

import hookio
from guardrails import truncation


def main():
    event = hookio.read("PostToolUse")
    if event is None or not event.is_shell:
        return 0
    return hookio.decide(
        event, "truncation", truncation.check_output(event.command, event.stdout)
    )


if __name__ == "__main__":
    sys.exit(main())
