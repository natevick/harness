#!/usr/bin/env python3
import sys

import hookio
from guardrails import PASS, comments


def verdict_for(event):
    if event.is_shell:
        return comments.check_shell(event.command, event.cwd)
    if event.is_write:
        return comments.check_units(event.write_units())
    return PASS


def main():
    event = hookio.read("PreToolUse")
    if event is None:
        return 0
    return hookio.decide(event, "comments", verdict_for(event))


if __name__ == "__main__":
    sys.exit(main())
