#!/usr/bin/env python3
import sys

import hookio
from guardrails import brevity


def main():
    event = hookio.read("UserPromptSubmit")
    if event is None:
        return 0
    return hookio.decide(event, "brevity_streak", brevity.streak_hint(event.session))


if __name__ == "__main__":
    sys.exit(main())
