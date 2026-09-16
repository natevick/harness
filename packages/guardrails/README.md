# harness-guardrails

[![tests](https://github.com/natevick/harness-guardrails/actions/workflows/test.yml/badge.svg)](https://github.com/natevick/harness-guardrails/actions/workflows/test.yml)

These are rules a model cannot talk itself out of. Every guard exists because of a specific failure, recorded in [`docs/provenance.md`](docs/provenance.md). They come from running agents on real work, and from reading how the harnesses actually behave.

Python 3.10+, standard library only. One core, adapters for Claude Code, Codex CLI, Kimi Code, and grok. Kimi has not been probed live; the coverage table says so.

The comments guard is the reason this repo exists. A Claude Code hook on `Write|Edit` saw **1 of 116** file writes in a measured session. The other 115 arrived as shell heredocs. A hook that reports no violations because it never saw the writes is not a hook.

## The guards

| Guard | Fires on | Verdict |
| --- | --- | --- |
| `comments` | a comment or docstring added by a file write, a shell heredoc, a `git apply` patch, or a Codex patch | deny |
| `pipes` | reading `$?` after piping into `head`/`tail`/`wc`/`cut`/… | deny |
| `pkill` | `pkill -f`, which matches the shell running it | deny (`pgrep -f` warns) |
| `review_brevity` | an over-budget PR body, review, comment, commit message or chat message | deny |
| `brevity` | a reply over the prose-word budget | nudge at next prompt; deny at stop past 2x |
| `commitment` | "I'll do X" with no cron, task, file, PR or explicit downgrade | deny at stop |
| `truncation` | a command whose output landed exactly on its own `head -n` cap | warn |
| `goals` | a request to loop "until it returns nothing" | warn at prompt-submit |
| `delegation` | 30 consecutive shell calls with no subagent | warn |

## Coverage

`live` = probed in [`RESULTS.md`](tests/live/RESULTS.md), which covers only `pipes` on a pre-shell
event. `doc` = documented, not probed. `silent` = unregistered, because the harness cannot act on
it. See [`docs/harnesses.md`](docs/harnesses.md).

| Guard | Claude Code 2.1.259 | Codex 0.144.5 | Kimi Code 0.31.0 | grok 1.0.5 |
| --- | --- | --- | --- | --- |
| `pipes` | enforced (live) | enforced (live) | enforced (doc) | enforced (live) |
| `pkill` | enforced (doc) | enforced (doc) | enforced (doc) | enforced (doc) |
| `comments` | enforced (doc) | enforced (doc, patch parsed) | enforced (doc) | enforced (doc) |
| `review_brevity` | enforced (doc) | enforced (doc) | enforced (doc) | enforced (doc) |
| `brevity` | enforced (doc) | enforced (doc) | **silent** — no stop text | enforced (doc) |
| `commitment` | enforced (doc) | enforced (doc) | **silent** — no stop text | enforced (doc) |
| `truncation` | warns (doc) | warns (doc) | **silent** — fire-and-forget | **silent** — passive in 1.0.5 |
| `goals` | warns (doc) | warns (doc) | warns (doc) | **silent** — output ignored |
| `delegation` | warns (doc) | warns (doc) | unverified | **silent** — no warn channel |

grok loads Claude settings hooks unchanged but sends **camelCase**: an unported Claude hook parses
nothing and fails open. A live control hook read zero commands while ours denied the same call.

## Install

```sh
adapters/hookjson/install.sh --harness codex
adapters/hookjson/install.sh --harness codex --target .codex/hooks.json
```

Harnesses: `claude-code`, `codex`, `kimi`, `grok`. No `--target` prints the snippet; an existing
file needs `--force`, which backs it up and replaces this pack's entries by script name. Python
3.10+ is checked first and the checkout path is quoted. Adapt the `claude-code` MCP matcher to
your server names.

## Tests

```sh
tests/run.sh        # offline, no tokens
tests/live/run.sh   # real harness turns, spends tokens
```

The offline runner uses a temporary state directory and fails any test file that produces no
pass/fail summary — a suite that reports nothing because it ran nothing.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `GUARDRAILS_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/harness-guardrails` | counters, logs, decision trail |
| `GUARDRAILS_HARNESS` | detected | force the output shape |
| `GUARDRAILS_LOG_DECISIONS` | unset | also record allows in `decisions.jsonl` |
| `GUARDRAILS_BREVITY_BUDGET` | `150` | prose words per reply |
| `GUARDRAILS_BREVITY_BLOCK_AT` | `2.0` | multiple of the budget past which a reply is blocked; `0` never blocks, only records |
| `GUARDRAILS_BREVITY_FLUSH_WAIT` | `2` | seconds to wait for a transcript flush |
| `GUARDRAILS_COMMENT_MAX_RUN` | `0` | longest run of added comment lines allowed |
| `GUARDRAILS_COMMENT_EXEMPT` | `/tmp/` | colon-separated exempt path prefixes |
| `GUARDRAILS_PR_BODY_WORDS` | `400` | PR body budget |
| `GUARDRAILS_REVIEW_BODY_WORDS` | `200` | review body budget |
| `GUARDRAILS_REVIEW_COMMENT_WORDS` | `150` | inline review comment budget |
| `GUARDRAILS_COMMIT_BODY_WORDS` | `200` | commit message budget |
| `GUARDRAILS_MESSAGE_WORDS` | `150` | comment, chat and notification budget |
| `GUARDRAILS_ALLOW_LONG_REVIEW` | unset | stand the outbound-brevity guard down |
| `GUARDRAILS_ALLOW_PKILL_F` | unset | allow `pkill -f` |
| `GUARDRAILS_COMMITMENT_MECHANISMS` | `crontab,cron,CronCreate,ScheduleWakeup,/loop,TASKS.md` | names that count as a mechanism |
| `GUARDRAILS_COMMAND_WRAPPERS` | unset | wrapper commands to look past before `gh`/`git` |
| `GUARDRAILS_NOTIFY_COMMANDS` | unset | commands whose `--notify` text is budgeted |
| `GUARDRAILS_COMMITMENT_MECHANISMS` | `crontab,cron,scheduled,/loop` | comma-separated names that count as a mechanism |
| `GUARDRAILS_COMMAND_WRAPPERS` | empty | wrapper commands to look through before `gh`/`git` |
| `GUARDRAILS_NOTIFY_COMMANDS` | empty | commands whose `--notify` text is budgeted |

`decisions.jsonl` stores a truncated SHA-256 of the command, not the command; state files are 0600
in a 0700 directory. Shell writes needing expansion are out of scope — see
[`docs/harnesses.md`](docs/harnesses.md).

## Adding a harness

See [`adapters/README.md`](adapters/README.md).

## Licence

MIT.
