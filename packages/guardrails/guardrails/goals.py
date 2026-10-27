import os
import re

from . import PASS, deny, state_dir
from .comments import bash_units, patch_units, resolve
from .commitment import prose

MACHINE_PREFIXES = (
    "<task-notification",
    "<system-reminder",
    "[SYSTEM NOTIFICATION",
    "<local-command-",
)

EXHAUSTION = "a 'until it returns nothing' condition"
SUBJECTIVE = "a subjective completion condition"
OPEN_ENDED = "an open-ended duration"

AUTONOMY_MARKERS = (
    "/goal", "/loop", "keep going", "keep running", "repeat", "iterate",
    "each time", "every time",
)

UNBOUNDED_TERMINATORS = (
    (("until", "no more"), EXHAUSTION),
    (("until", "nothing"), EXHAUSTION),
    (("until", "zero"), EXHAUSTION),
    (("until", "no new"), EXHAUSTION),
    (("until", "no further"), EXHAUSTION),
    (("until", "empty"), EXHAUSTION),
    (("until", "clean"), EXHAUSTION),
    (("until", "you are satisfied"), SUBJECTIVE),
    (("until", "you're satisfied"), SUBJECTIVE),
    (("until", "i am satisfied"), SUBJECTIVE),
    (("forever",), OPEN_ENDED),
    (("indefinitely",), OPEN_ENDED),
    (("continuously",), OPEN_ENDED),
    (("non-stop",), OPEN_ENDED),
    (("nonstop",), OPEN_ENDED),
)

SUBJECTIVE_WORDS = (
    "clean", "cleaner", "better", "robust", "nice", "good", "improved",
    "solid", "polished", "satisfied", "happy",
)

MEASURABLE = re.compile(
    r"\b(?:tests?|pass(?:es|ed|ing)?|fails?|ci|build|exits?|status|lint)\b"
    r"|\b\d+\b"
    r"|`[^`]+`"
    r"|\b[\w./-]+\.[A-Za-z0-9]+\b",
    re.I,
)

WORK = re.compile(
    r"^(?:please\s+)?(?:implement|add|fix|build|create|refactor|ship|write|"
    r"update|change|remove|delete|make|finish|complete|introduce|port|migrate|loop)\b",
    re.I,
)

QUESTION = re.compile(
    r"^(?:what|why|how|when|where|who|explain|describe|summarize)\b",
    re.I,
)

DONE_CLAIM = re.compile(
    r"(?:^|\n)\s*done[.!]?\s*(?:\n|$)"
    r"|\b(?:this is done|task is done|work is done|ready for review|ready to merge|"
    r"all checks pass|i am done|i(?:'|’)m done)\b",
    re.I,
)

VAGUE = """DONE-MEANS GATE

This goal has no concrete final state: it names {kind}. Name an observable end
state before any work starts. A final state names a checkable outcome (a test
that exits 0, a file that exists, a CI check that is green). Words like clean,
better, or robust do not, and neither does "until zero failing".

Write done-means.json with a done sentence and at least one command, then a
passing review verdict, before editing any other file.
"""

NOTE = """<system-reminder>
UNBOUNDED-WORK GATE

This request sets up autonomous or repeating work whose stopping condition may not
be reachable: it names {kind}. Before doing ANY of the work, do this in your first
response:

1. Name the terminator you were given and say plainly whether it can be reached.
   "Until the panel returns no findings" is NOT reachable on an adversarial process
   — reviewers, fuzzers and scanners keep finding things, and each fix creates new
   surface. Same for "until it's clean" or "until you're satisfied".
2. Propose a BOUNDED replacement and get agreement. Good shapes:
     - a round/iteration cap ("3 rounds, then report")
     - a wall-clock or token budget
     - a severity floor ("stop when a round returns nothing above medium")
     - a diminishing-returns rule ("stop when a round's findings are all
       previously-known or below X")
3. State what you will deliver when the bound is hit, including the case where
   work is still outstanding. "I stopped at the cap with N items open" is a
   legitimate and expected outcome — not a failure to be worked around.
4. If a stop-time hook is enforcing the unbounded condition, say so explicitly: it
   will block stopping and push you into repeated one-more-action turns. The user
   must clear it; you cannot.

Do not silently accept the unbounded form and start working. Raising the bound
costs one exchange. Not raising it has cost a full session.
</system-reminder>"""


def ordered(text, needles):
    position = 0
    for needle in needles:
        found = text.find(needle, position)
        if found < 0:
            return False
        position = found + len(needle)
    return True


def subjective_only(text):
    lower = (text or "").lower()
    if not any(re.search(r"\b%s\b" % re.escape(word), lower) for word in SUBJECTIVE_WORDS):
        return False
    return MEASURABLE.search(text or "") is None


def vague_clause(text):
    lower = (text or "").lower()
    for needles, kind in UNBOUNDED_TERMINATORS:
        if ordered(lower, needles):
            return kind
    if subjective_only(text):
        return "only subjective completion words"
    return None


def vague_prompt(text):
    found = vague_clause(text)
    if found:
        return found
    if not MEASURABLE.search(text or ""):
        return "no observable end state"
    return None


def is_task(prompt):
    text = (prompt or "").lstrip()
    if not text or text.startswith(MACHINE_PREFIXES):
        return False
    lower = text.lower()
    if any(marker in lower for marker in AUTONOMY_MARKERS):
        return True
    if QUESTION.match(text):
        return False
    return bool(WORK.match(text))


def task_marker(session):
    key = re.sub(r"[^A-Za-z0-9_-]", "", str(session or ""))[:64] or "unknown"
    return os.path.join(state_dir(), "done-task-%s" % key)


def note_task(session):
    try:
        os.makedirs(state_dir(), mode=0o700, exist_ok=True)
        with open(task_marker(session), "w") as handle:
            handle.write("1")
    except OSError:
        return


def task_open(session):
    return os.path.exists(task_marker(session))


def shell_paths(command, cwd):
    writes, patches = bash_units(command or "")
    paths = [resolve(target, cwd or "") for target, _text, _append in writes]
    for patch in patches:
        paths.extend(unit[0] for unit in patch_units(patch, cwd))
    return paths


def claims_done(text):
    return bool(DONE_CLAIM.search(prose(text or "")))


def check_prompt(prompt, session=""):
    prompt = (prompt or "").lstrip()
    if not prompt or prompt.startswith(MACHINE_PREFIXES):
        return PASS
    if not is_task(prompt):
        return PASS

    note_task(session)
    reason = vague_prompt(prompt)
    if not reason:
        return PASS
    if reason in (EXHAUSTION, SUBJECTIVE, OPEN_ENDED):
        return deny(NOTE.format(kind=reason))
    return deny(VAGUE.format(kind=reason))


def check_start(cwd, session, paths):
    from . import done

    if done.stood_down():
        return PASS
    spec = done.locate(cwd)
    if not (task_open(session) or os.path.isfile(spec)):
        return PASS
    if paths and all(done.allowed_write(cwd, path) for path in paths):
        return PASS
    problems, _data = done.start_problems(cwd, spec)
    if problems:
        return deny(done.format_block(problems))
    return PASS


def check_stop(text, cwd):
    from . import done

    if done.stood_down() or not claims_done(text):
        return PASS
    problems, _data = done.finish_problems(cwd)
    if problems:
        return deny(done.format_block(problems))
    return PASS
