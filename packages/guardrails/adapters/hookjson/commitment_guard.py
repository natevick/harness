#!/usr/bin/env python3
import sys

import hookio
from guardrails import commitment


def reply(event):
    text = hookio.stop_message(event)
    if text:
        return text

    transcript = hookio.transcript_path(event)
    if not transcript:
        hookio.note_missing_stop_text(event)
        return None
    return hookio.final_assistant_text(transcript)


def main():
    event = hookio.read("Stop")
    if event is None or event.stop_hook_active:
        return 0
    return hookio.decide(event, "commitment", commitment.check_reply(reply(event)))


if __name__ == "__main__":
    sys.exit(main())
