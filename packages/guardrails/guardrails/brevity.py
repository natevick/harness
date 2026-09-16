import json
import os
import re
import time
from datetime import datetime, timezone

from . import PASS, deny, state_dir, warn

BUDGET = int(os.environ.get("GUARDRAILS_BREVITY_BUDGET", "150"))
BLOCK_AT = float(os.environ.get("GUARDRAILS_BREVITY_BLOCK_AT", "2.0"))
STALE_AFTER_SECONDS = 3600

TABLE_RULE = re.compile(r"^[-|: ]+$")

BLOCK = (
    "Reply was {words} prose words, budget {budget}. "
    "Rewrite: lead with the result, one line per item, put depth in a file. "
    "({nth} over-budget reply this session.)"
)

HINT = (
    "BREVITY (guard: brevity) — your previous reply was {words} prose words, {over}x the "
    "{budget}-word budget; {tier}. That is the {nth} over-budget reply this session.\n"
    "Prose words only; code blocks and tables are already excluded, so this is not a long "
    "artifact being miscounted — it is {words} words of your own writing.\n"
    "Answer what was asked and stop. One line per item. No preamble, no restating what you "
    "just did, no 'worth noting' asides. If it needs more than ~{budget} words, it belongs in "
    "a file, not a message."
)

TIER_ALLOWED = "allowed through, but over {limit} words it would have been blocked"
TIER_BLOCKED = "blocked for passing {limit} words, and rewritten"
TIER_UNBLOCKABLE = "allowed through; blocking is off"


def prose_words(markdown):
    total, fenced = 0, False
    for line in str(markdown).split("\n"):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("|") or TABLE_RULE.match(stripped):
            continue
        total += len(stripped.split())
    return total


def ordinal(count):
    return {1: "1st", 2: "2nd", 3: "3rd"}.get(count, "%dth" % count)


def tier_text(blocked, budget, block_at):
    if block_at <= 0:
        return TIER_UNBLOCKABLE
    template = TIER_BLOCKED if blocked else TIER_ALLOWED
    return template.format(limit=int(budget * block_at))


def session_key(session):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(session))[:64]


def log_path():
    return os.path.join(state_dir(), "brevity.jsonl")


def state_path(session):
    return os.path.join(state_dir(), "brevity-last-%s.json" % (session_key(session) or "unknown"))


def open_private(path, mode):
    descriptor = os.open(path, mode, 0o600)
    return os.fdopen(descriptor, "w" if mode & os.O_TRUNC else "a")


def append_log(entry):
    try:
        with open_private(log_path(), os.O_CREAT | os.O_APPEND | os.O_WRONLY) as handle:
            handle.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def write_state(session, values):
    try:
        with open_private(
            state_path(session), os.O_CREAT | os.O_TRUNC | os.O_WRONLY
        ) as handle:
            json.dump(values, handle)
    except OSError:
        pass


def read_state(session):
    try:
        with open(state_path(session)) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def last_seen_uuid(session):
    return read_state(session).get("uuid")


def violations_this_session(session):
    count = 0
    try:
        with open(log_path()) as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("session") == session and entry.get("over"):
                    count += 1
    except OSError:
        return 1
    return count


def evaluate(text, session, source="payload", uuid=None):
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        os.makedirs(state_dir(), mode=0o700, exist_ok=True)
        os.chmod(state_dir(), 0o700)
    except OSError:
        pass

    if text is None:
        append_log({"ts": now, "session": session, "source": source, "status": "unmeasured",
                    "words": None, "budget": BUDGET, "over": False})
        write_state(session, {"session": session, "ts": now, "source": source,
                              "uuid": uuid, "words": 0, "budget": BUDGET, "count": 0})
        return PASS

    words = prose_words(text)
    over = words > BUDGET
    blocked = BLOCK_AT > 0 and words > BUDGET * BLOCK_AT
    append_log({"ts": now, "session": session, "source": source, "status": "measured",
                "words": words, "budget": BUDGET, "over": over, "blocked": blocked,
                "characters": len(text)})

    count = violations_this_session(session) if over else 0
    write_state(session, {"session": session, "ts": now, "source": source, "uuid": uuid,
                          "words": words, "budget": BUDGET, "count": count,
                          "blocked": blocked, "block_at": BLOCK_AT})

    if not blocked:
        return PASS
    return deny(BLOCK.format(words=words, budget=BUDGET, nth=ordinal(count)))


def streak_hint(session):
    if not session_key(session):
        return PASS

    path = state_path(session)
    try:
        if time.time() - os.path.getmtime(path) > STALE_AFTER_SECONDS:
            return PASS
        with open(path) as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return PASS

    words = state.get("words", 0)
    budget = state.get("budget", 150)
    count = state.get("count", 1)
    if not words or not budget or words <= budget:
        return PASS

    tier = tier_text(state.get("blocked", False), budget, state.get("block_at", BLOCK_AT))
    return warn(HINT.format(words=words, over=round(words / budget, 1),
                            budget=budget, nth=ordinal(count), tier=tier))
