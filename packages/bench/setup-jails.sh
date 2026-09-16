#!/usr/bin/env bash
# Build per-harness HOME jails so every seat sees identical instructions.
#
# The jail keeps each CLI's own auth + model config (symlinked back in) but
# hides ~/.claude/CLAUDE.md, ~/.claude/projects/*/memory/MEMORY.md, the hooks in
# ~/.claude/settings.json and the MCP servers in ~/.claude.json — all of which
# both `claude` and `grok` would otherwise load, while `codex` loads nothing.
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAIL="$BENCH/jail"
REAL_HOME="${REAL_HOME:-$HOME}"

rm -rf "$JAIL"
mkdir -p "$JAIL/claude/.claude" "$JAIL/grok" "$JAIL/codex"

# claude: needs OAuth credentials + a pre-onboarded ~/.claude.json, nothing else.
ln -s "$REAL_HOME/.claude/.credentials.json" "$JAIL/claude/.claude/.credentials.json"
printf '%s\n' '{"hasCompletedOnboarding":true,"mcpServers":{}}' > "$JAIL/claude/.claude.json"

# grok: whole ~/.grok symlinked (auth + model config, no rules files live there).
ln -s "$REAL_HOME/.grok" "$JAIL/grok/.grok"

# codex: whole ~/.codex symlinked (auth + gpt-5.6-sol/xhigh config, no AGENTS.md).
ln -s "$REAL_HOME/.codex" "$JAIL/codex/.codex"

echo "jails built under $JAIL"
find "$JAIL" -maxdepth 2 | sort
