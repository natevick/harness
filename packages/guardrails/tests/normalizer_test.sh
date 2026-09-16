#!/usr/bin/env bash
set -uo pipefail

ADAPTERS="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

fire() {
  local script="$1" payload="$2"
  shift 2
  printf '%s' "$payload" | env GUARDRAILS_STATE_DIR="$TMP/state" "$@" \
    python3 "$ADAPTERS/$script" 2>"$TMP/err"
}

verdict_of() {
  if printf '%s' "$1" | grep -q '"permissionDecision": "deny"'; then printf 'deny-claude'
  elif printf '%s' "$1" | grep -q '"decision": "deny"'; then printf 'deny-grok'
  elif printf '%s' "$1" | grep -q '"additionalContext"'; then printf 'warn'
  else printf 'allow'; fi
}

record() {
  local name="$1" expect="$2" got="$3"
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-58s (%s)\n' "$name" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s expected %s, got %s\n' "$name" "$expect" "$got"
  fi
}

json() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1"; }

echo "── ONE COMMENT, FOUR DIALECTS — the same verdict from every harness ──"

CLAUDE_WRITE='{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/srv/app",
  "tool_name":"Write","tool_use_id":"t1",
  "tool_input":{"file_path":"/srv/app/a.rb","content":"# why this exists\nclass A; end"}}'
record "Claude snake_case Write" deny-claude "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$CLAUDE_WRITE")")")"

GROK_WRITE='{"hookEventName":"pre_tool_use","sessionId":"s1","cwd":"/srv/app",
  "toolName":"search_replace","toolUseId":"t1",
  "toolInput":{"file_path":"/srv/app/a.rb","old_string":"class A; end",
               "new_string":"# why this exists\nclass A; end"}}'
record "grok camelCase search_replace" deny-grok "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$GROK_WRITE")")")"

KIMI_WRITE='{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/srv/app",
  "tool_name":"Write","tool_call_id":"t1",
  "tool_input":{"path":"/srv/app/a.rb","content":"# why this exists\nclass A; end"}}'
record "Kimi path field" deny-claude "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$KIMI_WRITE")")")"

CODEX_PATCH='{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/srv/app",
  "tool_name":"apply_patch","tool_use_id":"t1",
  "tool_input":{"command":"*** Begin Patch\n*** Update File: /srv/app/a.rb\n@@\n-class A; end\n+# why this exists\n+class A; end\n*** End Patch"}}'
record "Codex apply_patch envelope" deny-claude "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$CODEX_PATCH")")")"

CODEX_DIFF='{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/srv/app",
  "tool_name":"apply_patch","tool_use_id":"t1",
  "tool_input":{"command":"--- a/srv/app/a.rb\n+++ b/srv/app/a.rb\n@@ -1 +1,2 @@\n+# why this exists\n class A; end"}}'
record "Codex unified diff" deny-claude "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$CODEX_DIFF")")")"

echo
echo "── AND THE CLEAN VERSION OF EACH MUST PASS ──"
CLEAN_CLAUDE='{"hook_event_name":"PreToolUse","cwd":"/srv/app","tool_name":"Write",
  "tool_input":{"file_path":"/srv/app/a.rb","content":"class A; end"}}'
record "Claude clean write" allow "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$CLEAN_CLAUDE")")")"
CLEAN_KIMI='{"hook_event_name":"PreToolUse","cwd":"/srv/app","tool_name":"Write","tool_call_id":"t",
  "tool_input":{"path":"/srv/app/a.rb","content":"class A; end"}}'
record "Kimi clean write" allow "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$CLEAN_KIMI")")")"
CLEAN_CODEX='{"hook_event_name":"PreToolUse","cwd":"/srv/app","tool_name":"apply_patch",
  "tool_input":{"command":"*** Begin Patch\n*** Update File: /srv/app/a.rb\n@@\n+class A; end\n*** End Patch"}}'
