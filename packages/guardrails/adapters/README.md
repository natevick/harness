# Adapters

The core in `guardrails/` knows nothing about any harness. It takes plain strings and paths and
returns a `Verdict` — `decision` of `allow`, `deny` or `warn`, plus a `reason`.

An adapter does three things and nothing else:

1. read the harness's event payload,
2. call the core function for that event,
3. render the `Verdict` in whatever shape the harness expects.

No policy lives in an adapter. A threshold, a regex or a message written here belongs in the core.

## `hookjson/` — the universal adapter

One adapter covers every harness that speaks Claude-shaped hook JSON: Claude Code, Codex CLI,
Kimi Code and grok. `hookio.py` holds all four dialects; the ten entry-point scripts are one
screen each and contain no harness knowledge at all.

`hookio.Event` normalises casing, event names, tool vocabulary and field names, exposing
`is_shell`, `is_write`, `command`, `path`, `write_units()`, `prompt`, `stdout` and the stop text.
`hookio.decide` logs the verdict, writes the reason to stderr, and emits the harness's own deny
shape with its own exit code. Field-by-field differences are in
[`../docs/harnesses.md`](../docs/harnesses.md).

## The contract

| Harness event | Core call | Verdict handling |
| --- | --- | --- |
| pre-shell (about to run a command) | `pipes.check_command(command)` | `deny` blocks the call |
| | `pkill.check_command(command)` | `deny` blocks; `warn` is advisory context |
| | `review_brevity.check_command(command)` | `deny` blocks the call |
| | `comments.check_shell(command, cwd)` | `deny` blocks the call |
| | `delegation.record_call(session)` | `warn` is advisory context |
| pre-file-write | `comments.check_units([(path, old, new), …])` | `deny` blocks the write |
| pre-message-send | `review_brevity.check_message(label, text[, budget])` | `deny` blocks the send |
| delegation event (subagent spawned) | `delegation.reset(session)` | no verdict |
| post-shell (command finished) | `truncation.check_output(command, stdout)` | `warn` is advisory context |
| stop (turn is ending) | `brevity.evaluate(text, session, source, uuid)` | `deny` should re-prompt the model |
| | `commitment.check_reply(text)` | `deny` should re-prompt the model |
| prompt-submit | `goals.check_prompt(prompt)` | `warn` is context prepended to the turn |
| | `brevity.streak_hint(session)` | `warn` is context prepended to the turn |

`deny` on a stop event means "the turn is not finished": the reason goes where the model will read
it, and the harness hands control back to the model rather than to the user. `warn` never blocks.

For a full-content write the adapter supplies the on-disk text as `old`, so only added lines
count. For an edit it supplies the tool's own before and after strings.

## State

Guards that keep state write to `$GUARDRAILS_STATE_DIR`, defaulting to
`${XDG_STATE_HOME:-$HOME/.local/state}/harness-guardrails`. Adapters must not choose a location.

## Adding a harness

If it speaks Claude-shaped hook JSON, extend `hookjson/hookio.py`: add its casing and tool names
to the normalizer, its deny shape to `decide`, and a registration template under
`hookjson/install/`. Add a case to `tests/normalizer_test.sh` proving the same guard payload in
that dialect reaches the same verdict, and a probe in `tests/live/run.sh`.

If it does not — Cursor's `beforeShellExecution`, Gemini's `BeforeTool`, OpenCode's in-process
plugins, Prime Agent's TypeScript extensions — it needs its own directory. Those contracts are the
subject of separate research and are deliberately not guessed at here: an adapter written from
assumption passes its own tests and fires on nothing real.
