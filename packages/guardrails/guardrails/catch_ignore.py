import hashlib
import os
import re
from pathlib import Path

MESSAGE = (
    "catch-and-ignore: %s:%d catch body swallows the error.\n"
    "Handle it, rethrow it, or delete the try."
)

MARKER = re.compile(r"catch-ignore-ok:\s*\S")

EXTENSIONS = {
    ".js": "js",
    ".jsx": "js",
    ".mjs": "js",
    ".cjs": "js",
    ".ts": "js",
    ".tsx": "js",
    ".mts": "js",
    ".cts": "js",
    ".py": "py",
    ".rb": "rb",
    ".rake": "rb",
    ".java": "java",
    ".ex": "ex",
    ".exs": "ex",
}

KEYWORDS = {
    "pass", "nil", "null", "true", "false", "undefined", "continue", "break",
    "return", "if", "else", "elsif", "elif", "end", "do", "then", "void",
    "True", "False", "None", "and", "or", "not", "in", "is",
}

LITERAL = (
    r"(?:true|false|null|nil|undefined|True|False|None|void\s+0|"
    r"\d+|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|:ok|:nil|:error)"
)

STATEMENT = re.compile(
    r"\s*(?:"
    r"pass|\.\.\.|nil|null|undefined|void\s+0|void\s*\(\s*0\s*\)|"
        r"continue|break|"
    r"return|"
    r":ok|:nil|:error|true|false|True|False|None|"
    r"[A-Za-z_$@][\w.$@]*\s*(?:\+\+|--|\+=\s*\d+|=(?:\s*" + LITERAL + r"))"
    r")",
    re.VERBOSE,
)


def message(path, line):
    return MESSAGE % (path, line)


def marked(text, line):
    rows = text.splitlines()
    start = max(1, line - 1)
    stop = min(len(rows), line)
    for number in range(start, stop + 1):
        if MARKER.search(rows[number - 1]):
            return True
    return False


def code_map(text, lang):
    code = [True] * len(text)
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if lang in ("py", "rb", "ex") and c == "#":
            while i < n and text[i] != "\n":
                code[i] = False
                i += 1
            continue
        if lang in ("js", "java") and c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                code[i] = False
                i += 1
            continue
        if lang in ("js", "java") and c == "/" and nxt == "*":
            code[i] = False
            code[i + 1] = False
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] != "\n":
                    code[i] = False
                i += 1
            if i + 1 < n:
                code[i] = False
                code[i + 1] = False
                i += 2
            continue
        if lang == "py" and text.startswith(('"""', "'''"), i):
            quote = text[i:i + 3]
            for offset in range(3):
                code[i + offset] = False
            i += 3
            while i < n and not text.startswith(quote, i):
                if text[i] != "\n":
                    code[i] = False
                i += 1
            if text.startswith(quote, i):
                for offset in range(3):
                    code[i + offset] = False
                i += 3
            continue
        if c in ('"', "'") or (lang == "js" and c == "`"):
            code[i] = False
            i += 1
            while i < n and text[i] != c:
                if text[i] == "\\" and i + 1 < n:
                    code[i] = False
                    code[i + 1] = False
                    i += 2
                    continue
                if text[i] != "\n":
                    code[i] = False
                i += 1
            if i < n:
                code[i] = False
                i += 1
            continue
        i += 1
    return code


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def has_call(body):
    for match in re.finditer(r"\b([A-Za-z_][\w]*)\s*\(", body):
        if match.group(1) not in KEYWORDS:
            return True
    return False


def consume_if(body, index):
    n = len(body)
    i = index + 2
    while i < n and body[i] in " \t\r\n":
        i += 1
    if i < n and body[i] == "(":
        depth = 0
        while i < n:
            if body[i] == "(":
                depth += 1
            elif body[i] == ")":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
    while i < n and body[i] in " \t\r\n":
        i += 1
    if i < n and body[i] == "{":
        i = consume_braces(body, i)
        if i is None:
            return None
    else:
        match = STATEMENT.match(body, i)
        if not match:
            return None
        i = match.end()
    while i < n and body[i] in " \t\r\n;":
        i += 1
    if body.startswith("else", i) and (i + 4 == n or not (body[i + 4].isalnum() or body[i + 4] == "_")):
        i += 4
        while i < n and body[i] in " \t\r\n":
            i += 1
        if body.startswith("if", i):
            return consume_if(body, i)
        if i < n and body[i] == "{":
            return consume_braces(body, i)
        match = STATEMENT.match(body, i)
        if not match:
            return None
        return match.end()
    return i


