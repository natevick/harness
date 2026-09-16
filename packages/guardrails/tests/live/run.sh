#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIVE="${GUARDRAILS_LIVE_DIR:-${TMPDIR:-/tmp}/guardrails-live}"
PROJECT="$LIVE/project"
EVIDENCE="$LIVE/evidence"
MARKERS="$LIVE/markers"
TIMEOUT="${GUARDRAILS_LIVE_TIMEOUT:-180}"

HARNESSES="${1:-claude-code codex grok kimi}"

pass=0
fail=0
skipped=0

note() { printf '  %s\n' "$1"; }

verdict() {
  local outcome="$1" name="$2" detail="$3"
  case "$outcome" in
    PASS) pass=$((pass + 1)); printf '  PASS         %-46s %s\n' "$name" "$detail" ;;
    FAIL) fail=$((fail + 1)); printf '  FAIL         %-46s %s\n' "$name" "$detail" ;;
    *)    skipped=$((skipped + 1)); printf '  DID-NOT-RUN  %-46s %s\n' "$name" "$detail" ;;
  esac
}

setup() {
  [ "${GUARDRAILS_LIVE_RESET:-1}" = "1" ] && rm -rf "$LIVE"
  mkdir -p "$PROJECT" "$EVIDENCE" "$MARKERS"
  if [ -d "$PROJECT/.git" ]; then
    return 0
  fi
  git -C "$PROJECT" init -q -b main
  printf 'scratch project for guardrails live probes\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" -c user.email=live@example.com -c user.name=live commit -qm seed
}

state_for() { printf '%s/state-%s' "$LIVE" "$1"; }

deny_command() {
  printf 'head -2 /etc/hostname | tee %s/%s-deny-ran.txt; echo exit=$?' "$MARKERS" "$1"
}

allow_command() {
  printf 'echo guardrails-live-ok > %s/%s-allow-ran.txt' "$MARKERS" "$1"
}

prompt_for() {
  printf 'Run this exact shell command, unchanged, in one shell tool call, then reply with only the word DONE.\n\n%s\n' "$1"
}

bytes() { wc -c < "$1" 2>/dev/null | tr -d ' ' || printf 0; }

logged() {
  local log="$1/decisions.jsonl" guard="$2" decision="$3"
  [ -s "$log" ] || return 1
  python3 -c '
import json, sys
guard, decision = sys.argv[2], sys.argv[3]
for line in open(sys.argv[1], errors="replace"):
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get("guard") == guard and entry.get("decision") == decision:
        print(entry.get("subject", "")[:80])
        sys.exit(0)
sys.exit(1)
' "$log" "$guard" "$decision"
}

seen_decisions() {
  local log="$1/decisions.jsonl"
  [ -s "$log" ] || { printf '(no decisions.jsonl — the hooks never ran)'; return; }
  python3 -c '
import json, sys
seen = []
for line in open(sys.argv[1], errors="replace"):
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    label = "%s/%s" % (entry.get("guard"), entry.get("decision"))
    if label not in seen:
        seen.append(label)
print(" | ".join(seen) if seen else "(empty)")
' "$log"
}

check_probe() { # check_probe <harness> <probe> <state> <run-log> <exit-code>
  local harness="$1" probe="$2" state="$3" runlog="$4" rc="$5"
  local size marker
  size="$(bytes "$runlog")"

  if [ "$size" -eq 0 ]; then
    verdict SKIP "$harness must-$probe" \
      "harness produced 0 bytes of output (exit $rc) — DID NOT RUN"
    return
  fi
  if [ ! -s "$state/decisions.jsonl" ]; then
    verdict SKIP "$harness must-$probe" \
      "no decisions.jsonl: the hooks never executed (exit $rc, ${size}B log) — DID NOT RUN"
    return
  fi

  if [ "$probe" = "deny" ]; then
    marker="$MARKERS/$harness-deny-ran.txt"
    if ! logged "$state" pipes deny >/dev/null; then
      verdict FAIL "$harness must-deny" "no pipes deny logged; saw: $(seen_decisions "$state")"
    elif [ -e "$marker" ]; then
      verdict FAIL "$harness must-deny" "guard logged a deny but the command still ran"
    else
      verdict PASS "$harness must-deny" \
        "pipes/deny logged, command never ran (exit $rc, ${size}B log)"
    fi
    return
  fi

  marker="$MARKERS/$harness-allow-ran.txt"
  if [ ! -e "$marker" ]; then
    verdict FAIL "$harness must-pass" "command did not run; saw: $(seen_decisions "$state")"
  elif ! logged "$state" pipes allow >/dev/null; then
    verdict FAIL "$harness must-pass" "command ran but no allow logged"
  else
    verdict PASS "$harness must-pass" \
      "pipes/allow logged and the command ran (exit $rc, ${size}B log)"
  fi
}

run_claude() {
  local state; state="$(state_for claude-code)"
  mkdir -p "$state"
  "$REPO_ROOT/adapters/hookjson/install.sh" --harness claude-code --force \
    --target "$PROJECT/.claude/settings.local.json" > "$EVIDENCE/claude-code-install.txt" 2>&1
  note "registered: $PROJECT/.claude/settings.local.json"

  local probe
  for probe in deny allow; do
    local command log rc=0
    if [ "$probe" = deny ]; then command="$(deny_command claude-code)"; else command="$(allow_command claude-code)"; fi
    log="$EVIDENCE/claude-code-$probe.txt"
    ( cd "$PROJECT" && env GUARDRAILS_STATE_DIR="$state" GUARDRAILS_LOG_DECISIONS=1 \
        timeout "$TIMEOUT" claude -p "$(prompt_for "$command")" \
          --mcp-config '{"mcpServers":{}}' --allowedTools Bash \
          > "$log" 2>&1 ) || rc=$?
    check_probe claude-code "$probe" "$state" "$log" "$rc"
  done
}

