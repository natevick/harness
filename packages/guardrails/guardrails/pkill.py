import os
import re
import signal

from . import PASS, deny, warn
from .shell_text import PLACEHOLDER, commands, strip_prefixes

FULL_FLAG = re.compile(r"^-[a-zA-Z]*f$|^--full$")

DENIAL = """DENIED - pkill -f matches the shell running it.

The pattern you are searching for is, by construction, part of this command's own argv, so pkill
signals your own shell call. That terminates the tool call mid-run (exit 144) and leaves the
processes it was meant to replace still running.

Instead:
  * kill the recorded pid:  kill $(cat /path/to/pidfile)   or  kill <pid from ps>
  * to LOOK, not kill:      /bin/ps -eo pid,etime,cmd | grep -E '[m]ypattern'

Override when you are certain: GUARDRAILS_ALLOW_PKILL_F=1"""

NAME_DENIAL = """DENIED - killing by name or user. On 2026-11-18 `pkill -u norm sleep` killed the devcontainer's `sleep infinity`.

To stop your own processes, signal the process group you recorded:
  kill -- -<pgid>      or      pkill -g <pgid>

If a kill by name or user is truly needed, it needs Nate's tap. It runs as root in /, so keep
-u norm and use absolute paths:
  timeout 900 broker-run --sudo --reason "<why>" -- /usr/bin/pkill -u norm <pattern>

Inside a container there is no broker route (docker is refused under --sudo): kill the recorded
pgid inside the container instead."""

CAUTION = (
    "pgrep -f also matches this shell's own argv, so a hit may be your own command rather "
    "than the process you are checking. A count of 0 or 1 here is not evidence. Prefer: "
    "/bin/ps -eo pid,etime,cmd | grep -E '[m]ypattern'"
)


LOOKUPS = ("pgrep", "pidof")
SHELLS = ("sh", "bash", "zsh", "dash", "ksh")
CONTAINER_RUNNERS = ("docker", "podman")
CONTAINER_VALUE_OPTIONS = ("-e", "--env", "-u", "--user", "-w", "--workdir", "--env-file", "--detach-keys")
SHELL_VALUE_OPTIONS = ("-o", "-O", "+o", "+O")
SHORT_SELECTORS = "gPs"
SHORT_MODIFIERS = "ecfinoxAH"
LONG_SELECTORS = ("pgroup", "parent", "session")
LONG_MODIFIERS = ("echo", "count", "full", "ignore-case", "newest", "oldest", "exact",
                  "ignore-ancestors", "require-handler")

SIGNAL_NAMES = "|".join(name[3:] for name in signal.Signals.__members__)
SIGNAL_WORD = rf"(?:\d+|(?:SIG)?(?:{SIGNAL_NAMES})|(?:SIG)?RT(?:MIN|MAX)(?:[+-]\d+)?)"
SIGNAL_FLAG = re.compile(rf"^-{SIGNAL_WORD}$")
SIGNAL_VALUE = re.compile(rf"^{SIGNAL_WORD}$")
IDS = re.compile(rf"^(?:\d+(?:,\d+)*|\$(?:\w+|\{{\w+\}}|\$|!)|{PLACEHOLDER})$")

FULL = "full"
NAME = "name"
PGREP_FULL = "pgrep-full"


def matches_full(argv):
    return any(FULL_FLAG.match(token) for token in argv[1:])


def basename(token):
    return token.rsplit("/", 1)[-1]


def option_value(tokens, index, attached):
    if attached is not None:
        return attached, index
    if index < len(tokens):
        return tokens[index], index + 1
    return None, index


def scoped_to_ids(argv):
    tokens, index, selectors = argv[1:], 0, 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if token.startswith("--") and len(token) > 2:
            option, equals, attached = token[2:].partition("=")
            if option in LONG_MODIFIERS and not equals:
                continue
            if option != "signal" and option not in LONG_SELECTORS:
                return False
            value, index = option_value(tokens, index, attached if equals else None)
            pattern = SIGNAL_VALUE if option == "signal" else IDS
            if not pattern.match(value or ""):
                return False
            selectors += option in LONG_SELECTORS
        elif token.startswith("-") and token != "-":
            if SIGNAL_FLAG.match(token):
                continue
            body, position = token[1:], 0
            while position < len(body):
                letter = body[position]
                position += 1
                if letter in SHORT_MODIFIERS:
                    continue
                if letter not in SHORT_SELECTORS:
                    return False
                value, index = option_value(tokens, index, body[position:] or None)
                if not IDS.match(value or ""):
                    return False
                selectors += 1
                break
        else:
            return False
    return selectors > 0


def container_command(rest):
    index = 0
    while index < len(rest) and rest[index].startswith("-"):
        index += 2 if rest[index] in CONTAINER_VALUE_OPTIONS else 1
    return rest[index + 1:]


def unwrap(argv):
    via_xargs = False
    while argv:
        stripped = strip_prefixes(argv)
        via_xargs = via_xargs or any(basename(token) == "xargs" for token in argv[:len(argv) - len(stripped)])
        argv = stripped
        if argv and basename(argv[0]) in CONTAINER_RUNNERS and argv[1:2] == ["exec"]:
            argv = container_command(argv[2:])
            continue
        break
    return argv, via_xargs


def shell_payload(argv):
    name = basename(argv[0])
    if name == "eval":
        return " ".join(argv[1:])
    if name not in SHELLS:
        return None
    index = 1
    while index < len(argv) and argv[index].startswith(("-", "+")):
        option = argv[index]
        if not option.startswith("--") and "c" in option[1:]:
            return argv[index + 1] if index + 1 < len(argv) else None
        index += 2 if option in SHELL_VALUE_OPTIONS else 1
    return None


def brokered(argv):
    options = argv[1:argv.index("--")] if "--" in argv else argv[1:]
    return "--sudo" in options


def has_lookup(parsed):
    for command in parsed:
        argv, _ = unwrap(command.argv)
        if (argv and basename(argv[0]) in LOOKUPS) or has_lookup(command.inner):
            return True
    return False


def scan(parsed, findings, outer=()):
    lookup_in_pipe = False
    for command in parsed:
        if not command.piped:
            lookup_in_pipe = False
        scan(command.inner, findings)
        argv, via_xargs = unwrap(command.argv)
        if not argv:
            continue
        name = basename(argv[0])
        substituted = command.inner
        if not substituted and any(PLACEHOLDER in token for token in argv):
            substituted = list(outer)
        payload = shell_payload(argv)
        if payload is not None:
            scan(commands(payload), findings, list(outer) + command.inner)
        elif name == "broker-run" and brokered(argv):
            continue
        elif name == "pkill":
            if matches_full(argv):
                findings.add(FULL)
            if not scoped_to_ids(argv) or has_lookup(substituted):
                findings.add(NAME)
        elif name == "killall":
            findings.add(NAME)
        elif name == "kill" and (has_lookup(substituted) or (via_xargs and lookup_in_pipe)):
            findings.add(NAME)
        elif name == "pgrep" and matches_full(argv):
            findings.add(PGREP_FULL)
        lookup_in_pipe = lookup_in_pipe or name in LOOKUPS


def check_command(command):
    if not (command or "").strip():
        return PASS

    findings = set()
    scan(commands(command), findings)
    if NAME in findings:
        return deny(NAME_DENIAL)
    if FULL in findings and not os.environ.get("GUARDRAILS_ALLOW_PKILL_F"):
        return deny(DENIAL)
    if PGREP_FULL in findings:
        return warn(CAUTION)
    return PASS
