#!/usr/bin/env python3
import sys

import cursorio
from guardrails import truncation


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if event.name != "posttooluse" or not event.is_shell:
        return cursorio.allow(event)
    return cursorio.decide(
        event, "truncation", truncation.check_output(event.command, event.stdout)
    )


if __name__ == "__main__":
    sys.exit(main())
