#!/usr/bin/env bash
# Cursor payloads captured from a cloud agent (cursor_version 1.0.0) and the
# deny/warn shapes that agent enforced. The hookjson adapter must fail open
# on the same shell payload: tool_name is Shell, not Bash.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CURSOR="$ROOT/adapters/cursor"
HOOKJSON="$ROOT/adapters/hookjson"
INSTALL="$ROOT/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

fire() {
  local script="$1" payload="$2"
  shift 2
  printf '%s' "$payload" | env GUARDRAILS_STATE_DIR="$TMP/state" "$@" \
    python3 "$CURSOR/$script" >"$TMP/out" 2>"$TMP/err"
}

json() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1"; }

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

record() {
  local name="$1" expect="$2" got="$3"
  if [ "$got" = "$expect" ]; then ok "$name ($got)"
  else bad "$name expected $expect, got $got"; fi
}

permission() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("permission",""))' "$TMP/out" 2>/dev/null || printf 'unparsed'
}

SHELL_DENY='{"hook_event_name":"beforeShellExecution","conversation_id":"s1","session_id":"s1",
  "cwd":"","sandbox":false,"workspace_roots":["/srv/app"],
  "command":"head -2 /etc/hostname | tee /tmp/x; echo exit=$?"}'
SHELL_OK='{"hook_event_name":"beforeShellExecution","session_id":"s1","cwd":"",
  "sandbox":false,"workspace_roots":["/srv/app"],"command":"echo guardrails-live-ok"}'
PRE_DENY='{"hook_event_name":"preToolUse","tool_name":"Shell","session_id":"s1","cwd":"",
  "tool_input":{"command":"head -2 /etc/hostname | tee /tmp/x; echo exit=$?","cwd":"","timeout":600000},
  "workspace_roots":["/srv/app"]}'
PRE_PGREP='{"hook_event_name":"preToolUse","tool_name":"Shell","session_id":"s1",
  "tool_input":{"command":"pgrep -f watch.sh","cwd":""}}'
PRE_PKILL='{"hook_event_name":"beforeShellExecution","session_id":"s1",
  "command":"pkill -f watch.sh","cwd":"","sandbox":false}'

echo "── SHELL DENY IS permission deny, AND THE CLAUDE ADAPTER MISSES IT ──"
rc=0
fire pipe_exit_code_guard.py "$(json "$SHELL_DENY")" || rc=$?
if [ "$rc" -eq 0 ]; then ok "beforeShellExecution deny exits 0 (the JSON is the decision)"
else bad "beforeShellExecution deny exited $rc"; fi
record "beforeShellExecution pipe command" deny "$(permission)"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("user_message") and d.get("agent_message") and "additional_context" not in d else 1)
' "$TMP/out"; then ok "deny carries user_message and agent_message"
else bad "deny shape: $(cat "$TMP/out")"; fi
if [ -s "$TMP/err" ]; then ok "deny also writes the reason to stderr"
else bad "nothing on stderr"; fi

rc=0
printf '%s' "$(json "$SHELL_DENY")" | env GUARDRAILS_STATE_DIR="$TMP/state" \
  python3 "$HOOKJSON/pipe_exit_code_guard.py" >"$TMP/claude-out" 2>"$TMP/claude-err" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/claude-out" ]; then
  ok "the hookjson adapter fail-opens on a Cursor beforeShellExecution payload"
else
  bad "hookjson did not fail open (rc=$rc out=$(cat "$TMP/claude-out"))"
fi
printf '%s' "$(json "$PRE_DENY")" | env GUARDRAILS_STATE_DIR="$TMP/state" \
  python3 "$HOOKJSON/pipe_exit_code_guard.py" >"$TMP/claude-out" 2>/dev/null || true
if [ ! -s "$TMP/claude-out" ]; then
  ok "the hookjson adapter fail-opens on preToolUse tool_name Shell"
else
  bad "hookjson emitted a verdict for Shell: $(cat "$TMP/claude-out")"
fi

rc=0
fire pipe_exit_code_guard.py "$(json "$PRE_DENY")" || rc=$?
record "preToolUse Shell reaches the pipe guard" deny "$(permission)"

