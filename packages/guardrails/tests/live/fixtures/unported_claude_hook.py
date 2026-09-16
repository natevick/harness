#!/usr/bin/env python3
import json
import os
import sys


def record(variable, line):
    path = os.environ.get(variable)
    if not path:
        return
    with open(path, "a") as handle:
        handle.write(line + "\n")


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        record("UNPORTED_SEEN", "invoked, stdin was not JSON")
        return 0

    record("UNPORTED_SEEN", "invoked, keys=" + ",".join(sorted(payload)))

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command:
        return 0

    record("UNPORTED_PARSED", command)
    if "$?" in command and "|" in command:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "unported Claude hook denial",
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
