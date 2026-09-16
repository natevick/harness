import os
import re

from . import PASS, deny

PROMISE = [
    (re.compile(r"\bI(?:'|’)ll\s+\w", re.I), "I'll …"),
    (re.compile(r"\bI\s+will\b", re.I), "I will …"),
    (re.compile(r"\bI(?:'|’)m\s+going\s+to\b", re.I), "I'm going to …"),
    (re.compile(r"\bI\s+am\s+going\s+to\b", re.I), "I am going to …"),
    (re.compile(r"\bwe(?:'|’)ll\s+\w", re.I), "we'll …"),
    (re.compile(r"\bwe\s+will\b", re.I), "we will …"),
    (re.compile(r"\bI\s+plan\s+to\b", re.I), "I plan to …"),
]

SCHEDULED = [
    (re.compile(r"\blater\s+today\b", re.I), "later today"),
    (re.compile(r"\bin\s+the\s+morning\b", re.I), "in the morning"),
    (re.compile(r"\btomorrow\b", re.I), "tomorrow"),
    (re.compile(r"\bovernight\b", re.I), "overnight"),
    (re.compile(r"\bshortly\b", re.I), "shortly"),
    (re.compile(r"\bfollow[ -]up\b", re.I), "follow up"),
]

FIRST_PERSON = re.compile(r"\b(?:I|I(?:'|’)m|we|we(?:'|’)re)\b", re.I)

OFFER = re.compile(
    r"\bsay\s+(?:the\s+word|ship|so|otherwise|which|when|yes|no)\b"
    r"|\bif\s+you\b|\bonce\s+you\b|\bwhen\s+you\b|\bunless\s+you\b"
    r"|\byou\s+say\b|\byour\s+call\b|\btell\s+me\b|\bwant\s+me\s+to\b",
    re.I,
)

DEFAULT_MECHANISMS = "crontab,cron,CronCreate,ScheduleWakeup,/loop,TASKS.md"
DOWNGRADE = re.compile(r"\bno\s+mechanism\b", re.I)
MECHANISM_NAMES = tuple(
    name.strip()
    for name in os.environ.get("GUARDRAILS_COMMITMENT_MECHANISMS", DEFAULT_MECHANISMS).split(",")
    if name.strip()
)
MECHANISM_WORDS = re.compile(
    "|".join(re.escape(name) for name in MECHANISM_NAMES) or r"(?!x)x", re.I
)
TRACKER_URL = re.compile(
    r"https?://(?:www\.)?github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d+", re.I
)
ABSOLUTE_PATH = re.compile(r"(?:^|(?<=[\s`'\"(\[]))(/[^\s`'\"<>)\],;]+)", re.M)
CRON_FIELD = r"[\d*/,\-]+"
CRON = re.compile(
    r"(?:^|[\s`\"'(])(%s)\s+(%s)\s+(%s)\s+(%s)\s+([\dA-Za-z*/,\-]+)(?=$|[\s`\"')])"
    % (CRON_FIELD, CRON_FIELD, CRON_FIELD, CRON_FIELD),
    re.M,
)

BLOCK = (
    "Commitment without a mechanism: '{phrase}'. Build one (cron, task, file, PR) or "
    "downgrade the language.\n\n"
    "A verbal-only promise dies at session end, which means it never existed. Mechanisms this "
    "guard accepts: {mechanisms}, a cron expression, an absolute path that exists on disk, a "
    "pull-request or issue URL, or a tracked issue or task file. If none of those is warranted, "
    "say so in the reply \u2014 the words \"no mechanism\" are an accepted, honest downgrade."
)


def prose(markdown):
    kept, fenced = [], False
    for line in markdown.split("\n"):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced or line.lstrip().startswith(">"):
            continue
        kept.append(line)
    return "\n".join(kept)


def sentences(text):
    return [s for s in re.split(r"(?<=[.!?])\s+|\n+", text) if s.strip()]


def has_cron(text):
    for match in CRON.finditer(text):
        if sum(1 for field in match.groups() if "*" in field or "/" in field) >= 2:
            return True
    return False


def has_existing_path(text):
    for match in ABSOLUTE_PATH.finditer(text):
        candidate = match.group(1).rstrip(".,:;")
        if len(candidate) > 1 and os.path.exists(candidate):
            return True
    return False


def mechanism(text):
    return bool(
        DOWNGRADE.search(text)
        or MECHANISM_WORDS.search(text)
        or TRACKER_URL.search(text)
        or has_cron(text)
        or has_existing_path(text)
    )


def commitment(text):
    for sentence in sentences(prose(text)):
        if OFFER.search(sentence):
            continue
        for pattern, label in PROMISE:
            if pattern.search(sentence):
                return label, sentence.strip()
        if FIRST_PERSON.search(sentence):
            for pattern, label in SCHEDULED:
                if pattern.search(sentence):
                    return label, sentence.strip()
    return None, None


def check_reply(text):
    if not text:
        return PASS

    label, sentence = commitment(text)
    if label is None or mechanism(text):
        return PASS

    phrase = sentence if len(sentence) <= 140 else sentence[:137] + "..."
    return deny(BLOCK.format(phrase=phrase, mechanisms=", ".join(MECHANISM_NAMES)))
