import re
import shlex

HEREDOC_OPENER = re.compile(
    r"(?<![0-9<])<<(?!<)([-~]?)[ \t]*(\\?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\3"
)
OPERATORS_IN_QUOTES = "|;&<>\n"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
LAUNCHERS = ("sudo", "env", "timeout", "nice", "nohup", "ionice", "stdbuf", "command", "xargs")


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


SUBSTITUTION = re.compile(r"\$\(|[`()]")


def _plain_tokens(text):
    spaced = re.sub(r"([;|&])", r" \1 ", text.replace("'", " ").replace('"', " "))
    return spaced.split()


def segments(command):
    text = SUBSTITUTION.sub(";", executable_text(command)).replace("\n", ";")
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";|&")
    lexer.whitespace_split = True
    lexer.commenters = ""

    tokens = []
    while True:
        try:
            token = lexer.get_token()
        except ValueError:
            tokens = _plain_tokens(text)
            break
        if not token:
            break
        tokens.append(token)

    found, current = [], []
    for token in tokens:
        if all(char in ";|&" for char in token):
            if current:
                found.append(current)
            current = []
            continue
        current.append(token)
    if current:
        found.append(current)
    return found


def strip_prefixes(argv):
    tokens = list(argv)
    while tokens:
        head = tokens[0]
        if ASSIGNMENT.match(head):
            tokens.pop(0)
            continue
        if head.rsplit("/", 1)[-1] in LAUNCHERS:
            tokens.pop(0)
            while tokens and (tokens[0].startswith("-") or ASSIGNMENT.match(tokens[0])
                              or tokens[0].replace(".", "", 1).isdigit()):
                tokens.pop(0)
            continue
        break
    return tokens
