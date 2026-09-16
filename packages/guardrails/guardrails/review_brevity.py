import json
import os
import re
import shlex

from . import PASS, deny
from .brevity import prose_words
from .shell_text import heredoc_bodies

REVIEW_BODY_WORDS = int(os.environ.get("GUARDRAILS_REVIEW_BODY_WORDS", "200"))
REVIEW_COMMENT_WORDS = int(os.environ.get("GUARDRAILS_REVIEW_COMMENT_WORDS", "150"))
PR_BODY_WORDS = int(os.environ.get("GUARDRAILS_PR_BODY_WORDS", "400"))
COMMIT_BODY_WORDS = int(os.environ.get("GUARDRAILS_COMMIT_BODY_WORDS", "200"))
MESSAGE_WORDS = int(os.environ.get("GUARDRAILS_MESSAGE_WORDS", "150"))

REVIEWS_PATH = re.compile(r"/pulls/\d+/reviews\b")
COMMENTS_PATH = re.compile(r"/pulls/(\d+/)?comments\b")
FIX_LINE = re.compile(r"^\s*(\*\*|__)?fix:?", re.IGNORECASE | re.MULTILINE)
GATED_COMMAND = re.compile(r"\b(?:gh|git)\b")
GATED_NAMES = ("gh", "git")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OPERATORS = (";", "|", "||", "&&", "&")
CAT_SUBSTITUTION = re.compile(r"^\$\(\s*(?:/\S*/)?cat\s+([^)\s]+)\s*\)$")
NOTIFY_COMMANDS = tuple(
    name.strip()
    for name in os.environ.get("GUARDRAILS_NOTIFY_COMMANDS", "").split(",")
    if name.strip()
)
WRAPPERS = tuple(
    name.strip()
    for name in os.environ.get("GUARDRAILS_COMMAND_WRAPPERS", "").split(",")
    if name.strip()
)


class Unmeasurable:
    def __init__(self, detail):
        self.detail = detail

DENIAL = """⛔ BREVITY GUARD — nothing was sent. {problems}

Budgets: PR body 400, review body 200, inline review comment 150, PR/issue comment 150, \
chat message 150, tracker comment 150, commit message 200, notification 150.

Cut PROSE, not content — fenced code, diffs, tables and ```suggestion blocks cost nothing, so \
put the evidence in a block and spend the words on the claim and what it breaks. Lead with the \
result. One line per item. Depth goes in a file, not in the message. Findings belong on diff \
lines, not in the body, and every inline review comment needs a "**Fix:** …" line naming the \
edit the author would make — where no fix is known yet the action is the investigation \
("reproduce with X"), which is still an action.

Nothing is lost by retrying: the payload is on disk and the findings are still in it.
A body the hook cannot read is denied, not waved through: a guard that gives up on parsing and
allows is the failure this repository exists to prevent.

Override for a genuinely justified case: GUARDRAILS_ALLOW_LONG_REVIEW=1."""


def overridden():
    return bool(os.environ.get("GUARDRAILS_ALLOW_LONG_REVIEW"))


def flag_values(tokens, *names):
    found = []
    for index, token in enumerate(tokens):
        for name in names:
            if token == name and index + 1 < len(tokens):
                found.append(tokens[index + 1])
            elif token.startswith(name + "="):
                found.append(token[len(name) + 1:])
    return found


def flag_value(tokens, *names):
    values = flag_values(tokens, *names)
    return values[0] if values else None