rc=0
fire pipe_exit_code_guard.py "$(json "$SHELL_OK")" || rc=$?
record "a clean command is permission allow" allow "$(permission)"

echo
echo "── A WARN ON beforeShellExecution IS NOT PRETENDED TO BE DELIVERED ──"
fire pkill_self_match_guard.py "$(json '{"hook_event_name":"beforeShellExecution","command":"pgrep -f watch.sh","cwd":"/srv/app"}')"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="allow" and "additional_context" not in d else 1)
' "$TMP/out"; then ok "beforeShellExecution allow drops the pgrep warn"
else bad "beforeShell warn shape: $(cat "$TMP/out")"; fi
if [ -s "$TMP/state/decisions.jsonl" ] && grep -q '"guard": "pkill"' "$TMP/state/decisions.jsonl"; then
  bad "an undelivered warn was logged as if the model saw it"
else
  ok "an undelivered warn is not logged"
fi

echo
echo "── preToolUse additional_context IS THE WARN CHANNEL ──"
rm -rf "$TMP/state"
fire pkill_self_match_guard.py "$(json "$PRE_PGREP")"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="allow" and "pgrep -f" in d.get("additional_context","") else 1)
' "$TMP/out"; then ok "preToolUse pgrep warn is additional_context"
else bad "preToolUse warn shape: $(cat "$TMP/out")"; fi
fire pkill_self_match_guard.py "$(json "$PRE_PKILL")"
record "pkill -f denies on beforeShellExecution" deny "$(permission)"

echo
echo "── WRITES: preToolUse Write IS THE FULL NEW FILE, AND IT CAN DENY ──"
WRITE_BAD='{"hook_event_name":"preToolUse","tool_name":"Write","session_id":"s1",
  "tool_input":{"file_path":"/srv/app/a.rb","content":"# why this exists\nclass A; end"}}'
WRITE_OK='{"hook_event_name":"preToolUse","tool_name":"Write","session_id":"s1",
  "tool_input":{"file_path":"/srv/app/a.rb","content":"class A; end"}}'
fire comment_discipline_guard.py "$(json "$WRITE_BAD")"
record "a comment in Write content denies before the write" deny "$(permission)"
fire comment_discipline_guard.py "$(json "$WRITE_OK")"
record "a clean Write allows" allow "$(permission)"
HEREDOC='{"hook_event_name":"beforeShellExecution","cwd":"/srv/app","sandbox":false,
  "command":"cat > /srv/app/foo.rb <<'\''EOF'\''\n# why this exists\nclass A\nend\nEOF"}'
fire comment_discipline_guard.py "$(json "$HEREDOC")"
record "a shell heredoc is still a shell command" deny "$(permission)"

echo
echo "── postToolUse tool_output IS A JSON STRING, AND THE WARN IS additional_context ──"
POST='{"hook_event_name":"postToolUse","tool_name":"Shell","cwd":"",
  "tool_input":{"command":"grep -rn x /srv | head -3","cwd":""},
  "tool_output":"{\"output\":\"a\\nb\\nc\\n\",\"exitCode\":0}","duration":12.5}'
fire truncated_output_guard.py "$(json "$POST")"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "capped output at 3" in d.get("additional_context","") and "permission" not in d else 1)
' "$TMP/out"; then ok "truncation warn reads the JSON-string output"
else bad "truncation shape: $(cat "$TMP/out")"; fi

echo
echo "── A VAGUE GOAL BLOCKS beforeSubmitPrompt ──"
PROMPT='{"hook_event_name":"beforeSubmitPrompt","session_id":"s1",
  "prompt":"keep going until it returns nothing","attachments":[]}'
fire unbounded_goal_challenge.py "$(json "$PROMPT")"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("continue") is False and "UNBOUNDED-WORK" in d.get("user_message","") and "additional_context" not in d else 1)
' "$TMP/out"; then ok "vague goal is continue false"
else bad "goals shape: $(cat "$TMP/out")"; fi

