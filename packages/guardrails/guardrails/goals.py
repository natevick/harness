from . import PASS, warn

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


def check_prompt(prompt):
    prompt = (prompt or "").lstrip()
    if not prompt or prompt.startswith(MACHINE_PREFIXES):
        return PASS

    lower = prompt.lower()
    if not any(marker in lower for marker in AUTONOMY_MARKERS):
        return PASS

    for needles, kind in UNBOUNDED_TERMINATORS:
        if ordered(lower, needles):
            return warn(NOTE.format(kind=kind))
    return PASS