def read_file(path):
    if not path or path.startswith("<("):
        return None
    try:
        with open(os.path.expanduser(path), errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def tokenize(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";|&")
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return []


def commands_in(command):
    found, current = [], []
    for token in tokenize(command):
        if token in OPERATORS:
            if current:
                found.append(current)
            current = []
            continue
        current.append(token)
    if current:
        found.append(current)
    return found


def unwrap(tokens):
    while tokens and ASSIGNMENT.match(tokens[0]):
        tokens = tokens[1:]
    if "--" in tokens:
        head = tokens[: tokens.index("--")]
        rest = tokens[tokens.index("--") + 1:]
        wrapper = bool(head) and (
            os.path.basename(head[0]) in WRAPPERS
            or os.path.basename(head[0]) not in GATED_NAMES
        )
        if wrapper and rest:
            return unwrap(rest)
    return tokens


def flag_values(tokens, *names):
    found = []
    for index, token in enumerate(tokens):
        for name in names:
            if token == name and index + 1 < len(tokens):
                found.append(tokens[index + 1])
            elif token.startswith(name + "="):
                found.append(token[len(name) + 1:])
    return found


def flag_value(tokens, *names):
    values = flag_values(tokens, *names)
    return values[0] if values else None


def field_value(tokens, name):
    for value in flag_values(tokens, "-f", "--field", "--raw-field", "-F", "--field-file"):
        if value.startswith(name + "="):
            return value[len(name) + 1:]
    return None


def from_source(reference, heredocs):
    if reference == "-":
        if heredocs:
            return heredocs[0]
        return Unmeasurable("its body was piped in and the hook cannot see it")
    text = read_file(reference)
    if text is None:
        return Unmeasurable("its body file %s could not be read" % reference)
    return text


def inline_text(value):
    substitution = CAT_SUBSTITUTION.match(value.strip())
    if not substitution:
        return value
    text = read_file(substitution.group(1))
    if text is None:
        return Unmeasurable("it inlines %s, which could not be read" % substitution.group(1))
    return text


def body_of(tokens, heredocs):
    reference = flag_value(tokens, "--body-file", "-F")
    if reference is not None:
        return from_source(reference, heredocs)
    inline = flag_value(tokens, "--body", "-b")
    if inline is not None:
        return inline_text(inline)
    field = field_value(tokens, "body")
    if field is not None:
        return inline_text(field)
    return None


def review_input(tokens, heredocs):
    reference = flag_value(tokens, "--input")
    field = field_value(tokens, "body")
    if reference is None and field is not None:
        return [("the review body", inline_text(field), REVIEW_BODY_WORDS)], []
    if reference is None:
        return [], []

    raw = from_source(reference, heredocs)
    if isinstance(raw, Unmeasurable):
        return [("the review payload", raw, REVIEW_BODY_WORDS)], []
    try:
        data = json.loads(raw)
    except ValueError:
        return [("the review payload", Unmeasurable("its --input is not JSON"),
                 REVIEW_BODY_WORDS)], []
    if not isinstance(data, dict):
        return [], []
    comments = [c for c in data.get("comments") or [] if isinstance(c, dict)]
    joined = " ".join(tokens)
    if not comments and REVIEWS_PATH.search(joined) is None:
        return [], [data]
    return [("the review body", data.get("body"), REVIEW_BODY_WORDS)], comments


def gh_checks(tokens, heredocs):
    joined = " ".join(tokens)
    if "api" in tokens and (REVIEWS_PATH.search(joined) or COMMENTS_PATH.search(joined)):
        return review_input(tokens, heredocs)

    pair = tuple(tokens[1:3])
    if pair == ("pr", "review"):
        return [("the review body", body_of(tokens, heredocs), REVIEW_BODY_WORDS)], []
    if pair in (("pr", "create"), ("pr", "edit")):
        return [("the PR body", body_of(tokens, heredocs), PR_BODY_WORDS)], []
    if pair in (("pr", "comment"), ("issue", "comment")):
        return [("the %s comment" % pair[0], body_of(tokens, heredocs), MESSAGE_WORDS)], []
    return [], []


def git_checks(tokens, heredocs):
    if tokens[1:2] != ["commit"]:
        return [], []
    reference = flag_value(tokens, "-F", "--file")
    if reference is not None:
        return [("the commit message", from_source(reference, heredocs), COMMIT_BODY_WORDS)], []
    messages = flag_values(tokens, "-m", "--message")
    if not messages:
        return [], []
    resolved = [inline_text(message) for message in messages]
    unmeasurable = next((m for m in resolved if isinstance(m, Unmeasurable)), None)
    if unmeasurable is not None:
        return [("the commit message", unmeasurable, COMMIT_BODY_WORDS)], []
    return [("the commit message", "\n".join(resolved), COMMIT_BODY_WORDS)], []


def notify_checks(tokens, heredocs):
    if "--notify" not in tokens:
        return [], []
    after = tokens[tokens.index("--notify") + 1:]
    text = "\n".join(token for token in after if not token.startswith("-"))
    return [("the notification", text or None, MESSAGE_WORDS)], []


def command_checks(tokens, heredocs):
    name = os.path.basename(tokens[0])
    if name == "gh":
        return gh_checks(tokens, heredocs)
    if name == "git":
        return git_checks(tokens, heredocs)
    if name in NOTIFY_COMMANDS:
        return notify_checks(tokens, heredocs)
    return [], []


def offences(items, comments):
    found = []
    for label, text, budget in items:
        if text is None:
            continue
        if isinstance(text, Unmeasurable):
            found.append("%s cannot be measured: %s" % (label, text.detail))
            continue
        words = prose_words(text)
        if words > budget:
            found.append("%s is %d prose words (budget %d)" % (label, words, budget))

    for index, comment in enumerate(comments, start=1):
        text = comment.get("body") or ""
        where = "%s:%s" % (comment.get("path", "?"), comment.get("line", "?"))
        words = prose_words(text)
        if words > REVIEW_COMMENT_WORDS:
            found.append("comment %d (%s) is %d prose words (budget %d)"
                         % (index, where, words, REVIEW_COMMENT_WORDS))
        if text and not FIX_LINE.search(text):
            found.append("comment %d (%s) names no fix" % (index, where))
    return found


def verdict_for(problems):
    if not problems:
        return PASS
    return deny(DENIAL.format(problems="; ".join(problems) + "."))


def check_command(command):
    command = command or ""
    gated = GATED_COMMAND.search(command) or any(
        name and name in command for name in NOTIFY_COMMANDS
    )
    if overridden() or not gated:
        return PASS

    heredocs = heredoc_bodies(command)
    items, comments = [], []
    for tokens in commands_in(command):
        tokens = unwrap(tokens)
        if not tokens:
            continue
        segment_items, segment_comments = command_checks(tokens, heredocs)
        items += segment_items
        comments += segment_comments

    return verdict_for(offences(items, comments))


def check_message(label, text, budget=MESSAGE_WORDS):
    if overridden() or text is None:
        return PASS
    return verdict_for(offences([(label, text, budget)], []))
