# Harnesses

Four harnesses speak Claude-shaped hook JSON with variations. One adapter,
`adapters/hookjson/`, serves all of them: `hookio.py` normalises the payload on the way in and
renders the verdict in the shape that harness reads on the way out.

Field shapes below come from the verified adapter spec and, where marked, from live runs recorded
in `tests/live/RESULTS.md`.

## What varies

| | Claude Code 2.1.259 | Codex 0.144.5 | Kimi Code 0.31.0 | grok 1.0.5 |
|---|---|---|---|---|
| Key casing | snake_case | snake_case | snake_case | **camelCase** |
| Event value | `PreToolUse` | `PreToolUse` | `PreToolUse` | `pre_tool_use` |
| Shell tool | `Bash` | `Bash` | `Bash` | `run_terminal_command` |
| Write tools | `Write`/`Edit`/`MultiEdit` | `apply_patch` | `Write`/`Edit` | `search_replace` |
| Path field | `file_path` | in the patch | **`path`** | `file_path` (unverified) |
| Tool output | `tool_response` | `tool_response` | `tool_output` | `toolResult` |
| Stop text | `last_assistant_message` | same | **none** | `lastAssistantMessage` |
| Deny shape | `hookSpecificOutput` | `hookSpecificOutput` | `hookSpecificOutput` | `{"decision":"deny"}` |
| Deny exit | 0 | 0 | 0 | 2 |
| Deny also on stderr | yes | yes | yes | yes |
| Registration | `settings.json` | `.codex/hooks.json` | `[[hooks]]` TOML | `.grok/hooks/*.json` |
| Project scope | yes | yes | **no** | yes, needs trust |

What the adapter emits, exactly: Claude Code, Codex and Kimi get `hookSpecificOutput` JSON on
stdout and **exit 0**; grok gets `{"decision":"deny","reason":...}` and **exit 2**. Every deny also
writes the reason to stderr, which is Kimi's documented fallback channel and what grok uses when
the JSON carries no reason. The universality rests on the stderr copy, not on the exit code being 2
everywhere.

## Codex `apply_patch`

Codex does not send `file_path` and `content` for an edit. It sends the entire patch as
`tool_input.command`, so the comment guard would see a shell command instead of file content.
`hookio.patch_units` parses the added lines per file and hands the comment guard `(path, "",
added)` triples. Both the `*** Add File:` / `*** Update File:` envelope and plain unified diff
headers are handled; only `+` lines are treated as new content.

The shell guards skip write tools, so a patch body containing a pipeline is never read as a
command.

## grok and the camelCase trap

grok loads `~/.claude/settings.json` and project `.claude/settings.local.json` hooks unchanged,
which reads as free compatibility and is not. The envelope is camelCase throughout, so a hook that
reads `tool_input.command` gets an empty string, denies nothing, and exits 0. That is fail-open,
and it is silent.

The live probe registers a stock snake_case Claude hook beside ours and records every invocation.
On a real grok `PreToolUse` it ran once and parsed zero commands while our normalised guard denied
the same call. Its own log of the keys it received:

```
cwd, hookEventName, permissionMode, sessionId, timestamp, toolInput,
toolInputTruncated, toolName, toolUseId, transcriptPath, workspaceRoot
```

## Harness detection

`hookio.detect` picks the output shape from the payload: camelCase markers or grok's tool
vocabulary mean grok, `apply_patch` means Codex, `tool_call_id`/`tool_output`/a bare `path` mean
Kimi, and anything else is treated as Claude-shaped. `GUARDRAILS_HARNESS` overrides all of it.

Codex and Claude Code are indistinguishable on a shell call — the payloads are identical — so a
Codex `Bash` event is labelled `claude` in the decision log. That costs nothing, because the two
read the same output shape. Set `GUARDRAILS_HARNESS=codex` if you want the log to say so.

## What we chose not to register

The templates in `adapters/hookjson/install/` leave out hooks that the harness cannot act on,
rather than registering a guard that can never fire:

- **grok**: no `UserPromptSubmit` (grok ignores its stdout and exit code) and no `PostToolUse`
  (passive in 1.0.5).
- **Kimi**: deny travels as `hookSpecificOutput` with exit 0, the spelling Kimi documents, with the
  reason on stderr as a fallback. No `PostToolUse` (fire-and-forget, cannot warn) and no `Stop` (the payload carries no
  assistant text, so the brevity and commitment guards have nothing to read). If you register the
  Stop guards anyway, they exit 0 and write one `harness sent no assistant text` line to
  `decisions.jsonl` per session, so the gap is visible rather than silent.

## Timeouts

Claude Code allows 600 s, grok defaults to 5 s (600 s for `Stop`), Kimi to 30 s. The templates set
`timeout` explicitly — 10 s for tool hooks, 30 s for stop gates — so an imported hook is not
killed by a default it never saw.

## What the shell-write scope does not cover

The comment guard reads shell writes it can see literally: heredocs (`cat > f <<EOF`, including
`<<\EOF` and `<<~EOF`), `tee`, `echo`/`printf` redirects, inline `python3 - <<PY` scripts calling
`write_text`, and `git apply` / `patch` heredoc bodies parsed as diffs.

It deliberately does not cover writes whose target or content only exists after shell expansion:

- `F=a.py; cat > "$F" <<EOF` — the target token is a variable, so the guard cannot know the
  extension without executing the shell.
- an inline `-c` program that opens a file and writes a comment into it — the content is a
  command-line string, not a heredoc body.
- an in-place stream editor inserting a line into a file the guard never sees the body of.

Widening the matcher to guess at these would trade a known gap for false denials on ordinary
commands. The gap is real: a write routed through any of those three reaches disk unguarded.

## Adapting the MCP matcher

`install/claude-code.json` matches outbound message tools by pattern —
`Bash|mcp__.*(?:slack_send_message|save_comment|save_issue)` — rather than by one installation's
server names. If your MCP servers expose different tool names, edit that matcher: it is a regular
expression tested against the tool name, and only the outbound-brevity guard uses it.
