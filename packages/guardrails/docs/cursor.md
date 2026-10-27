# Cursor

Cursor does not speak Claude-shaped hook JSON. `adapters/cursor/` reads Cursor's payload and
emits Cursor's verdict. No threshold or regex lives there.

The shapes below were checked three ways. **Live** means a hook in this cloud agent actually ran
and the bytes were read back. **Daemon** means the check is the exec-daemon source on that VM
(`cursor_version` `1.0.0`), not a fired event. **Docs** means [Cursor's hooks page](https://cursor.com/docs/hooks)
and the [third-party hooks page](https://cursor.com/docs/reference/third-party-hooks), read
2026-10-21, where the daemon and the live run did not contradict them.

## Where hooks load

| Source | Path | Live on a cloud agent |
| --- | --- | --- |
| Project | `<repo>/.cursor/hooks.json` | Fired, after `ReloadAgentSkills`. A file written mid-command did not see that command's pre-hook. |
| Claude project | `<repo>/.claude/settings.json` and `.claude/settings.local.json` | Fired. The script received Cursor's payload, not Claude's. |
| User | `~/.cursor/hooks.json` | Did not fire. Docs say cloud VMs do not load your laptop's home directory. |
| User Claude | `~/.claude/settings.json` | Not fired in this run. The daemon has the path. |
| Enterprise / team | `/etc/cursor/hooks.json`, `~/.cursor/managed/active-team-hooks/hooks.json` | Not fired. Docs: Enterprise cloud agents run these. |

Project commands run from the repo root. The daemon reads hooks at process start and again on
`ReloadAgentSkills`. It does not watch the file. Desktop Cursor does watch `hooks.json`; that
reload was not what this VM did.

A cloud agent loads hooks only once it has a writable environment. Docs: early read-only turns
do not run them. `sessionStart` and `sessionEnd` do not run in cloud agents. `beforeMCPExecution`
and `afterMCPExecution` do not either. Tab and `workspaceOpen` are IDE-only.

## What the script is given

Every hook gets a common envelope. Live shell and write events carried:

`conversation_id`, `generation_id`, `model`, `hook_event_name`, `cursor_version`,
`workspace_roots`, `user_email` (null here), `transcript_path` (null here), `session_id`.

`session_id` matched `conversation_id`. `cwd` on shell events was `""`. The adapter uses the
first `workspace_roots` entry when `cwd` is blank, then `CURSOR_PROJECT_DIR`.

Env present on the live scripts: `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `CLAUDE_PROJECT_DIR`,
`CURSOR_AGENT_SOCKET`, `CURSOR_RIPGREP_PATH`, `CURSOR_SPAWN_CWD_HOP`, `CURSOR_WORKLOAD_CGROUP`.
Docs also list `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH`, and `CURSOR_CODE_REMOTE`. Those
three were absent in this run.

Stdin is the JSON payload when the daemon is started with command-hook stdin transport (this VM
was). Otherwise the daemon wraps the command in a heredoc that is still the script's stdin. The
scripts read `sys.stdin` either way.

### Events that fired

| Event | Payload that mattered | Order for one shell call |
| --- | --- | --- |
| `preToolUse` | `tool_name`, `tool_input`, `tool_use_id`, `cwd` | 1 |
| `beforeShellExecution` | `command`, `cwd`, `sandbox`, `tool_use_id` | 2 |
| `afterShellExecution` | `command`, `output` (raw terminal text), `duration`, `sandbox` | 3 |
| `postToolUse` | `tool_name`, `tool_input`, `tool_output`, `duration`, `tool_use_id` | 4 |

Shell `tool_name` is `Shell`. `tool_input` is `{"command", "cwd", "timeout"}`. `cwd` was `""`.
`postToolUse` `tool_output` is a **JSON string** `{"output", "exitCode"}`, not the raw text.
`afterShellExecution` `output` is the raw text. Both describe the same call and share `tool_use_id`.

`preToolUse` for `Read` is `tool_input: {"file_path"}`. `beforeReadFile` then sends `file_path`,
`content`, and `attachments`. That is after the local read; a deny stops the content reaching the
model. Nothing in the guard table needs it.

`preToolUse` for `Write` is `tool_input: {"file_path", "content"}` where `content` is the **full
new file**. StrReplace came through as that same Write, not as a patch tool. `afterFileEdit`
runs after a successful write with `file_path` and `edits: [{old_string, new_string}]`. A new
file's `old_string` was `""`. A StrReplace's edit was the hunk. The write is already on disk by
then, and the response schema has no permission field the daemon enforces.

### Events that did not fire here

The daemon builds these payloads. Docs agree, except where noted.

| Event | Input the adapter cares about | Output the daemon enforces |
| --- | --- | --- |
| `beforeSubmitPrompt` | `prompt`, `attachments` | `continue` (bool), `user_message`, `additional_context` |
| `afterAgentResponse` | `text` | none. Response is ignored. |
| `stop` | `status` (`completed`/`aborted`/`error`), `loop_count`. No assistant text. | `followup_message` becomes the next user message |
| `subagentStart` | `subagent_type`, `task`, `tool_call_id`, … | `permission` `allow` or `deny`. `ask` is treated as deny. |
| `preToolUse` on `Task` | `tool_name` `Task` | same permission object as any preToolUse |

`additional_context` is delivered only for `sessionStart`, `beforeSubmitPrompt`, `preToolUse`,
`postToolUse`, and `postToolUseFailure` (10000 characters). A live `preToolUse` and a live
`postToolUse` that returned `additional_context` both showed up in the model context.

`beforeShellExecution` accepts `agent_message` in the schema. On deny, the daemon's shell path
uses `user_message` only (`Command execution was blocked by a hook: …`). On allow it does not
inject `agent_message`. A warn returned there is dropped. That was read in the daemon and is why
warns go out on `preToolUse` instead.

## What the script must print

Permission hooks (`beforeShellExecution`, `preToolUse`, `subagentStart`, `beforeReadFile`,
`beforeMCPExecution`, `beforeTabFileRead`) treat exit 0 with JSON that fails the schema, including
empty stdout, as a block. An allow is `{"permission":"allow"}`.

| Verdict | Event | Stdout | Exit |
| --- | --- | --- | --- |
| deny | `beforeShellExecution`, `preToolUse` | `{"permission":"deny","user_message","agent_message"}` | 0 |
| warn | `preToolUse`, `postToolUse`, `beforeSubmitPrompt` | `{"additional_context"}`. Prompt also sets `"continue":true`. preToolUse also sets `"permission":"allow"`. | 0 |
| deny | `stop` | `{"followup_message"}` | 0 |
| allow | permission events | `{"permission":"allow"}` | 0 |

Exit 2 also blocks, and is what the docs call equivalent to `permission: deny`. The live deny used
exit 0 plus the JSON, and the command did not run. The reason is copied to stderr as well.

A crash, a timeout, or any exit other than 0 or 2 fails open unless the hook sets `failClosed`.
The template sets `failClosed` on the hooks that deny. Invalid JSON on a permission hook blocks
even without `failClosed`. Unparseable stdin exits 1 so a fail-closed hook blocks and the others
fail open.

`stop` follow-ups stop after `loop_limit` (template sets 5; the daemon's default is also 5).
`status` other than `completed` does not re-prompt. `ask` is not used: cloud agents have nobody
to approve it, and `preToolUse` does not enforce `ask`.

## Guard map

The contract table in [`../adapters/README.md`](../adapters/README.md), on the closest event that
can actually enforce the verdict.

| Guard | Cursor event | Enforced? |
| --- | --- | --- |
| `pipes` deny | `beforeShellExecution` and `preToolUse` `Shell` | Live. `permission: deny` stopped the shell. `user_message` reached the model. |
| `pkill` deny | same | Same deny path. The `pkill -f` rule itself was not the command that was blocked live. |
| `pkill` warn | `preToolUse` `Shell` only | Live channel: `additional_context` on `preToolUse` reached the model. `beforeShellExecution` cannot deliver it. |
| `comments` shell | `beforeShellExecution` and `preToolUse` `Shell` | Same command string as `pipes`, including heredocs. |
| `comments` write | `preToolUse` `Write` | Live. Full new file in `content`. `permission: deny` left no file. StrReplace was that Write. `afterFileEdit` is too late. |
| `review_brevity` shell | `beforeShellExecution` and `preToolUse` `Shell` | Same command string. |
| `review_brevity` MCP | `preToolUse` matcher `MCP:…` | Daemon sends `tool_name` `MCP:<tool>` and a `tool_input` object. Not fired live. `beforeMCPExecution` does not run in cloud agents. |
| `delegation` count | `preToolUse` `Shell` | Warn channel verified. Not counted on `beforeShellExecution`: both events fire for one call and would double the counter. |
| `delegation` reset | `subagentStart`, and `preToolUse` `Task` | Daemon. Not fired live. |
| `truncation` warn | `postToolUse` `Shell` | Live channel. The output string is parsed out of the JSON `tool_output`. `afterShellExecution` accepts any object and does not inject `additional_context`. |
| `goals` vague prompt | `beforeSubmitPrompt` | Docs: `continue: false` blocks the submit. Not fired live in the 2026-10-21 probe. |
| `goals` edit | `preToolUse` `Write`/`Shell` and `beforeShellExecution` | Same deny path as `pipes` for a shell write the parser can see. `Write` deny was live for the comments guard. |
| `goals` done claim | `stop` `followup_message` | Same re-prompt as `commitment`, capped by `loop_limit`. The hook re-runs sabotage and can be killed at 30s. |
| brevity streak | `beforeSubmitPrompt` | Daemon plus docs. Not fired live. Warn is `additional_context` with `continue: true`. It does not block the prompt. |
| `brevity`, `commitment` | `stop` `followup_message` | The re-prompt field is in the daemon. The live stop payload has no assistant text and `transcript_path` was null. `afterAgentResponse` `text` is stashed for the stop hook. That event is supported in cloud agents and did not fire during the tool probes. |

`beforeShellExecution` and `preToolUse` both run for one shell call, `preToolUse` first. A deny
there stops the call, so the later hook does not run. Allows run both. The shell guards are
registered on both so a build that skipped one of them would still deny.

## What Cursor cannot express

- A warn on `beforeShellExecution`. `agent_message` is not shown to the model on allow.
- A warn on `afterShellExecution`. `additional_context` is not in the delivery set.
- A deny on `afterFileEdit`. The write has already happened.
- `beforeMCPExecution` / `afterMCPExecution` on a cloud agent.
- `sessionStart` / `sessionEnd` on a cloud agent. `sessionStart` cannot block session creation
  even on the desktop; the daemon says callers ignore `continue: false`.
- Stop re-prompting from the stop payload alone. `followup_message` is the re-prompt, and it
  works only when some earlier event saved the reply. This run's `transcript_path` was null.
- More than `loop_limit` automatic stop follow-ups (5 in the template).
- `ask`. There is no person at the cloud agent to answer it.
- User-level `~/.cursor/hooks.json` on a cloud agent. It did not fire here.

## `.claude/settings.json` is the wrong file

The daemon loads it and rewrites matchers (`Bash` → `Shell`, `Edit` → `Write`, `Task` stays
`Task`). The script still receives `hook_event_name: "preToolUse"` and `tool_name: "Shell"`.
A live `.claude/settings.json` `PreToolUse` hook with matcher `Bash` ran on `Shell`.

`adapters/hookjson/` treats only `Bash` and `run_terminal_command` as shells, so that payload
is an allow. The tests lock that: the same bytes deny in `adapters/cursor/` and produce no
output in `adapters/hookjson/`. Nested `hookSpecificOutput` is translated only when the daemon
was started with nested Claude output normalisation (this VM was). Do not depend on it. The
Cursor adapter prints Cursor's own JSON.

## Enable it

Python 3.10+. From a harness checkout:

```sh
./install.sh --harness cursor --target <repo>/.cursor/hooks.json --force
```

Omit `--target` to print the snippet. An existing file needs `--force`, which backs it up and
replaces this pack's entries by script name. A Claude-shaped `settings.json` is refused.

Desktop user scope, every project:

```sh
./install.sh --harness cursor --target ~/.cursor/hooks.json --force
```

That file does not apply to cloud agents.

### Cloud agents

Commit project hooks, or write them before the exec daemon starts. A file created after startup
does not fire until reload.

The commands in a normal install are the absolute path of the checkout that ran `install.sh`.
That path is right on the machine that wrote the file and wrong on a laptop-generated commit
checked out in a VM. Two ways to make the path true on the VM:

1. **Environment install** (the path is written on the VM):

```sh
git clone --depth 1 https://github.com/natevick/harness.git "$HOME/.harness/src"
"$HOME/.harness/src/packages/guardrails/adapters/cursor/cloud-setup.sh" "$REPO"
```

Put that in the cloud environment's install step so the clone and `.cursor/hooks.json` exist
before an agent turn. `cloud-setup.sh` points the hooks at that checkout.

2. **Commit a portable `hooks.json`** and clone harness to the path it expands:

```sh
./install.sh --harness cursor --portable --target .cursor/hooks.json --force
git add .cursor/hooks.json
```

`--portable` writes `python3 "${HARNESS_ROOT:-$HOME/.harness/src}/packages/guardrails/..."`.
The hook command is a shell command, so `$HOME` expands when the hook runs. The environment
install still has to clone harness there. If the clone is missing, the fail-closed shell hooks
block rather than fail open.

Do not commit a `hooks.json` whose commands point at a path that only exists on one laptop.
