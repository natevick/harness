#!/usr/bin/env python3
import sys

import cursorio
from guardrails import goals


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if event.name != "beforesubmitprompt":
        return cursorio.allow(event)
    return cursorio.decide(event, "goals", goals.check_prompt(event.prompt, event.session))


if __name__ == "__main__":
    sys.exit(main())
