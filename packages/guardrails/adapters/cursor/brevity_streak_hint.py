#!/usr/bin/env python3
import sys

import cursorio
from guardrails import brevity


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if event.name != "beforesubmitprompt":
        return cursorio.allow(event)
    return cursorio.decide(event, "brevity_streak", brevity.streak_hint(event.session))


if __name__ == "__main__":
    sys.exit(main())
