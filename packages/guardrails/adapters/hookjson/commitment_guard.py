#!/usr/bin/env python3
import sys

import hookio
from guardrails import commitment


def main():
    event = hookio.read("Stop")
    if event is None or event.stop_hook_active:
        return 0
    return hookio.decide(event, "commitment", commitment.check_reply(hookio.assistant_reply(event)))


if __name__ == "__main__":
    sys.exit(main())
