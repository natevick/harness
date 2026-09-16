#!/usr/bin/env bash
# run-seat.sh <seat> <workdir> <prompt-file> <outdir>
#
# Runs one harness seat against one working directory and records:
#   $outdir/stdout.log   raw harness output (JSON / JSONL / plain)
#   $outdir/stderr.log
#   $outdir/meta.json    seat, exit code, wall-clock ms, start/end epoch ms
#
# Seats:
#   claude        Claude Code, HOME-jailed, no MCP, no CLAUDE.md
#   claude-cfg    Claude Code, exactly as Norm is configured today
#   codex         codex exec (gpt-5.6-sol, xhigh)
#   grok          grok (grok-4.5), HOME-jailed
set -uo pipefail

SEAT="$1"
WORK="$(cd "$2" && pwd)"
PROMPT_FILE="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAIL="$BENCH/jail"

mkdir -p "$4"
OUT="$(cd "$4" && pwd)"   # absolute: the seats below cd into $WORK
PROMPT="$(< "$PROMPT_FILE")"

start_ms=$(( $(date +%s%N) / 1000000 ))

case "$SEAT" in
  claude)
    cd "$WORK"
    HOME="$JAIL/claude" "$(command -v claude)" \
      -p "$PROMPT" \
      --output-format json \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --dangerously-skip-permissions \
      --add-dir "$WORK" \
      > "$OUT/stdout.log" 2> "$OUT/stderr.log" < /dev/null
    ;;
  claude-cfg)
    cd "$WORK"
    "$(command -v claude)" \
      -p "$PROMPT" \
      --output-format json \
      --dangerously-skip-permissions \
      --add-dir "$WORK" \
      > "$OUT/stdout.log" 2> "$OUT/stderr.log" < /dev/null
    ;;
  codex)
    codex exec \
      --cd "$WORK" \
      -s workspace-write \
      --json \
      "$PROMPT" \
      > "$OUT/stdout.log" 2> "$OUT/stderr.log" < /dev/null
    ;;
  grok)
    HOME="$JAIL/grok" "$(command -v grok)" \
      -p "$PROMPT" \
      --cwd "$WORK" \
      --output-format json \
      --always-approve \
      --max-turns 200 \
      > "$OUT/stdout.log" 2> "$OUT/stderr.log" < /dev/null
    ;;
  *)
    echo "unknown seat: $SEAT" >&2
    exit 64
    ;;
esac

rc=$?
end_ms=$(( $(date +%s%N) / 1000000 ))

# claude and grok are launched from $WORK via a cd so their cwd is the repo.
jq -n \
  --arg seat "$SEAT" \
  --arg work "$WORK" \
  --argjson rc "$rc" \
  --argjson start "$start_ms" \
  --argjson end "$end_ms" \
  '{seat: $seat, workdir: $work, exit_code: $rc, start_ms: $start, end_ms: $end, wall_ms: ($end - $start)}' \
  > "$OUT/meta.json"

echo "$SEAT finished rc=$rc in $((end_ms - start_ms))ms"
exit $rc
