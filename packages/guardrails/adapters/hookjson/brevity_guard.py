#!/usr/bin/env python3
import os
import sys
import time

import hookio
from guardrails import brevity

FLUSH_WAIT = float(os.environ.get("GUARDRAILS_BREVITY_FLUSH_WAIT", "2"))
FLUSH_POLL = 0.05


def measure(event):
    text = hookio.stop_message(event)
    if text:
        return text, "payload", None

    transcript = hookio.transcript_path(event)
    if not transcript:
        return None, "absent", None

    seen = brevity.last_seen_uuid(event.session or "-")
    deadline = time.monotonic() + FLUSH_WAIT
    while True:
        text, uuid = hookio.last_assistant(transcript)
        if text and uuid != seen:
            return text, "transcript", uuid
        if time.monotonic() >= deadline:
            return None, "unflushed", uuid
        time.sleep(FLUSH_POLL)


def main():
    event = hookio.read("Stop")
    if event is None or event.stop_hook_active:
        return 0

    text, source, uuid = measure(event)
    if source == "absent":
        hookio.note_missing_stop_text(event)
        return 0

    return hookio.decide(
        event, "brevity", brevity.evaluate(text, event.session or "-", source, uuid)
    )


if __name__ == "__main__":
    sys.exit(main())
