#!/usr/bin/env python3
import sys

import cursorio
from guardrails import PASS, comments


def verdict_for(event):
    if event.is_shell:
        return comments.check_shell(event.command, event.cwd)
    if event.is_write:
        return comments.check_units(event.write_units())
    return PASS


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if not event.is_shell and not event.is_write:
        return cursorio.allow(event)
    return cursorio.decide(event, "comments", verdict_for(event))


if __name__ == "__main__":
    sys.exit(main())
