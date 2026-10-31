import os
import pwd
import re
import shlex

TAILS = (
    ".cursor/hooks.json",
    ".cursor/mcp.json",
    ".claude/settings.json",
    ".claude/settings.local.json",
    ".claude/mcp.json",
    ".codex/hooks.json",
)
ROOT_NAMES = {".mcp.json", "mcp.json"}
WRITE_BINARIES = {"cp", "mv", "rm", "tee", "truncate", "ln"}
OPEN_WRITE = re.compile(r"\bopen\s*\(|write_text\s*\(|write_bytes\s*\(")
REDIRECT = re.compile(r">>?")
SED = re.compile(r"\bsed\b")
SED_INPLACE = re.compile(r"(?:^|\s)-[A-Za-z]*i")


def home_dir():
    return pwd.getpwuid(os.geteuid()).pw_dir


def trust_path():
    return os.path.join(home_dir(), ".harness", "reviewers.json")


def is_protected(cwd, path):
    text = os.path.expanduser(str(path or "").strip().strip("'\""))
    if not text:
        return False
    if os.path.isabs(text):
        absolute = os.path.normpath(text)
    else:
        absolute = os.path.abspath(os.path.join(cwd or ".", text))
    folded = absolute.replace("\\", "/")
    home = os.path.abspath(home_dir()).replace("\\", "/")
    if folded == home + "/.harness/reviewers.json":
        return True
    for tail in TAILS:
        if folded == home + "/" + tail or folded.endswith("/" + tail):
            return True
    base = os.path.basename(folded)
    parent = os.path.dirname(folded)
    cwd_norm = os.path.abspath(cwd or ".").replace("\\", "/")
    if base == ".mcp.json":
        return True
    if base in ROOT_NAMES and parent in (cwd_norm, home, home + "/.cursor"):
        return True
    return False


def installer_command(command):
    if not isinstance(command, str) or not command.strip():
        return False
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    bases = [os.path.basename(token) for token in tokens]
    if "cloud-setup.sh" in bases:
        return True
    return "install.sh" in bases and "--harness" in tokens


def write_like(command):
    if REDIRECT.search(command) or OPEN_WRITE.search(command):
        return True
    if SED.search(command) and SED_INPLACE.search(command):
        return True
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    bases = {os.path.basename(token) for token in tokens}
    return bool(bases & WRITE_BINARIES)


def command_targets(command, cwd):
    if not isinstance(command, str) or not command.strip() or installer_command(command):
        return []
    if not write_like(command):
        return []
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    found = []
    for token in tokens:
        if is_protected(cwd, token):
            found.append(token)
            continue
        folded = token.replace("\\", "/")
        if ".harness/reviewers.json" in folded:
            found.append(trust_path())
            continue
        for tail in TAILS:
            if tail in folded:
                found.append(tail)
                break
        else:
            if folded.endswith("/.mcp.json") or folded == ".mcp.json":
                found.append(token)
    return found


def format_block(paths):
    lines = ["protected: %s" % path for path in paths]
    return "PROTECTED PATH\n" + "\n".join(lines)