record "Codex clean patch" allow "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$CLEAN_CODEX")")")"

echo
echo "── THE SHELL GUARDS SEE run_terminal_command, NOT ONLY Bash ──"
GROK_SHELL='{"hookEventName":"pre_tool_use","toolName":"run_terminal_command",
  "toolInput":{"command":"shellcheck x.sh | head -15; echo exit=$?"}}'
out="$(fire pipe_exit_code_guard.py "$(json "$GROK_SHELL")")"
record "grok run_terminal_command reaches the pipe guard" deny-grok "$(verdict_of "$out")"
CLAUDE_SHELL='{"hook_event_name":"PreToolUse","tool_name":"Bash",
  "tool_input":{"command":"shellcheck x.sh | head -15; echo exit=$?"}}'
record "the same command as Claude Bash" deny-claude "$(verdict_of "$(fire pipe_exit_code_guard.py "$(json "$CLAUDE_SHELL")")")"
record "grok run_terminal_command reaches the pkill guard" deny-grok \
  "$(verdict_of "$(fire pkill_self_match_guard.py "$(json '{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"pkill -f watch.sh"}}')")")"

echo
echo "── A WRITE TOOL IS NOT A SHELL CALL ──"
PATCH_WITH_PIPE='{"hook_event_name":"PreToolUse","tool_name":"apply_patch",
  "tool_input":{"command":"*** Begin Patch\n*** Update File: /srv/app/a.sh\n+cmd | head -5; echo $?\n*** End Patch"}}'
record "a patch body is not scanned by the pipe guard" allow \
  "$(verdict_of "$(fire pipe_exit_code_guard.py "$(json "$PATCH_WITH_PIPE")")")"

echo
echo "── THE GROK DENY SHAPE AND EXIT CODE ──"
rc=0
printf '%s' "$(json "$GROK_SHELL")" | env GUARDRAILS_STATE_DIR="$TMP/state" \
  python3 "$ADAPTERS/pipe_exit_code_guard.py" >"$TMP/out" 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 2 ]; then
  pass=$((pass + 1)); echo "  ok   grok deny exits 2"
else
  fail=$((fail + 1)); printf '  FAIL grok deny exited %s\n' "$rc"
fi
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("decision") == "deny" and d.get("reason") and "hookSpecificOutput" not in d else 1)
' "$TMP/out"; then
  pass=$((pass + 1)); echo "  ok   grok gets {decision, reason} and no hookSpecificOutput"
else
  fail=$((fail + 1)); printf '  FAIL grok shape wrong: %s\n' "$(cat "$TMP/out")"
fi
if [ -s "$TMP/err" ]; then
  pass=$((pass + 1)); echo "  ok   a deny also writes the reason to stderr"
else
  fail=$((fail + 1)); echo "  FAIL nothing on stderr"
fi
rc=0
printf '%s' "$(json "$CLAUDE_SHELL")" | env GUARDRAILS_STATE_DIR="$TMP/state" \
  python3 "$ADAPTERS/pipe_exit_code_guard.py" >/dev/null 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
  pass=$((pass + 1)); echo "  ok   the Claude shape exits 0 (exit 2 would double-report)"
else
  fail=$((fail + 1)); printf '  FAIL Claude deny exited %s\n' "$rc"
fi

