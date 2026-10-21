#!/usr/bin/env python3
import sys

import cursorio
from guardrails import PASS, review_brevity


def leaf(tool):
    if tool.startswith("MCP:"):
        return tool.split(":", 1)[1]
    if tool.startswith("mcp__"):
        return tool.rsplit("__", 1)[-1]
    return tool


def message_verdict(event):
    if not event.is_mcp:
        return PASS
    name = leaf(event.tool)
    if name.endswith(("slack_send_message", "slack_send_message_draft")):
        return review_brevity.check_message("the Slack message", event.fields.get("message"))
    if name.endswith("save_comment"):
        return review_brevity.check_message("the Linear comment", event.fields.get("body"))
    if name.endswith("save_issue"):
        return review_brevity.check_message(
            "the Linear issue description", event.fields.get("description")
        )
    return PASS


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if event.is_shell:
        verdict = review_brevity.check_command(event.command)
    elif event.is_mcp:
        verdict = message_verdict(event)
    else:
        return cursorio.allow(event)
    return cursorio.decide(event, "review_brevity", verdict)


if __name__ == "__main__":
    sys.exit(main())
