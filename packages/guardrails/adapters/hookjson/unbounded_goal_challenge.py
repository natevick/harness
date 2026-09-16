#!/usr/bin/env python3
import sys

import hookio
from guardrails import goals


def main():
    event = hookio.read("UserPromptSubmit")
    if event is None:
        return 0
    return hookio.decide(event, "goals", goals.check_prompt(event.prompt))


if __name__ == "__main__":
    sys.exit(main())
