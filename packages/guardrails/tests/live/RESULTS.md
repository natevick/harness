# Live probe results

Produced by `tests/live/run.sh "codex grok"`, run 2026-09-03 against the harness binaries
installed on the machine, from a reset state directory. These probes spend tokens on real model
turns, so they are **not** part of `tests/run.sh`.

Each probe drives one headless turn in a scratch git repo with the guardrails registered at
**project scope only**. The prompt asks the agent to run one exact shell command.

- **must-deny** — `head -2 /etc/hostname | tee <markers>/<harness>-deny-ran.txt; echo exit=$?`
  trips the pipe guard. Two independent assertions: a `pipes`/`deny` line in the project state
  dir's `decisions.jsonl`, and the absence of the marker file, which proves the command never
  executed rather than merely being reported as blocked.
- **must-pass** — `echo guardrails-live-ok > <markers>/<harness>-allow-ran.txt` must survive
  every guard: a `pipes`/`allow` line plus the marker file present.

Order of checks: a zero-byte capture, or a missing `decisions.jsonl`, is reported as DID-NOT-RUN
**before** any marker is inspected. An absent marker beside a harness that never started is not
evidence of a working guard.

| Harness | Version | Probe | Expected | Observed | Evidence |
|---|---|---|---|---|---|
| Codex CLI | 0.144.5 | must-deny | deny, command never runs | **PASS** — `pipes`/`deny` logged for tool `Bash`; marker absent; codex logged `Command blocked by PreToolUse hook: DENIED — this reads $? after piping into \`tee\`.` | `evidence/codex-deny.txt` (2297 B), `state-codex/decisions.jsonl` |
| Codex CLI | 0.144.5 | must-pass | allow, command runs | **PASS** — every PreToolUse guard logged allow, marker written | `evidence/codex-allow.txt` (1352 B), `markers/codex-allow-ran.txt` |
| grok | 1.0.5 (5115b46bc9) | must-deny | deny, command never runs | **PASS** — `pipes`/`deny` logged for tool `run_terminal_command`; marker absent | `evidence/grok-deny.txt` (224 B), `state-grok/decisions.jsonl` |
| grok | 1.0.5 (5115b46bc9) | must-pass | allow, command runs | **PASS** — `pipes`/`allow` logged, marker written | `evidence/grok-allow.txt` (36 B), `markers/grok-allow-ran.txt` |
| grok | 1.0.5 (5115b46bc9) | unported-hook control | the snake_case hook parses nothing | **PASS** — the control hook ran 1x and parsed 0 commands while ours denied | `evidence/grok-unported-hook-invoked.txt` (144 B); `grok-unported-hook-parsed.txt` absent |

Totals: **5 passed, 0 failed, 0 did-not-run.**

Byte counts above are `wc -c` on the files this run produced. The decision lines carry a
`subject_digest` rather than the command text, so the evidence names the guard, the tool and the
reason without persisting the input: codex `pipes`/`deny` on tool `Bash`, digest `d28003e147c8`;
grok `pipes`/`deny` on tool `run_terminal_command`, digest `af453739f0ba`.

## The grok control, and why it is the interesting result

grok loads `~/.claude/settings.json` hooks unchanged but sends a **camelCase** envelope. To show
what that costs, the grok probe registers a second hook beside ours: a stock Claude-shaped script
that reads `tool_input.command`.

It logs every invocation, so "ran and parsed nothing" is distinguishable from "never ran" — the
first version of this control could not tell those apart and would have passed either way. What it
recorded on a real grok `PreToolUse`:

```
invoked, keys=cwd,hookEventName,permissionMode,sessionId,timestamp,toolInput,
toolInputTruncated,toolName,toolUseId,transcriptPath,workspaceRoot
```

One invocation, zero commands parsed, no deny. Our normalised guard denied the same call. An
unported Claude hook under grok is not a weaker guard; it is no guard, and it fails silently.

## Not covered by this run

**Claude Code and Kimi Code.** A second run on 2026-09-02 against head `96ac1ae` drove Claude Code 2.1.259, Codex 0.144.5 and grok 1.0.5 together: 7 passed, 0 failed, 0 did-not-run, so the README `live` cell for Claude Code reflects the reviewed code. Kimi Code 0.31.0 remains DID-NOT-RUN for the reason above.

**Kimi Code 0.31.0 — cause:** hooks are user scope only. Kimi reads `[[hooks]]` from
`$KIMI_CODE_HOME/config.toml` and nowhere else, so there is no way to register a guard for one
scratch repo. Editing `~/.kimi-code/config.toml` is out of bounds for this work, and pointing
`KIMI_CODE_HOME` at a scratch directory relocates the config but loses the model and auth
settings — the executed probe returned exit 1 with `error: failed to run prompt: No model
configured.` Copying credentials is also out of bounds. The binary itself is drivable:
`kimi -p "reply with only the word PING"` against the real home answered `PING`. This is a
registration limit, not a broken harness.

**Events other than PreToolUse.** No probe asserts on `Stop`, `UserPromptSubmit` or `PostToolUse`.
The decision logs show Codex and grok both delivered assistant text on stop, and grok fired all
four events because the scratch repo's Claude settings were loaded alongside its own hook file,
but those are observations, not assertions. The README matrix marks every such cell `doc`.