echo
echo "── STOP RE-PROMPTS FROM THE afterAgentResponse STASH ──"
rm -rf "$TMP/state"
STASH='{"hook_event_name":"afterAgentResponse","session_id":"s1","text":"I will post the numbers in the morning."}'
fire assistant_text_store.py "$(json "$STASH")"
if [ -s "$TMP/state/cursor-assistant-s1.txt" ]; then ok "afterAgentResponse stashes the reply"
else bad "stash was not written"; fi
STOP='{"hook_event_name":"stop","session_id":"s1","status":"completed","loop_count":0}'
rc=0
fire commitment_guard.py "$(json "$STOP")" || rc=$?
if [ "$rc" -eq 0 ] && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "Commitment without a mechanism" in d.get("followup_message","") else 1)
' "$TMP/out"; then ok "stop followup_message is the re-prompt"
else bad "stop rc=$rc out=$(cat "$TMP/out") err=$(cat "$TMP/err")"; fi
rc=0
fire commitment_guard.py "$(json '{"hook_event_name":"stop","session_id":"s1","status":"aborted","loop_count":0}')" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ]; then ok "an aborted stop does not re-prompt"
else bad "aborted stop rc=$rc out=$(cat "$TMP/out")"; fi

rm -rf "$TMP/state"
rc=0
fire brevity_guard.py "$(json '{"hook_event_name":"stop","session_id":"bare","status":"completed"}')" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ]; then ok "a stop with no assistant text stays quiet"
else bad "missing text rc=$rc out=$(cat "$TMP/out")"; fi
fire brevity_guard.py "$(json '{"hook_event_name":"stop","session_id":"bare","status":"completed"}')"
count="$(grep -c 'cursor sent no assistant text' "$TMP/state/decisions.jsonl" 2>/dev/null || printf 0)"
if [ "$count" = "1" ]; then ok "the missing-text gap is logged once"
else bad "missing-text logged $count times"; fi

echo
echo "── DELEGATION COUNTS preToolUse ONLY, AND A SUBAGENT RESETS IT ──"
rm -rf "$TMP/state"
fire delegation_nudge.py "$(json "$SHELL_OK")"
fire delegation_nudge.py "$(json '{"hook_event_name":"preToolUse","tool_name":"Shell","session_id":"s1","tool_input":{"command":"echo hi"}}')"
if [ "$(cat "$TMP/state/delegation-s1.count" 2>/dev/null)" = "1" ]; then
  ok "one preToolUse shell call increments once; beforeShellExecution does not"
else
  bad "delegation count is $(cat "$TMP/state/delegation-s1.count" 2>/dev/null || echo missing)"
fi
fire delegation_nudge.py "$(json '{"hook_event_name":"subagentStart","session_id":"s1","subagent_type":"generalPurpose","task":"look"}')"
record "subagentStart allows" allow "$(permission)"
if [ ! -e "$TMP/state/delegation-s1.count" ]; then ok "subagentStart resets the counter"
else bad "counter survived subagentStart"; fi

echo
echo "── MCP preToolUse tool_input MAY BE A JSON STRING ──"
LONG="$(python3 -c 'print(" ".join(["word"]*180))')"
MCP="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"MCP:slack_send_message","tool_input":json.dumps({"message":sys.argv[1]})}))' "$LONG")"
fire review_brevity_guard.py "$MCP"
record "an over-budget MCP message denies" deny "$(permission)"

echo
echo "── BAD INPUT EXITS 1 SO failClosed CAN BLOCK ──"
rc=0
printf 'not-json' | env GUARDRAILS_STATE_DIR="$TMP/state" python3 "$CURSOR/pipe_exit_code_guard.py" >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 1 ]; then ok "unparseable stdin exits 1"
else bad "unparseable stdin exited $rc"; fi

echo
echo "── INSTALL: CURSOR SHAPE, MERGE, PORTABLE, AND NO CLAUDE FILE ──"
out="$("$INSTALL" --harness cursor)"
if printf '%s' "$out" | python3 -c '
import json,sys
config=json.load(sys.stdin)
hooks=config["hooks"]
shell=hooks["beforeShellExecution"]
pre=hooks["preToolUse"]
sys.exit(0 if config.get("version")==1 and shell and pre
    and all("command" in h and "hooks" not in h for h in shell)
    and any(h.get("failClosed") is True for h in shell)
    and any(h.get("matcher")=="Shell|Write" for h in pre)
    and "afterFileEdit" not in hooks and "afterShellExecution" not in hooks
    and "beforeMCPExecution" not in hooks else 1)