echo
echo "── HARNESS DETECTION, AND THE ENV OVERRIDE BEATS IT ──"
detect() {
  printf '%s' "$1" | python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import hookio
print(hookio.detect(json.load(sys.stdin)))
' "$ADAPTERS"
}
for probe in \
  "claude|$(json "$CLAUDE_WRITE")" \
  "grok|$(json "$GROK_WRITE")" \
  "kimi|$(json "$KIMI_WRITE")" \
  "codex|$(json "$CODEX_PATCH")"; do
  want="${probe%%|*}"
  got="$(detect "${probe#*|}")"
  record "detects $want" "$want" "$got"
done
got="$(printf '%s' "$(json "$CLAUDE_WRITE")" | env GUARDRAILS_HARNESS=grok python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import hookio
print(hookio.detect(json.load(sys.stdin)))
' "$ADAPTERS")"
record "GUARDRAILS_HARNESS overrides detection" grok "$got"
out="$(fire comment_discipline_guard.py "$(json "$CLAUDE_WRITE")" GUARDRAILS_HARNESS=grok)"
record "the override changes the emitted shape" deny-grok "$(verdict_of "$out")"

echo
echo "── EVENT NAMES: grok sends pre_tool_use, Claude sends PreToolUse ──"
out="$(fire truncated_output_guard.py "$(json '{"hookEventName":"post_tool_use","toolName":"run_terminal_command","toolInput":{"command":"grep -rn x /srv | head -3"},"toolResult":{"stdout":"a\nb\nc"}}')")"
if printf '%s' "$out" | grep -q '"hookEventName": "PostToolUse"'; then
  pass=$((pass + 1)); echo "  ok   grok post_tool_use normalises to PostToolUse and reads toolResult"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "$out"
fi
out="$(fire truncated_output_guard.py "$(json '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn x /srv | head -3"},"tool_output":"a\nb\nc"}')")"
if printf '%s' "$out" | grep -q 'capped output at 3'; then
  pass=$((pass + 1)); echo "  ok   Kimi tool_output is read as the command output"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "$out"
fi

echo
echo "── STOP WITH NO TEXT — silent, but logged once ──"
rc=0
printf '{"hook_event_name":"Stop","session_id":"kimi-1","stop_hook_active":false}' \
  | env GUARDRAILS_STATE_DIR="$TMP/state" GUARDRAILS_HARNESS=kimi \
    python3 "$ADAPTERS/brevity_guard.py" >"$TMP/out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ]; then
  pass=$((pass + 1)); echo "  ok   a stop with no assistant text exits 0 silently"
else
  fail=$((fail + 1)); printf '  FAIL rc=%s out=%s\n' "$rc" "$(cat "$TMP/out")"
fi
for _ in 1 2 3; do
  printf '{"hook_event_name":"Stop","session_id":"kimi-1","stop_hook_active":false}' \
    | env GUARDRAILS_STATE_DIR="$TMP/state" GUARDRAILS_HARNESS=kimi \
      python3 "$ADAPTERS/brevity_guard.py" >/dev/null 2>&1
done
count="$(grep -c 'harness sent no assistant text' "$TMP/state/decisions.jsonl" 2>/dev/null || printf 0)"
if [ "$count" = "1" ]; then
  pass=$((pass + 1)); echo "  ok   it is logged exactly once across four stops"
else
  fail=$((fail + 1)); printf '  FAIL logged %s times\n' "$count"
fi
rc=0
printf '{"hookEventName":"stop","sessionId":"g1","stopHookActive":false,"lastAssistantMessage":"I will post the numbers in the morning."}' \
  | env GUARDRAILS_STATE_DIR="$TMP/state" python3 "$ADAPTERS/commitment_guard.py" >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'Commitment without a mechanism' "$TMP/err"; then
  pass=$((pass + 1)); echo "  ok   grok lastAssistantMessage reaches the commitment guard"
else
  fail=$((fail + 1)); printf '  FAIL rc=%s err=%s\n' "$rc" "$(cat "$TMP/err")"
fi
rc=0
printf '{"hook_event_name":"Stop","session_id":"c1","stop_hook_active":false,"last_assistant_message":"I will post the numbers in the morning."}' \
  | env GUARDRAILS_STATE_DIR="$TMP/state" python3 "$ADAPTERS/commitment_guard.py" >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 2 ]; then
  pass=$((pass + 1)); echo "  ok   Claude last_assistant_message reaches it too"
else
  fail=$((fail + 1)); printf '  FAIL rc=%s\n' "$rc"
fi

