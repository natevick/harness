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

The prompt gate warns on that shape. It does not block the submit. On 2026-10-27 the same
scan treated a bounded goal as that shape: "until" followed by "zero" fired on "loop until
`npm test` has zero failures, max 5 rounds" and on "loop until zero failing tests", and a
task that quoted "loop until clean" as an example was read as the instruction. Citations in
double quotes or backticks are removed before the sentence split, so a period inside
a citation is not a sentence break and cannot hide a cap or leak a quoted until-clause.
An until-clause outside a citation stands only when that sentence has no checkable
outcome and no cap. Checkable is a backtick
command, test, CI, build, lint, exit status, or a failure count. A cap is N rounds,
iterations, or attempts, with or without max, maximum, at most, or up to; a time or
token budget; or N minutes, hours, seconds, or tokens. N is digits or a number word
from one through twenty, then twenty through ninety by tens, plus hundred. Below a
level, nothing above a level, or previously known findings count only after stop
when, stop once, until, or done when.
"until clean", "until nothing", "until no more findings", "until you're satisfied",
"forever", and "indefinitely" still warn. "until the panel returns no findings" is the
note's own example and did not match, because "no findings" is not "no more". It matches
now. A cap does not silence "forever". The done-means vagueness scan uses the same rule, so
a checkable or capped until-clause is no longer rejected as vague there either.

The edit gate is the enforcement: a `done-means.json` with a concrete `done` sentence and a
passing review bound to the spec hash, before any other edit. A done claim re-runs the
checks and reverts the non-test diff in a temporary worktree: the checks must fail there
and pass after the diff is put back.
What is checked and what is only recorded is in [`done-means.md`](done-means.md).
Machine-generated prompt prefixes stay excluded.

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

## duplicates — the same block, copied

2026-10-22 simplicity pass, 39 duplicated-logic findings across 7 Selective PRs. Two of them are
the proof:

- selective-java-junit#1 finding 2. Test helpers copied across `ProtocolTest`, `ForkedSurefireIT`,
  `DiscoveryTest`, and `ClientRun`. The reviewed head `16199644aaa2` is not on the public repo.
  The public snapshot `c70deee` already keeps `batch`, `count`, `conformanceEnvironment`, and
  `repo` once, in `ClientRun`. The fixture copies those published method bodies back into the four
  classes the review names.
- selective-ruby-core#80 finding 1, at the reviewed commit `c2ff5fd8`. The `around` block that
  saves and restores ENV is byte-identical in `stdio_transport_spec.rb` and
  `stdio_controller_spec.rb`. `controller_spec.rb` and `stdio_binary_spec.rb` spell the same idea
  differently. Those two are not token clones. Not enforced.

Architecture cannot reach into those trees from this repo, and no type system is shared by Java
and Ruby (or by the other languages jscpd scans). The check wraps jscpd, fails only on a clone
that is not in the baseline, and the error names both blocks and says to extract one shared
helper. The Ruby fix in the fixture is the review's `with_env`. The Java fix leaves the helpers
on `ClientRun` only.

Clones already on this repo's main — the cursor and hookjson adapters, the installers, and a few
test harnesses — are fingerprints in `simplicity/duplicates-baseline.json`. They stay because
deleting them was not this change. A new clone is not in that file and fails.

## catch-ignore — an empty catch that pretends to handle

2026-10-22 simplicity pass, 8 catch-and-ignore findings. The proof is the before/after text in
the reviews, because those PR heads are not on the public snapshots:

- selective-js-vitest#1 finding 3: `catch { this.broken = true; }` around `stdin.end` and `kill`.
  The review deletes the try.
- finding 5: `catch (err) { if (err.missingTransport) {...} failures += 1; ...; continue; }`
  around `openStdio`. Node's `spawn` does not throw there. The review deletes the try.
- finding 6: `catch { void 0; }` around `child.kill`. The review calls `kill` and nothing else.
- selective-python-pytest#1 finding 1: `except Exception: pass` around `get_plugin`. The review
  deletes the try.
- selective-ruby-core#80 finding 11: `rescue IOError` then `nil` around a second `close`. The
  review deletes the rescue.

Java `catch (Exception ignored) {}` and Elixir `rescue _ -> nil` are in the same test so the five
languages the check claims are actually scanned. No Elixir review was attached.

A catch that rethrows, logs, or returns a value is not this failure. `return None` is a value.
`pass`, a literal assignment, a bare `return`, and `continue` are not. Empty is not.

The same limit as duplicates: nothing in this repo's types sees a `rescue` in Ruby or a `catch`
in Java. The check is the CI command. Its error says to handle it, rethrow it, or delete the try.

Swallows already on main are `simplicity/catch-ignore-baseline.json`. Each entry has a reason.
Most are "the state file is missing, so start from empty" or "a corrupt log line is skipped".
They were not introduced here, and this repo does not allow a new comment to mark them in place.