'; then ok "the snippet is Cursor hooks.json and skips events that cannot enforce"
else bad "snippet shape is wrong"; fi
if printf '%s' "$out" | grep -q "$ROOT/adapters/cursor/pipe_exit_code_guard.py"; then
  ok "commands carry this checkout"
else bad "checkout path missing"; fi

printf '{"version":1,"hooks":{"beforeShellExecution":[{"command":"python3 /other/keep.py"}]},"model":"keep"}' > "$TMP/existing.json"
before="$(cat "$TMP/existing.json")"
rc=0
"$INSTALL" --harness cursor --target "$TMP/existing.json" >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$TMP/existing.json")" = "$before" ]; then
  ok "an existing file is refused without --force"
else bad "existing file rc=$rc"; fi
"$INSTALL" --harness cursor --target "$TMP/existing.json" --force >/dev/null
if python3 -c '
import json,sys
config=json.load(open(sys.argv[1]))
cmds=[h["command"] for h in config["hooks"]["beforeShellExecution"]]
sys.exit(0 if config.get("model")=="keep" and any(c.endswith("keep.py") for c in cmds)
    and sum(1 for c in cmds if c.endswith("pipe_exit_code_guard.py"))==1 else 1)
' "$TMP/existing.json"; then ok "merge keeps unrelated hooks and does not duplicate"
else bad "merge failed: $(cat "$TMP/existing.json")"; fi
"$INSTALL" --harness cursor --target "$TMP/existing.json" --force >/dev/null
if python3 -c '
import json,sys
from collections import Counter
config=json.load(open(sys.argv[1]))
for event, hooks in config["hooks"].items():
    names=[h["command"].rsplit("/",1)[-1] for h in hooks]
    if names and max(Counter(names).values())!=1:
        sys.exit(1)
sys.exit(0 if config["hooks"]["beforeShellExecution"] else 1)
' "$TMP/existing.json"; then ok "a second install leaves one copy of each guard per event"
else bad "re-install duplicated hooks"; fi

printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"true"}]}]}}' > "$TMP/claude.json"
rc=0
"$INSTALL" --harness cursor --target "$TMP/claude.json" --force >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 4 ] && grep -q 'Claude-shaped' "$TMP/err"; then
  ok "a Claude settings file is refused"
else bad "claude file rc=$rc $(cat "$TMP/err")"; fi

portable="$("$INSTALL" --harness cursor --portable)"
if printf '%s' "$portable" | grep -q '${HARNESS_ROOT:-$HOME/.harness/src}/packages/guardrails/adapters/cursor/pipe_exit_code_guard.py'; then
  ok "portable commands expand HARNESS_ROOT or ~/.harness/src"
else bad "portable snippet: $portable"; fi

REPO="$(cd "$ROOT/../.." && pwd)"
rc=0
"$REPO/install.sh" --harness claude-code --portable >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 2 ]; then ok "the root installer rejects --portable for a non-cursor harness"
else bad "root --portable claude-code exited $rc"; fi
"$REPO/install.sh" --harness cursor --portable --force --target "$TMP/root-hooks.json" >/dev/null
if python3 -c '
import json,sys
config=json.load(open(sys.argv[1]))
cmd=config["hooks"]["beforeShellExecution"][0]["command"]
sys.exit(0 if "${HARNESS_ROOT:-$HOME/.harness/src}/packages/guardrails/adapters/cursor/" in cmd else 1)
' "$TMP/root-hooks.json"; then ok "the root installer forwards --portable into hooks.json"
else bad "root portable file: $(cat "$TMP/root-hooks.json")"; fi

rc=0
bash "$CURSOR/cloud-setup.sh" -h >/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then ok "cloud-setup.sh -h exits 0"
else bad "cloud-setup -h exited $rc"; fi
rc=0
bash "$CURSOR/cloud-setup.sh" >/dev/null 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 2 ]; then ok "cloud-setup.sh without a repo exits 2"
else bad "cloud-setup no-repo exited $rc"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