echo
echo "── THE DECISION LOG IS THE EVIDENCE TRAIL ──"
rm -rf "$TMP/state"
fire pipe_exit_code_guard.py "$(json "$CLAUDE_SHELL")" >/dev/null
if grep -q '"guard": "pipes"' "$TMP/state/decisions.jsonl" 2>/dev/null &&
   grep -q '"decision": "deny"' "$TMP/state/decisions.jsonl" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok   a deny is logged with its guard name"
else
  fail=$((fail + 1)); echo "  FAIL no deny in decisions.jsonl"
fi
rm -rf "$TMP/state"
fire pipe_exit_code_guard.py "$(json '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}')" >/dev/null
if [ ! -f "$TMP/state/decisions.jsonl" ]; then
  pass=$((pass + 1)); echo "  ok   an allow is not logged by default"
else
  fail=$((fail + 1)); echo "  FAIL an allow was logged without being asked"
fi
rm -rf "$TMP/state"
fire pipe_exit_code_guard.py "$(json '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}')" \
  GUARDRAILS_LOG_DECISIONS=1 >/dev/null
if grep -q '"decision": "allow"' "$TMP/state/decisions.jsonl" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok   GUARDRAILS_LOG_DECISIONS=1 records allows too"
else
  fail=$((fail + 1)); echo "  FAIL no allow logged under GUARDRAILS_LOG_DECISIONS"
fi

echo
echo "── GROK SENDS NESTED camelCase TOO — a write must still be guarded ──"
GROK_NESTED='{"hookEventName":"pre_tool_use","sessionId":"s1","cwd":"/srv/app",
  "toolName":"search_replace","toolUseId":"t1",
  "toolInput":{"filePath":"/srv/app/a.rb","oldString":"class A; end",
               "newString":"# why this exists\nclass A; end"}}'
record "grok nested filePath and newString" deny-grok \
  "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$GROK_NESTED")")")"
GROK_NESTED_CLEAN='{"hookEventName":"pre_tool_use","cwd":"/srv/app","toolName":"search_replace",
  "toolInput":{"filePath":"/srv/app/a.rb","oldString":"class A; end","newString":"class A; end"}}'
record "the clean version of the same write" allow \
  "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$GROK_NESTED_CLEAN")")")"

echo
echo "── CODEX MOVE-TO: an added line belongs to the file codex will write ──"
MOVED='{"hook_event_name":"PreToolUse","cwd":"/srv/app","tool_name":"apply_patch",
  "tool_input":{"command":"*** Begin Patch\n*** Update File: notes.txt\n*** Move to: notes.rb\n+# why this exists\n*** End Patch"}}'
record "a comment moved into a guarded name denies" deny-claude \
  "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$MOVED")")")"
MOVED_OUT='{"hook_event_name":"PreToolUse","cwd":"/srv/app","tool_name":"apply_patch",
  "tool_input":{"command":"*** Begin Patch\n*** Update File: a.rb\n*** Move to: notes.txt\n+# why this exists\n*** End Patch"}}'
record "a comment moved into an unguarded name allows" allow \
  "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$MOVED_OUT")")")"
SMUGGLED='{"hook_event_name":"PreToolUse","cwd":"/srv/app","tool_name":"apply_patch",
  "tool_input":{"command":"*** Begin Patch\n*** Update File: a.rb\n+++ /tmp/x\n+# smuggled\n*** End Patch"}}'
record "a +++ line inside the envelope is content, not a header" deny-claude \
  "$(verdict_of "$(fire comment_discipline_guard.py "$(json "$SMUGGLED")")")"

echo
echo "── A TRUNCATED TOOL INPUT IS UNMEASURABLE, NOT CLEAN ──"
CLIPPED='{"hookEventName":"pre_tool_use","toolName":"run_terminal_command",
  "toolInputTruncated":true,"toolInput":{"command":"echo hello"}}'
