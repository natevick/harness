#!/usr/bin/env python3
import sys

import hookio
from guardrails import goals


def paths_for(event):
    if event.name == "stop":
        return None
    if event.is_write:
        units = event.write_units()
        paths = [unit[0] for unit in units if unit[0]]
        if paths:
            return paths
        return [event.path] if event.path else []
    if event.is_shell:
        return goals.shell_paths(event.command, event.cwd)
    return None


def stop_text(event):
    text = hookio.stop_message(event)
    if text:
        return text
    transcript = hookio.transcript_path(event)
    if not transcript:
        hookio.note_missing_stop_text(event)
        return None
    return hookio.final_assistant_text(transcript)


def main():
    event = hookio.read("PreToolUse")
    if event is None:
        return 0
    if event.name == "stop":
        if event.stop_hook_active:
            return 0
        text = stop_text(event)
        if not text:
            return 0
        return hookio.decide(event, "goals", goals.check_stop(text, event.cwd))
    paths = paths_for(event)
    if not paths:
        return 0
    return hookio.decide(event, "goals", goals.check_start(event.cwd, event.session, paths))


if __name__ == "__main__":
    sys.exit(main())