def consume_all(body):
    i = 0
    n = len(body)
    while i < n:
        while i < n and body[i] in " \t\r\n;":
            i += 1
        if i >= n:
            return True
        if body.startswith("if", i) and (i + 2 == n or not (body[i + 2].isalnum() or body[i + 2] == "_")):
            i = consume_if(body, i)
            if i is None:
                return False
            continue
        match = STATEMENT.match(body, i)
        if not match:
            return False
        i = match.end()
    return True


def returns_value(body):
    for match in re.finditer(r"\breturn\b", body):
        rest = body[match.end():].lstrip()
        if rest[:1] not in ("", ";", "}", "\n"):
            return True
    return False


def is_noop(body):
    body = re.sub(r"(?m)#.*$|//.*$", " ", body)
    if has_call(body) or returns_value(body):
        return False
    if re.search(r"\b(throw|raise|reraise)\b", body):
        return False
    return consume_all(body)


def consume_braces(body, index):
    if index >= len(body) or body[index] != "{":
        return None
    depth = 0
    start = index + 1
    i = index
    n = len(body)
    while i < n:
        if body[i] == "{":
            depth += 1
        elif body[i] == "}":
            depth -= 1
            if depth == 0:
                if not consume_all(body[start:i]):
                    return None
                return i + 1
        i += 1
    return None


def balanced(text, code, index, open_ch, close_ch):
    if index >= len(text) or text[index] != open_ch or not code[index]:
        return None
    depth = 0
    i = index
    n = len(text)
    while i < n:
        if not code[i]:
            i += 1
            continue
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def skip_ws(text, code, index):
    i = index
    n = len(text)
    while i < n and (text[i].isspace() or not code[i]):
        i += 1
    return i


def brace_catches(text, code, keyword):
    found = []
    for match in re.finditer(r"\b" + keyword + r"\b", text):
        index = match.start()
        if not code[index]:
            continue
        previous = index - 1
        while previous >= 0 and not code[previous]:
            previous -= 1
        if previous >= 0 and (text[previous] == "." or text[previous].isalnum() or text[previous] == "_"):
            continue
        cursor = skip_ws(text, code, match.end())
        if cursor < len(text) and text[cursor] == "(" and code[cursor]:
            end = balanced(text, code, cursor, "(", ")")
            if end is None:
                continue
            cursor = skip_ws(text, code, end + 1)
        if cursor >= len(text) or text[cursor] != "{" or not code[cursor]:
            continue
        end = balanced(text, code, cursor, "{", "}")
        if end is None:
            continue
        body = visible_span(text, code, cursor + 1, end)
        line = line_of(text, index)
        end_line = line_of(text, end)
        if is_noop(body) and not any(marked(text, item) for item in range(line, end_line + 1)):
            found.append((line, body))
    return found


def visible_span(text, code, start, end):
    parts = []
    i = start
    while i < end:
        if code[i]:
            parts.append(text[i])
            i += 1
            continue
        if text[i] in "\"'`":
            parts.append('""')
            i += 1
            while i < end and not code[i]:
                if text[i] == "\n":
                    parts.append("\n")
                i += 1
            continue
        parts.append("\n" if text[i] == "\n" else " ")
        i += 1
    return "".join(parts)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def python_excepts(text, code):
    lines = text.splitlines(keepends=True)
    offsets = []
    cursor = 0
    for line in lines:
        offsets.append(cursor)
        cursor += len(line)
    found = []
    for number, line in enumerate(lines, start=1):
        start = offsets[number - 1]
        stripped = "".join(
            line[pos] if code[start + pos] else " "
            for pos in range(len(line))
        )
        match = re.match(r"^(\s*)except\b[^:\n]*:([^\n]*)$", stripped)
        if not match:
            continue
        header_indent = len(match.group(1).expandtabs(4))
        inline = match.group(2).strip()
        if inline:
            body = inline
        else:
            chunks = []
            for follow in lines[number:]:
                raw = follow.splitlines()[0] if follow.endswith("\n") else follow
                if raw.strip() and indent_of(raw.replace("\t", "    ")) <= header_indent:
                    break
                chunks.append(raw)
            body = "\n".join(chunks)
        line_end = number + max(body.count("\n"), 0)
        if is_noop(body) and not any(marked(text, item) for item in range(number, line_end + 1)):
            found.append((number, body))
    return found


def following_block(lines, number):
    header = lines[number - 1]
    header_indent = indent_of(header.replace("\t", "    "))
    chunks = []
    stop = number
    for index in range(number, len(lines)):
        raw = lines[index]
        if not raw.strip():
            chunks.append(raw)
            stop = index + 1
            continue
        if indent_of(raw.replace("\t", "    ")) <= header_indent and re.match(
            r"\s*(rescue|else|ensure|end|after|catch|finally)\b", raw
        ):
            break
        chunks.append(raw)
        stop = index + 1
    return "\n".join(chunks), stop


