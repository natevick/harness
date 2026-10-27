#!/usr/bin/env python3
import sys

import cursorio
from guardrails import goals


def paths_for(event):
    if event.is_write:
        return [event.path] if event.path else []
    if event.is_shell:
        return goals.shell_paths(event.command, event.cwd)
    return None


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if event.name == "stop":
        if not event.follow_up_ok:
            return 0
        text, source = cursorio.assistant_text(event)
        if source == "absent":
            cursorio.note_missing_stop_text(event, "goals")
            return 0
        return cursorio.decide(event, "goals", goals.check_stop(text, event.cwd, event.session))
    paths = paths_for(event)
    if not paths:
        return cursorio.allow(event)
    return cursorio.decide(event, "goals", goals.check_start(event.cwd, event.session, paths))


if __name__ == "__main__":
    sys.exit(main())
