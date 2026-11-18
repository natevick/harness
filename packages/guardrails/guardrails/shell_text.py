import re
from typing import NamedTuple

HEREDOC_OPENER = re.compile(
    r"(?<![0-9<])<<(?!<)([-~]?)[ \t]*(\\?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\3"
)
OPERATORS_IN_QUOTES = "|;&<>\n"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
LAUNCHERS = ("sudo", "env", "timeout", "nice", "nohup", "ionice", "stdbuf", "command", "xargs", "setsid")


def _blank(out, start, end):
    for index in range(start, min(end, len(out))):
        if out[index] != "\n":
            out[index] = " "


def _body_span(text, start, terminator, indented):
    index = start
    size = len(text)
    while index < size:
        end = text.find("\n", index)
        if end == -1:
            end = size
        probe = text[index:end].strip() if indented else text[index:end].rstrip()
        if probe == terminator:
            return start, index, min(end + 1, size)
        index = end + 1
    return start, size, size


def _walk(text):
    single, double, bodies, pending = [], [], [], []
    index, size = 0, len(text)

    while index < size:
        char = text[index]

        if char == "\\":
            index += 2
            continue

        if char == "'":
            closing = text.find("'", index + 1)
            if closing == -1:
                index += 1
                continue
            single.append((index, closing + 1))
            index = closing + 1
            continue

        if char == '"':
            cursor = index + 1
            while cursor < size:
                if text[cursor] == "\\":
                    cursor += 2
                    continue
                if text[cursor] == '"':
                    break
                cursor += 1
            double.append((index, min(cursor + 1, size)))
            index = cursor + 1 if cursor < size else size
            continue

        if char == "\n" and pending:
            index += 1
            for terminator, indented in pending:
                start, body_end, end = _body_span(text, index, terminator, indented)
                bodies.append((start, end, body_end))
                index = end
            pending = []
            continue

        opener = HEREDOC_OPENER.match(text, index)
        if opener:
            pending.append((opener.group(4), bool(opener.group(1))))
            bodies.append((opener.start(), opener.end(), opener.start()))
            index = opener.end()
            continue

        index += 1

    return single, double, bodies


def scannable(command):
    text = command or ""
    out = list(text)
    single, double, bodies = _walk(text)

    for start, end, _ in bodies:
        _blank(out, start, end)
    for start, end in single:
        _blank(out, start, end)
    for start, end in double:
        for index in range(start, min(end, len(out))):
            if out[index] in OPERATORS_IN_QUOTES:
                out[index] = " "
    return "".join(out)


def executable_text(command):
    text = command or ""
    out = list(text)
    _, _, bodies = _walk(text)
    for start, end, _ in bodies:
        _blank(out, start, end)
    return "".join(out)


def heredoc_bodies(command):
    text = command or ""
    _, _, bodies = _walk(text)
    return [text[start:body_end].rstrip("\n")
            for start, _, body_end in bodies if body_end > start]


PLACEHOLDER = "\x00"
SUBSTITUTION_OPENERS = ("$(", "<(", ">(")
REDIRECTION = re.compile(r"^(?:\d+|&)?[<>]")
REDIRECTION_OPERATOR = re.compile(r"^(?:\d+|&)?(?:>>|>|<)$")
DURATION = re.compile(r"^\d+(?:\.\d+)?[smhd]?$")
KEYWORDS = ("{", "!", "if", "then", "elif", "else", "do", "while", "until", "time", "exec")
VALUE_OPTIONS = {
    "sudo": ("-u", "-g", "-C", "-D", "-R", "-T", "-U", "-p", "-r", "-t", "-h", "--user", "--group"),
    "env": ("-u", "-C", "-S", "-P", "--unset"),
    "timeout": ("-s", "-k", "--signal", "--kill-after"),
    "nice": ("-n",),
    "ionice": ("-c", "-n", "-p", "-t"),
    "stdbuf": ("-i", "-o", "-e"),
    "xargs": ("-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s"),
}


class Command(NamedTuple):
    argv: list
    inner: list
    piped: bool


