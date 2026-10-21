#!/usr/bin/env python3
import sys

import cursorio


def main():
    event = cursorio.read()
    if event is None:
        return 1
    if event.name == "afteragentresponse" and event.text:
        cursorio.stash_assistant(event.session, event.text)
    return cursorio.allow(event)


if __name__ == "__main__":
    sys.exit(main())
