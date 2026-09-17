import difflib
import os
import re
import shlex
import tempfile

from . import PASS, deny

MAX_RUN = int(os.environ.get("GUARDRAILS_COMMENT_MAX_RUN", "0"))

EXEMPT_SUFFIXES = (".md", ".markdown", ".txt", ".rst")


def _default_exempt_trees():
    """Temp roots where scratch files should not trigger comment discipline.

    Linux gettempdir() is usually /tmp. macOS gettempdir() is under /var/folders,
    while tests and agents still write /tmp/... (symlink to /private/tmp).
    """
    roots = {os.path.join(tempfile.gettempdir(), "")}
    for candidate in ("/tmp", "/private/tmp", "/var/tmp"):
        roots.add(os.path.join(candidate, ""))
        try:
            roots.add(os.path.join(os.path.realpath(candidate), ""))
        except OSError:
            pass
    return ":".join(sorted(roots))


DEFAULT_EXEMPT = _default_exempt_trees()
EXEMPT_TREES = tuple(
    tree
    for tree in os.environ.get("GUARDRAILS_COMMENT_EXEMPT", DEFAULT_EXEMPT).split(":")
    if tree
)

HASH, SLASH, BLOCK, DASH, XML = r"#", r"//", r"/\*", r"--", r"<!--"
ERB = r"<%#"
C_FAMILY = [SLASH, BLOCK]

BY_EXTENSION = {
    "rb": [HASH], "rake": [HASH], "gemspec": [HASH], "ru": [HASH], "py": [HASH],
    "sh": [HASH], "bash": [HASH], "zsh": [HASH], "fish": [HASH], "pl": [HASH],
    "yml": [HASH], "yaml": [HASH], "tf": [HASH], "tfvars": [HASH], "toml": [HASH],
    "conf": [HASH], "ini": [HASH], "env": [HASH],
    "js": C_FAMILY, "mjs": C_FAMILY, "cjs": C_FAMILY, "jsx": C_FAMILY,
    "ts": C_FAMILY, "tsx": C_FAMILY, "go": C_FAMILY, "c": C_FAMILY, "h": C_FAMILY,
    "cc": C_FAMILY, "cpp": C_FAMILY, "hpp": C_FAMILY, "java": C_FAMILY,
    "kt": C_FAMILY, "swift": C_FAMILY, "rs": C_FAMILY, "scala": C_FAMILY,
    "php": C_FAMILY + [HASH],
    "css": [BLOCK], "scss": C_FAMILY, "sass": C_FAMILY,
    "sql": [DASH], "lua": [DASH], "hs": [DASH], "elm": [DASH],
    "ex": [HASH], "exs": [HASH], "r": [HASH], "ps1": [HASH],
    "dart": C_FAMILY, "cs": C_FAMILY, "proto": C_FAMILY, "jsonc": C_FAMILY,
    "html": [XML], "xml": [XML], "erb": [XML, ERB],
    "vue": [XML] + C_FAMILY, "svelte": [XML] + C_FAMILY,
}
BY_BASENAME = {
    "Gemfile": [HASH], "Rakefile": [HASH], "Dockerfile": [HASH],
    "Makefile": [HASH], "Procfile": [HASH], "Brewfile": [HASH],
}
ALL_PREFIXES = [HASH, SLASH, BLOCK, DASH, XML]

DOCSTRING_EXTENSIONS = {"py"}
RUBY_EXTENSIONS = {"rb", "rake", "gemspec", "ru"}

PRAGMAS = (
    "frozen_string_literal", "encoding", "coding", "typed:", "rubocop:", "noqa",
    "type:", "eslint-", "@ts-", "shellcheck", "pylint:", "prettier-ignore", "nolint",
)
DECORATION = re.compile(r"^[^A-Za-z@]+")

FILE_HEREDOC = re.compile(
    r"<<[-~]\s*[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)"
    r"|<<\s*[\x27\"]([A-Za-z_][A-Za-z0-9_]*)[\x27\"]"
)
BASH_HEREDOC = re.compile(
    r"(?<![0-9<])<<(?!<)([-~]?)\s*\\?([\x27\"]?)([A-Za-z_][A-Za-z0-9_]*)\2"
)
REDIRECT = re.compile(r"(?<![0-9<>&])(>>?)\s*([^\s|;&<>()]+)")
TEE = re.compile(r"\btee\b((?:\s+(?:-a|--append))*)\s+([^\s|;&<>()]+)")
OPERATOR = re.compile(r"^(?:>>?|<|\||\|\||&&|;)$")
ECHO = ("echo", "printf")

