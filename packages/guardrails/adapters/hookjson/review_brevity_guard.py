#!/usr/bin/env python3
import sys

import hookio
from guardrails import PASS, review_brevity


def message_verdict(tool, fields):
    if not tool.startswith("mcp__"):
        return PASS
    if tool.endswith(("slack_send_message", "slack_send_message_draft")):
        return review_brevity.check_message("the Slack message", fields.get("message"))
    if tool.startswith("mcp__linear"):
        if tool.endswith("save_comment"):
            return review_brevity.check_message("the Linear comment", fields.get("body"))
        if tool.endswith("save_issue"):
            return review_brevity.check_message(
                "the Linear issue description", fields.get("description")
            )
    return PASS


def main():
    event = hookio.read("PreToolUse")
    if event is None:
        return 0
    if event.is_shell:
        verdict = review_brevity.check_command(event.command)
    else:
        verdict = message_verdict(event.tool, event.fields)
    return hookio.decide(event, "review_brevity", verdict)


if __name__ == "__main__":
    sys.exit(main())
