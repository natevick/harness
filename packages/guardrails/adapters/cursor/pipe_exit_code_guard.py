#!/usr/bin/env python3
import sys

import cursorio
from guardrails import pipes


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if not event.is_shell:
        return cursorio.allow(event)
    return cursorio.decide(event, "pipes", pipes.check_command(event.command))


if __name__ == "__main__":
    sys.exit(main())
