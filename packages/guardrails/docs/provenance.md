# Provenance

Every guard here was paid for by a specific failure. This file records what each one cost, so
that nobody deletes a rule because it reads like generic advice. Dates and numbers are taken
from the header comments of the original hooks.

## comments — zero comments in code

Rule adopted 2026-09-02: zero comments in code. Not "short comments" — none. Shebangs and
pragmas are the only exempt lines. Rationale belongs in the commit body and the pull-request
description, where `git blame` finds it and a reader looking for it will actually look.
Docstrings count: a new one is a comment with different quoting.

The guard's own blind spot is the reason it reads shell commands and not just file-write tool
calls. A measurement of one session found the file-write path saw **1 of 116** writes: the other
115 arrived as `cat > file <<'EOF'` heredocs, `tee`, `echo >`, and inline `python3 - <<PY`
scripts calling `write_text`. A guard that fires on a small fraction of the population and
reports no violations looks like protection and is not.

The single-line limit was tightened from a 3-line run to zero on 2026-09-02.

## pipes — `$?` after a pipe into a display filter

2026-08-05: four false passes in one day, one root cause — reading `$?` after a pipe and getting
the LAST element's status.

1. `shellcheck … | head -15; echo exit=$?` → head's 0, reported "shellcheck clean"
2. `./test-api.sh | tail -2; echo exit=$?` → tail's 0, hid an exit 2
3. a version-manager shim's own exit 1 read as a shellcheck finding
4. `grep -c '"result":'` matched `"result":null` in a 403 body → reported a denied scope as granted

Shellcheck cannot catch it. Verified against default, `--enable=all`, and
`--enable=check-extra-masked-returns` — none flag it, because `cmd | head; echo $?` is *correct*
shell. `$?` yielding the pipeline's last status is documented behaviour, not a defect. SC2181 is
on by default but fires only on `$?` inside a conditional, never on interpolation. And all four
failures were ad-hoc shell tool calls, not files in a repo, so a lint on checked-in scripts would
have seen none of them. It has to run on every shell call.

Deny, not ask: an agent in auto-approve mode resolves an "ask" itself, so an ask silently
degrades to "allowed" exactly when no human is watching. Only deny holds.

Narrow by design: a blanket "`$?` after any pipe" rule would deny legitimate code —
`cmd | grep -q x; [ $? -eq 0 ]` genuinely wants the last element's status. Intent is not in the
syntax. So it fires only when the pipeline's last stage is a display/format filter
(`head`/`tail`/`wc`/`cut`/…), which essentially always exits 0. Verified: pipefail is off by
default (`false | head` → `$?` = 0), so the hazard is real; with `set -o pipefail` present the
read becomes correct and the guard stands down.

## pkill — `pkill -f` matches the shell running it

2026-08-11: `/usr/bin/pkill -f 'watch-both.sh'` killed the agent's own shell tool call mid-run
(exit 144) and left the processes it targeted alive. `pgrep -f` has produced false process
readings at least four times, which is why it warns rather than passes silently.

Quoted spans are stripped before matching. The first version matched the words "not pkill -f"
inside an echo string and blocked a read-only `ps` command — the same defect as the truncation
guard firing on its own test data. Only real command positions count.

## truncation — output that landed exactly on its own cap

This is the failure that cost the most in one segfault investigation: 30 lines of a CI config
read and a trigger declared absent, 2 lines of a 4-call method grepped, and "no asset sync in CI"
reported off a narrow term list that had to be challenged twice. A hook cannot see the
conclusion, but it can see the truncation that licensed it.

It lives in a file, not `python3 -c '...'`: the first version embedded the logic in a
single-quoted shell string and the apostrophes in its own warning text terminated the program, so
the hook silently did nothing.

Two stand-downs were added after false fires. A heredoc-fed interpreter is a program, not a
pipeline: any `head -5` inside it is source code or test data — it fired on its own test harness
before that check existed. And in a compound command the other stages inflate the line count, so
the comparison against a single stage's cap is meaningless — it fired twice on
`echo …; grep -m1 …` before that check existed.