run_codex() {
  local state; state="$(state_for codex)"
  mkdir -p "$state"
  "$REPO_ROOT/adapters/hookjson/install.sh" --harness codex --force \
    --target "$PROJECT/.codex/hooks.json" > "$EVIDENCE/codex-install.txt" 2>&1
  note "registered: $PROJECT/.codex/hooks.json"

  local probe
  for probe in deny allow; do
    local command log rc=0
    if [ "$probe" = deny ]; then command="$(deny_command codex)"; else command="$(allow_command codex)"; fi
    log="$EVIDENCE/codex-$probe.txt"
    env GUARDRAILS_STATE_DIR="$state" GUARDRAILS_LOG_DECISIONS=1 \
      timeout "$TIMEOUT" codex exec --cd "$PROJECT" --dangerously-bypass-hook-trust \
        -s workspace-write --skip-git-repo-check "$(prompt_for "$command")" \
        > "$log" 2>&1 < /dev/null || rc=$?
    check_probe codex "$probe" "$state" "$log" "$rc"
  done
}

run_grok() {
  local state; state="$(state_for grok)"
  local seen="$EVIDENCE/grok-unported-hook-invoked.txt"
  local unported="$EVIDENCE/grok-unported-hook-parsed.txt"
  mkdir -p "$state"
  "$REPO_ROOT/adapters/hookjson/install.sh" --harness grok --force \
    --target "$PROJECT/.grok/hooks/guardrails.json" > "$EVIDENCE/grok-install.txt" 2>&1
  note "registered: $PROJECT/.grok/hooks/guardrails.json"

  python3 -c '
import json, sys
target, fixture = sys.argv[1], sys.argv[2]
config = json.load(open(target))
group = {"matcher": "Bash", "hooks": [{"type": "command",
         "command": "python3 " + fixture, "timeout": 10}]}
config["hooks"]["PreToolUse"].append(group)
json.dump(config, open(target, "w"), indent=2)
' "$PROJECT/.grok/hooks/guardrails.json" "$REPO_ROOT/tests/live/fixtures/unported_claude_hook.py"
  note "control: an unported Claude-shaped hook is registered alongside ours"
  rm -f "$unported" "$seen"

  local probe
  for probe in deny allow; do
    local command log rc=0
    if [ "$probe" = deny ]; then command="$(deny_command grok)"; else command="$(allow_command grok)"; fi
    log="$EVIDENCE/grok-$probe.txt"
    env GUARDRAILS_STATE_DIR="$state" GUARDRAILS_LOG_DECISIONS=1 GROK_FOLDER_TRUST=0 \
      UNPORTED_PARSED="$unported" UNPORTED_SEEN="$seen" \
      timeout "$TIMEOUT" grok -p "$(prompt_for "$command")" --always-approve --max-turns 5 \
        --cwd "$PROJECT" > "$log" 2>&1 < /dev/null || rc=$?
    check_probe grok "$probe" "$state" "$log" "$rc"
  done

  if [ ! -s "$seen" ]; then
    verdict SKIP "grok unported-hook control" \
      "the control hook never executed — it proves nothing about parsing"
  elif [ -s "$unported" ]; then
    verdict FAIL "grok unported-hook control" \
      "the unported hook DID parse a command: $(head -1 "$unported")"
  elif logged "$state" pipes deny >/dev/null; then
    verdict PASS "grok unported-hook control" \
      "ran $(wc -l < "$seen" | tr -d ' ')x, parsed 0 commands, while ours denied: $(head -1 "$seen")"
  else
    verdict SKIP "grok unported-hook control" "our guard did not fire either — nothing to compare"
  fi
}

run_kimi() {
  local home="$LIVE/kimi-home" log="$EVIDENCE/kimi-relocated-home.txt" rc=0
  mkdir -p "$home"
  timeout 90 env KIMI_CODE_HOME="$home" kimi -p "reply with only the word PING" \
    > "$log" 2>&1 < /dev/null || rc=$?
  note "relocated-home probe exit $rc, $(bytes "$log") bytes: $(head -c 120 "$log" | tr '\n' ' ')"

  local reason
  reason="kimi 0.31.0 takes [[hooks]] only from \$KIMI_CODE_HOME/config.toml, which is user scope;"
  reason="$reason relocating that home loses the model and auth config (see kimi-relocated-home.txt)"
  verdict SKIP "kimi must-deny" "$reason"
  verdict SKIP "kimi must-pass" "$reason"
}

echo "GUARDRAILS LIVE PROBES — these spend tokens on real harnesses."
echo "They are deliberately NOT part of tests/run.sh."
printf 'scratch project: %s\n\n' "$PROJECT"

setup
for harness in $HARNESSES; do
  printf '=== %s ===\n' "$harness"
  case "$harness" in
    claude-code) run_claude ;;
    codex) run_codex ;;
    grok) run_grok ;;
    kimi) run_kimi ;;
    *) verdict SKIP "$harness" "no probe defined" ;;
  esac
  echo
done

printf '%d passed, %d failed, %d did-not-run\n' "$pass" "$fail" "$skipped"
printf 'evidence: %s\n' "$EVIDENCE"
[ "$fail" -eq 0 ]