out="$(fire pipe_exit_code_guard.py "$(json "$CLIPPED")")"
if printf '%s' "$out" | grep -q 'truncated this tool input'; then
  pass=$((pass + 1)); echo "  ok   a clipped command warns instead of passing silently"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "$out"
fi
CLIPPED_DENY='{"hookEventName":"pre_tool_use","toolName":"run_terminal_command",
  "toolInputTruncated":true,"toolInput":{"command":"cmd | head -3; echo $?"}}'
record "a clipped command that still trips a guard denies" deny-grok \
  "$(verdict_of "$(fire pipe_exit_code_guard.py "$(json "$CLIPPED_DENY")")")"

echo
echo "── A COMMAND GIVEN AS A LIST MUST NOT CRASH THE GUARD ──"
LIST='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":["ls","-la"]}}'
rc=0
printf '%s' "$(json "$LIST")" | env GUARDRAILS_STATE_DIR="$TMP/state" \
  python3 "$ADAPTERS/pipe_exit_code_guard.py" >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/err" ]; then
  pass=$((pass + 1)); echo "  ok   a list command exits 0 with no traceback"
else
  fail=$((fail + 1)); printf '  FAIL rc=%s %s\n' "$rc" "$(cat "$TMP/err")"
fi
LIST_DENY='{"hook_event_name":"PreToolUse","tool_name":"Bash",
  "tool_input":{"command":["cmd","|","head","-3;","echo","$?"]}}'
record "a list command is joined and still checked" deny-claude \
  "$(verdict_of "$(fire pipe_exit_code_guard.py "$(json "$LIST_DENY")")")"

echo
echo "── THE DECISION TRAIL IS NOT A PLAINTEXT SINK ──"
rm -rf "$TMP/state"
FAKE_KEY="sk-$(printf live)-NOTAREALKEY1234567890"
FAKE_TOKEN="ghp$(printf _)NOTAREALTOKEN1234567890"
SECRET_CMD="$(python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {
    "command": "curl -H \"Authorization: Bearer %s\" https://x | tee o.txt; echo $?" % sys.argv[1]}}))
' "$FAKE_KEY")"
fire pipe_exit_code_guard.py "$(json "$SECRET_CMD")" >/dev/null
SECRET_STOP="{\"hook_event_name\":\"Stop\",\"session_id\":\"leak\",\"stop_hook_active\":false,\"last_assistant_message\":\"the token is $FAKE_TOKEN and here is more prose\"}"
printf '%s' "$(json "$SECRET_STOP")" | env GUARDRAILS_STATE_DIR="$TMP/state" \
  python3 "$ADAPTERS/brevity_guard.py" >/dev/null 2>&1
if grep -rqF -e "$FAKE_KEY" -e "$FAKE_TOKEN" "$TMP/state" 2>/dev/null; then
  fail=$((fail + 1)); echo "  FAIL a fake credential reached the state directory"
else
  pass=$((pass + 1)); echo "  ok   neither fake credential appears in any state file"
fi
if [ -s "$TMP/state/decisions.jsonl" ] && grep -q 'subject_digest' "$TMP/state/decisions.jsonl"; then
  pass=$((pass + 1)); echo "  ok   the deny is still recorded, by digest"
else
  fail=$((fail + 1)); echo "  FAIL the deny was not recorded at all"
fi
modes="$(find "$TMP/state" -type f -exec stat -c %a {} + | sort -u | tr '\n' ' ')"
if [ "$modes" = "600 " ]; then
  pass=$((pass + 1)); echo "  ok   every state file is 0600"
else
  fail=$((fail + 1)); printf '  FAIL state file modes were: %s\n' "$modes"
fi
if [ "$(stat -c %a "$TMP/state")" = "700" ]; then
  pass=$((pass + 1)); echo "  ok   the state directory is 0700"
else
  fail=$((fail + 1)); printf '  FAIL state dir mode %s\n' "$(stat -c %a "$TMP/state")"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