def masked_line(text, code, lines, number):
    offset = sum(len(item) + 1 for item in lines[: number - 1])
    line = lines[number - 1]
    return "".join(
        line[pos] if offset + pos < len(code) and code[offset + pos] else " "
        for pos in range(len(line))
    )


def ruby_rescues(text, code):
    lines = text.splitlines()
    found = []
    for number, line in enumerate(lines, start=1):
        visible = masked_line(text, code, lines, number)
        leading = re.match(r"^(\s*)rescue\b(.*)$", visible)
        if leading and leading.group(1) == visible[: len(leading.group(1))]:
            if visible.strip().startswith("rescue"):
                body, _stop = following_block(lines, number)
                if is_noop(body) and not marked(text, number) and not any(
                    marked(text, item) for item in range(number, number + body.count("\n") + 1)
                ):
                    found.append((number, body))
                continue
        inline = re.search(r"(?<![\w.])rescue\b(.*)$", visible)
        if inline and visible[: inline.start()].strip():
            body = inline.group(1).strip()
            if is_noop(body) and not marked(text, number):
                found.append((number, body))
    return found


def elixir_arms(text, code):
    lines = text.splitlines()
    found = []
    for number, line in enumerate(lines, start=1):
        visible = masked_line(text, code, lines, number)
        if not re.match(r"\s*(rescue|catch)\b", visible):
            continue
        if not re.match(r"\s*(rescue|catch)\s*$", visible):
            continue
        section, _stop = following_block(lines, number)
        arrows = [match.start() for match in re.finditer(r"->", section)]
        if not arrows:
            body = section
            if is_noop(body) and not marked(text, number):
                found.append((number, body))
            continue
        line_starts = [0]
        for index, char in enumerate(section):
            if char == "\n":
                line_starts.append(index + 1)
        for position, arrow in enumerate(arrows):
            body_start = arrow + 2
            if position + 1 < len(arrows):
                next_arrow = arrows[position + 1]
                boundary = 0
                for start in line_starts:
                    if start <= next_arrow:
                        boundary = start
                body_end = boundary
            else:
                body_end = len(section)
            body = section[body_start:body_end]
            arm_line = number + section.count("\n", 0, arrow)
            if is_noop(body) and not marked(text, arm_line):
                found.append((arm_line, body))
    return found


def findings_in(text, lang):
    code = code_map(text, lang)
    if lang in ("js", "java"):
        return brace_catches(text, code, "catch")
    if lang == "py":
        return python_excepts(text, code)
    if lang == "rb":
        return ruby_rescues(text, code)
    if lang == "ex":
        return elixir_arms(text, code)
    return []


def glob_match(path, pattern):
    body = pattern
    prefix = ""
    if pattern.startswith("**/"):
        prefix = "(?:.*/)?"
        body = pattern[3:]
    regex = prefix + re.escape(body).replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    return re.fullmatch(regex, path) is not None


def ignored(path, patterns):
    normal = path.replace(os.sep, "/")
    for pattern in patterns:
        if glob_match(normal, pattern) or glob_match(os.path.basename(normal), pattern):
            return True
    return False


def fingerprint(path, header, body):
    normal = re.sub(r"\s+", " ", header + "\n" + body).strip()
    digest = hashlib.sha256(("%s\n%s" % (path, normal)).encode()).hexdigest()[:16]
    return digest


def header_text(text, line):
    rows = text.splitlines()
    if 1 <= line <= len(rows):
        return rows[line - 1]
    return ""


def scan_file(path, root, lang):
    text = path.read_text(encoding="utf-8", errors="replace")
    rel = os.path.relpath(path, root).replace(os.sep, "/")
    found = []
    for line, body in findings_in(text, lang):
        found.append({
            "path": rel,
            "line": line,
            "body": body,
            "fingerprint": fingerprint(rel, header_text(text, line), body),
            "message": message(rel, line),
        })
    return found


def iter_files(root, patterns):
    root = os.path.abspath(root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in (".git", "node_modules")]
        for name in filenames:
            ext = os.path.splitext(name)[1]
            lang = EXTENSIONS.get(ext)
            if lang is None:
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if ignored(rel, patterns):
                continue
            yield full, lang


def scan_paths(roots, patterns=None):
    patterns = patterns or []
    found = []
    for root in roots:
        root = os.path.abspath(root)
        for full, lang in iter_files(root, patterns):
            found.extend(scan_file(Path(full), root, lang))
    return found


def apply_baseline(found, counts):
    if counts is None:
        return found
    remaining = dict(counts)
    kept = []
    for item in found:
        key = item["fingerprint"]
        if remaining.get(key, 0) > 0:
            remaining[key] -= 1
            continue
        kept.append(item)
    return kept


def counts_of(found):
    counts = {}
    for item in found:
        counts[item["fingerprint"]] = counts.get(item["fingerprint"], 0) + 1
    return counts
