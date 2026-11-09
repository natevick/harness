#!/usr/bin/env python3
import sys

import hookio
from guardrails import PASS, commitment


def main():
    event = hookio.read("Stop")
    if event is None or event.stop_hook_active:
        return 0
    verdict = commitment.check_reply(hookio.assistant_reply(event))
    if verdict is not PASS and hookio.launches_worker(hookio.transcript_path(event)):
        verdict = PASS
    return hookio.decide(event, "commitment", verdict)


if __name__ == "__main__":
    sys.exit(main())
