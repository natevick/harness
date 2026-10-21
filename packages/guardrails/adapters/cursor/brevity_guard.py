#!/usr/bin/env python3
import sys

import cursorio
from guardrails import brevity


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if event.name != "stop":
        return cursorio.allow(event)
    if not event.follow_up_ok:
        return 0

    text, source = cursorio.assistant_text(event)
    if source == "absent":
        cursorio.note_missing_stop_text(event, "brevity")
        return 0
    return cursorio.decide(
        event, "brevity", brevity.evaluate(text, event.session or "-", source, None)
    )


if __name__ == "__main__":
    sys.exit(main())