INTERPRETER = re.compile(r"\b(?:python3?|ruby|node|perl)\b")
WRITE_CALL = re.compile(r"\.write_text\(|\.write\(|open\(")
PATH_LITERAL = re.compile(r"[\x27\"]([^\x27\"\s]+\.[A-Za-z0-9]{1,8})[\x27\"]")
TRIPLE_QUOTED = re.compile(
    r'"""(.*?)"""' + "|" + r"\x27\x27\x27(.*?)\x27\x27\x27", re.S
)
DOCSTRING = re.compile(r'^[rRuUbBfF]{0,2}("""|\x27\x27\x27)')

DENIAL = """⛔ COMMENT DISCIPLINE — nothing was written. {problems}

Zero comments in code. Not "short comments" — none. Shebangs and pragmas ({pragmas}) are the \
only exempt lines. Rationale goes in the commit body and the pull-request description, where \
git blame finds it and a reader looking for it will actually look.

Do one of these, then retry:
  * delete it — if the commit message or PR body already says this, the comment is duplication
  * move it — paste it into the commit body you are about to write
  * make the code say it — name the value, extract a method, restructure

Docstrings count. A new one is a comment with different quoting.
Override for a genuine exception: GUARDRAILS_COMMENT_MAX_RUN=<n> allows runs up to n lines."""


def extension_of(path):
    base = os.path.basename(path)
    return base.rsplit(".", 1)[-1].lower() if "." in base else ""


def prefixes_for(path):
    return (
        BY_BASENAME.get(os.path.basename(path))
        or BY_EXTENSION.get(extension_of(path))
        or ALL_PREFIXES
    )


def language_known(path):
    return os.path.basename(path) in BY_BASENAME or extension_of(path) in BY_EXTENSION


def exempt(path):
    return path.endswith(EXEMPT_SUFFIXES) or path.startswith(EXEMPT_TREES)


def triple_open(stripped):
    for quote in ('"""', "'''"):
        if stripped.count(quote) % 2 == 1:
            return quote
    return None


def is_pragma(stripped, strip_prefix):
    if stripped.startswith("#!") or stripped.startswith("#["):
        return True
    body = DECORATION.sub("", strip_prefix.sub("", stripped, count=1))
    return body.startswith(PRAGMAS)


def comment_lines(text, path):
    prefixes = prefixes_for(path)
    matcher = re.compile(r"^\s*(?:" + "|".join(prefixes) + r")\s*\S")
    stripper = re.compile(r"^\s*(?:" + "|".join(prefixes) + r")\s*")
    extension = extension_of(path)
    found = set()
    terminator = None
    quote = None
    quote_is_docstring = False
    ruby_block = False
    star_block = False

    for index, line in enumerate(text.split("\n")):
        stripped = line.strip()

        if star_block:
            found.add(index)
            if "*/" in stripped:
                star_block = False
            continue

        if terminator is not None:
            if stripped == terminator:
                terminator = None
            continue

        if quote is not None:
            if quote_is_docstring:
                found.add(index)
            if quote in stripped:
                quote = None
            continue

        if ruby_block:
            found.add(index)
            if stripped.startswith("=end"):
                ruby_block = False
            continue

        heredoc = FILE_HEREDOC.search(line)
        if heredoc:
            terminator = heredoc.group(1) or heredoc.group(2)
            continue

        if extension in RUBY_EXTENSIONS and stripped.startswith("=begin"):
            ruby_block = True
            found.add(index)
            continue

        if extension in DOCSTRING_EXTENSIONS:
            triple = triple_open(stripped)
            if DOCSTRING.match(stripped):
                found.add(index)
                quote, quote_is_docstring = triple, True
                continue
            if triple:
                quote, quote_is_docstring = triple, False
                continue

        if matcher.match(line) and not is_pragma(stripped, stripper):
            found.add(index)

        if BLOCK in prefixes and "/*" in line and "*/" not in line.split("/*", 1)[1]:
            star_block = True

    return found


def added_indices(old, new):
    new_lines = new.split("\n")
    if not old:
        return set(range(len(new_lines)))
    added = set()
    opcodes = difflib.SequenceMatcher(
        None, old.split("\n"), new_lines, autojunk=False
    ).get_opcodes()
    for tag, _, _, start, end in opcodes:
        if tag in ("insert", "replace"):
            added.update(range(start, end))
    return added


def longest_run(indices):
    best_length, best_start = 0, indices[0]
    length, start = 0, indices[0]
    previous = None
    for index in indices:
        if previous is not None and index == previous + 1:
            length += 1
        else:
            length, start = 1, index
        if length > best_length:
            best_length, best_start = length, start
        previous = index
    return best_length, best_start