## brevity — the reply budget

Five escalations from the user, the last on 2026-09-02 calling the reply length "untenable".
Budget: 150 prose words per reply. Code fences and tables are excluded from the count, so a long
artifact is never miscounted — the number is prose the model wrote itself.

The guard measures the payload's `last_assistant_message` when the harness provides it, and falls
back to the transcript otherwise, waiting for the flush. An unflushed reply is logged as
`unmeasured`, loudly, rather than as a clean run: a harness that reports zero violations because
it measured nothing is the most expensive result there is, because it looks like success.

The block point moved from the budget to 2x the budget on 2026-09-03. A Stop hook runs after the
harness has already rendered the reply, so a block never prevents the long reply: the user sees
it, then sees the rewrite. "Seeing double is not a solution." Most overages are marginal —
158-174 words on a 150 budget in the session that prompted this — and there a rewrite buys
nothing and costs the duplicate. So a reply between the budget and `GUARDRAILS_BREVITY_BLOCK_AT`
times the budget is allowed through and recorded, and the next prompt carries a nudge naming the
count and the line; only past the line is the duplicate worth it. `0` turns blocking off and
keeps the record.

## review_brevity — the outbound-artifact budgets

Measured, not guessed: across 16 agent-written panel review bodies the prose ran 248-2017 words,
while the humans reviewing those same pull requests wrote 39-219.

Budgets: PR body 400, review body 200, inline review comment 150, PR/issue comment 150, chat
message 150, tracker comment 150, commit message 200, notification 150. Fenced code, diffs and
tables cost nothing, so evidence is free and only the claim is rationed. Every inline review
comment must also carry a `**Fix:**` line naming the edit the author would make; where no fix is
known yet, the action is the investigation, which is still an action.

## commitment — a promise with no mechanism

A verbal-only promise dies at session end, which means it never existed. Six of them did in one
48-hour window ending 2026-09-02.

Accepted mechanisms: a cron line or `crontab` entry, a scheduler call, a `/loop`, an absolute
path that exists on disk, a pull-request or issue URL, a `TASKS.md` row. The phrase "no
mechanism" is an accepted, honest downgrade — saying a thing is unowned is better than a promise
nobody will keep.

Offers are not commitments: "say the word and I'll do it" is waiting on the user, and the guard
skips those sentences.

## goals — unbounded work

Built 2026-07-31 after a goal of "run your own panel review until the panel comes back with no
more input" ran five review rounds, found something every round, and could not terminate — the
stop-time hook blocked stopping, so every attempt to finish produced one more action. The user's
words afterwards: "I should have given a stronger bounded end."

The failure is structural, not a lapse: on any adversarial process (review panels, fuzzing,
red-teaming, "find all the bugs"), "until it returns nothing" has no reachable end state.

This guard blocks nothing. It injects a note so the model raises the bound *before* starting,
rather than discovering the trap several hours in. On 2026-09-02 it false-fired on a
machine-generated task notification whose own text said "do not loop on it forever", which is why
machine-generated prompt prefixes are excluded.

## delegation — grinding instead of orchestrating

Heavy or parallelisable work belongs in a subagent. Two sessions measured on 2026-09-02 ran 94
and 983 consecutive inline shell calls with zero delegation. The threshold worth watching is
around 10; the nudge fires every 30 so it stays a reminder rather than noise, and any delegation
call resets the counter.

## The contract test

`tests/hook_stdin_contract_test.sh` exists because a hook shipped as `python3 - <<PY` with a body
that read `sys.stdin`. A heredoc *is* stdin, so the program read an empty string and the hook
never fired once. The test is a change-detector: it plants an offender and an innocent
`python3 -c` payload pipe on every run, and fails if it cannot tell them apart or if it had no
population to scan.
