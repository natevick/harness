import os
import pwd
import re
import shlex

TAILS = (
    ".cursor/hooks.json",
    ".cursor/mcp.json",
    ".cursor/environment.json",
    ".claude/settings.json",
    ".claude/settings.local.json",
    ".claude/mcp.json",
    ".codex/hooks.json",
)
ROOT_NAMES = {".mcp.json", "mcp.json"}
WRITE_BINARIES = {"cp", "mv", "rm", "tee", "truncate", "ln", "install", "dd", "rsync"}
OPEN_WRITE = re.compile(r"\bopen\s*\(|write_text\s*\(|write_bytes\s*\(")
REDIRECT = re.compile(r">>?")
SED = re.compile(r"\bsed\b")
SED_INPLACE = re.compile(r"(?:^|\s)-[A-Za-z]*i")
TRUST_FILE = "/etc/harness/reviewers.json"


def home_dir():
    return pwd.getpwuid(os.geteuid()).pw_dir


def trust_path():
    return TRUST_FILE


def _real(path):
    return os.path.realpath(path).replace("\\", "/")


def harness_root():
    return os.path.join(home_dir(), ".harness")


def _folded(cwd, path):
    text = os.path.expanduser(str(path or "").strip().strip("'\""))
    if not text:
        return ""
    if os.path.isabs(text):
        absolute = os.path.normpath(text)
    else:
        absolute = os.path.abspath(os.path.join(cwd or ".", text))
    try:
        absolute = os.path.realpath(absolute)
    except OSError:
        return absolute.replace("\\", "/")
    return absolute.replace("\\", "/")


def is_protected(cwd, path):
    folded = _folded(cwd, path)
    if not folded:
        return False
    home = _real(home_dir())
    harness = home + "/.harness"
    if folded == harness or folded.startswith(harness + "/"):
        return True
    if folded == _real(TRUST_FILE):
        return True
    for tail in TAILS:
        if folded == home + "/" + tail or folded.endswith("/" + tail):
            return True
    base = os.path.basename(folded)
    parent = os.path.dirname(folded)
    cwd_norm = _real(cwd or ".")
    if base == ".mcp.json":
        return True
    if base == "environment.json" and parent.endswith("/.cursor"):
        return True
    if base in ROOT_NAMES and parent in (cwd_norm, home, home + "/.cursor"):
        return True
    return False


def canonical_protected(cwd, token):
    if is_protected(cwd, token):
        return _folded(cwd, token)
    folded = os.path.expanduser(str(token or "")).replace("\\", "/")
    if TRUST_FILE in folded:
        return TRUST_FILE
    if ".cursor/environment.json" in folded:
        return ".cursor/environment.json"
    home = os.path.abspath(home_dir()).replace("\\", "/")
    marker = home + "/.harness"
    if marker + "/" in folded or folded.endswith(marker):
        return marker
    if "/.harness/" in folded:
        return marker
    for tail in TAILS:
        if tail in folded:
            return tail
    if folded.endswith("/.mcp.json") or folded == ".mcp.json":
        return token
    return ""


def write_like(command):
    if not isinstance(command, str) or not command:
        return False
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
    if not isinstance(command, str) or not command.strip():
        return []
    if not write_like(command):
        return []
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    found = []
    for token in tokens:
        hit = canonical_protected(cwd, token)
        if hit and hit not in found:
            found.append(hit)
    return found


def format_block(paths):
    lines = ["protected: %s" % path for path in paths]
    return "PROTECTED PATH\n" + "\n".join(lines)