class _Unit:
    def __init__(self, piped=False):
        self.words, self.word, self.inner, self.piped = [], None, [], piped

    def add(self, text):
        self.word = (self.word or "") + text

    def flush(self):
        if self.word is not None:
            self.words.append(self.word)
            self.word = None

    def finish(self, found):
        self.flush()
        argv = _without_redirections(self.words)
        if argv or self.inner:
            found.append(Command(argv, self.inner, self.piped))


def _without_redirections(words):
    argv, skip = [], False
    for word in words:
        if skip:
            skip = False
        elif REDIRECTION.match(word):
            skip = bool(REDIRECTION_OPERATOR.match(word))
        else:
            argv.append(word)
    return argv


def _double_quoted(text, index):
    body, inner, cursor = [], [], index + 1
    while cursor < len(text):
        char = text[cursor]
        if char == '"':
            return "".join(body), inner, cursor + 1
        if char == "\\":
            body.append(text[cursor + 1:cursor + 2])
            cursor += 2
        elif text.startswith("$(", cursor) or char == "`":
            nested, cursor = _substitution(text, cursor)
            body.append(PLACEHOLDER)
            inner.extend(nested)
        else:
            body.append(char)
            cursor += 1
    return None


def _substitution(text, index):
    if text[index] == "`":
        return _parse(text, index + 1, "`")
    return _parse(text, index + 2, ")")


def _parse(text, index, closer):
    found, unit, depth, pending = [], _Unit(), 0, []
    while index < len(text):
        char, pair = text[index], text[index:index + 2]
        if (closer == ")" and char == ")" and depth == 0) or (closer == "`" and char == "`"):
            unit.finish(found)
            return found, index + 1
        if char == "\\":
            escaped = text[index + 1:index + 2]
            if escaped not in ("", "\n"):
                unit.add(escaped)
            index += 2
        elif char == "'" and text.find("'", index + 1) != -1:
            end = text.find("'", index + 1)
            unit.add(text[index + 1:end])
            index = end + 1
        elif char == '"' and (quoted := _double_quoted(text, index)):
            body, nested, index = quoted
            unit.add(body)
            unit.inner.extend(nested)
        elif char == "<" and (opener := HEREDOC_OPENER.match(text, index)):
            pending.append((opener.group(4), bool(opener.group(1))))
            index = opener.end()
        elif char == "\n" and pending:
            unit.finish(found)
            unit, index = _Unit(), index + 1
            for terminator, indented in pending:
                index = _body_span(text, index, terminator, indented)[2]
            pending = []
        elif pair in SUBSTITUTION_OPENERS or char == "`":
            nested, index = _substitution(text, index)
            unit.add(PLACEHOLDER)
            unit.inner.extend(nested)
        elif char == "#" and unit.word is None:
            end = text.find("\n", index)
            index = len(text) if end == -1 else end
        elif char == "&" and (text[max(index - 1, 0):index] in ("<", ">") or pair == "&>"):
            unit.add(char)
            index += 1
        elif char in ";&\n(" or pair == "||" or char == ")":
            unit.finish(found)
            unit = _Unit()
            index += 2 if pair in ("&&", "||") else 1
            depth = max(depth + (char == "(") - (char == ")"), 0)
        elif char == "|":
            unit.finish(found)
            unit = _Unit(piped=True)
            index += 2 if pair == "|&" else 1
        elif char in " \t\r":
            unit.flush()
            index += 1
        else:
            unit.add(char)
            index += 1
    unit.finish(found)
    return found, index


def commands(command):
    return _parse(executable_text(command), 0, None)[0]


def strip_prefixes(argv):
    tokens = list(argv)
    while tokens:
        head = tokens[0]
        name = head.rsplit("/", 1)[-1]
        if ASSIGNMENT.match(head) or head in KEYWORDS:
            tokens.pop(0)
            continue
        if name not in LAUNCHERS:
            break
        tokens.pop(0)
        options = VALUE_OPTIONS.get(name, ())
        while tokens and (tokens[0].startswith("-") or ASSIGNMENT.match(tokens[0])
                          or DURATION.match(tokens[0])):
            option = tokens.pop(0)
            if name == "command" and option in ("-v", "-V"):
                return []
            if option in options and tokens:
                tokens.pop(0)
    return tokens