def disk_text(path):
    try:
        with open(path, errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def resolve(path, cwd):
    path = os.path.expanduser(path.strip("\"'"))
    return path if os.path.isabs(path) else os.path.normpath(os.path.join(cwd, path))


def redirect_target(line):
    match = TEE.search(line)
    if match:
        return match.group(2), bool(match.group(1).strip())
    match = REDIRECT.search(line)
    if match:
        return match.group(2), match.group(1) == ">>"
    return None, False


def echo_units(line):
    target, append = redirect_target(line)
    if not target:
        return []
    try:
        tokens = shlex.split(line, comments=False)
    except ValueError:
        return []
    if not tokens or os.path.basename(tokens[0]) not in ECHO:
        return []
    arguments = []
    for token in tokens[1:]:
        if OPERATOR.match(token):
            break
        if token.startswith("-"):
            continue
        arguments.append(token.replace("\\n", "\n"))
    if not arguments:
        return []
    return [(target, "\n".join(arguments), append)]


def interpreter_units(line, body):
    if not INTERPRETER.search(line) or not WRITE_CALL.search(body):
        return []
    literals = [first or second for first, second in TRIPLE_QUOTED.findall(body)]
    if not literals:
        return []
    units = []
    for match in PATH_LITERAL.finditer(body):
        target = match.group(1)
        if language_known(target):
            units += [(target, text, False) for text in literals]
    return units


def bash_units(command):
    lines = command.split("\n")
    units = []
    patches = []
    index = 0
    while index < len(lines):
        line = lines[index]
        opener = BASH_HEREDOC.search(line)
        if opener:
            indented, _, terminator = opener.groups()
            body = []
            index += 1
            while index < len(lines):
                candidate = lines[index]
                probe = candidate.strip() if indented else candidate.rstrip()
                if probe == terminator:
                    break
                body.append(candidate)
                index += 1
            text = "\n".join(body)
            target, append = redirect_target(line)
            if PATCH_COMMAND.search(line):
                patches.append(text)
            elif target:
                units.append((target, text, append))
            else:
                units += interpreter_units(line, text)
        else:
            units += echo_units(line)
        index += 1
    return units, patches


PATCH_COMMAND = re.compile(r"\b(?:git\s+(?:apply|am)|patch)\b")
PATCH_FILE = re.compile(r"^\*\*\*\s+(?:Add|Update|Delete)\s+File:\s*(\S.*?)\s*$")
PATCH_MOVE = re.compile(r"^\*\*\*\s+Move\s+to:\s*(\S.*?)\s*$")
PATCH_BEGIN = re.compile(r"^\*\*\*\s+Begin\s+Patch\s*$")
DIFF_FILE = re.compile(r"^\+\+\+\s+(?:b/)?(\S.*?)\s*$")


def patch_units(patch, cwd=None):
    collected = []
    current = None
    envelope = False

    for line in (patch or "").split("\n"):
        if PATCH_BEGIN.match(line):
            envelope = True
            continue

        header = PATCH_FILE.match(line)
        if header:
            current = {"path": header.group(1), "added": [], "removed": []}
            collected.append(current)
            continue

        move = PATCH_MOVE.match(line)
        if move and current is not None:
            current["path"] = move.group(1)
            continue

        if not envelope:
            diff = DIFF_FILE.match(line)
            if diff:
                current = {"path": diff.group(1), "added": [], "removed": []}
                collected.append(current)
                continue
            if line.startswith("---"):
                continue

        if current is None:
            continue
        if line.startswith("+"):
            current["added"].append(line[1:])
        elif line.startswith("-"):
            current["removed"].append(line[1:])

    units = []
    for entry in collected:
        if not entry["added"]:
            continue
        path = entry["path"]
        if cwd:
            path = resolve(path, cwd)
        units.append((path, "\n".join(entry["removed"]), "\n".join(entry["added"])))
    return units


def check_units(units):
    problems = []
    for path, old, new in units:
        if not path or exempt(path) or not new or not language_known(path):
            continue
        hits = sorted(added_indices(old, new) & comment_lines(new, path))
        if not hits:
            continue
        run, start = longest_run(hits)
        if run <= MAX_RUN:
            continue
        opening = new.split("\n")[start].strip()[:70]
        problems.append(
            "%s adds %d comment line(s) (longest run %d), starting: %s"
            % (path, len(hits), run, opening)
        )

    if not problems:
        return PASS
    return deny(DENIAL.format(problems=" ".join(problems), pragmas=", ".join(PRAGMAS)))


def check_write(path, content):
    return check_units([(path, disk_text(path), content)])


def check_shell(command, cwd):
    units = []
    writes, patches = bash_units(command or "")
    for target, text, append in writes:
        path = resolve(target, cwd)
        if language_known(path):
            units.append((path, "" if append else disk_text(path), text))
    for patch in patches:
        units += patch_units(patch, cwd)
    return check_units(units)
