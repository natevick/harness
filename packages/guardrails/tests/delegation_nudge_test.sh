#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/delegation_nudge.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

fire() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "session_id": sys.argv[2],
                  "tool_input": {"command": "ls"}}))
' "$1" "$2" | env GUARDRAILS_STATE_DIR="$TMP/state" python3 "$HOOK" 2>/dev/null
}

ok() {
  pass=$((pass + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
}

echo "── 31 shell calls in one session ──"
nudges=""
for i in $(seq 1 31); do
  out="$(fire Bash s1)"
  [ -n "$out" ] && nudges="$nudges $i"
done
if [ "$nudges" = " 30" ]; then ok "exactly one nudge, at call 30 (fired at:$nudges)"
else bad "expected a single nudge at 30, got:$nudges"; fi

out="$(fire Bash s1)"
for i in $(seq 33 60); do out="$(fire Bash s1)"; done
if [ -n "$out" ]; then ok "it re-emits at 60"
else bad "no second nudge at 60"; fi

echo "── the nudge is additionalContext, never a deny ──"
if printf '%s' "$out" | grep -q '"additionalContext"' &&
   ! printf '%s' "$out" | grep -q 'permissionDecision'; then
  ok "additionalContext with no permissionDecision"
else
  bad "wrong shape: $out"
fi
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "spawn a worker" in d["hookSpecificOutput"]["additionalContext"] else 1)'; then
  ok "valid JSON that names the action"
else
  bad "not valid JSON, or the text is missing: $out"
fi

echo "── delegation resets the counter ──"
for i in $(seq 1 29); do fire Bash s2 >/dev/null; done
fire Agent s2 >/dev/null
if [ ! -f "$TMP/state/delegation-s2.count" ]; then ok "an Agent call clears the counter"
else bad "counter survived an Agent call: $(cat "$TMP/state/delegation-s2.count")"; fi

nudges=""
for i in $(seq 1 5); do
  out="$(fire Bash s2)"
  [ -n "$out" ] && nudges="$nudges $i"
done
if [ -z "$nudges" ]; then ok "no nudge in the 5 shell calls after the reset"
else bad "nudged after a reset at:$nudges"; fi

for tool in Workflow SendMessage; do
  for i in $(seq 1 29); do fire Bash "s-$tool" >/dev/null; done
  fire "$tool" "s-$tool" >/dev/null
  if [ ! -f "$TMP/state/delegation-s-$tool.count" ]; then ok "a $tool call clears the counter"
  else bad "$tool did not clear the counter"; fi
done

echo "── other tools neither count nor reset ──"
for i in $(seq 1 29); do fire Bash s3 >/dev/null; done
for tool in Read Edit Grep Glob WebFetch; do fire "$tool" s3 >/dev/null; done
if [ "$(cat "$TMP/state/delegation-s3.count")" = "29" ]; then ok "Read/Edit/Grep/Glob/WebFetch leave the count alone"
else bad "count moved to $(cat "$TMP/state/delegation-s3.count")"; fi
out="$(fire Bash s3)"
if [ -n "$out" ]; then ok "the 30th shell call still nudges after unrelated tool calls"
else bad "no nudge on the 30th shell call"; fi

echo "── sessions are independent ──"
for i in $(seq 1 29); do fire Bash sA >/dev/null; done
nudges=""
for i in $(seq 1 29); do
  out="$(fire Bash sB)"
  [ -n "$out" ] && nudges="$nudges $i"
done
if [ -z "$nudges" ] && [ "$(cat "$TMP/state/delegation-sA.count")" = "29" ]; then
  ok "session B does not inherit session A's count"
else
  bad "cross-session leak (B nudged at:$nudges)"
fi

echo "── broken input must never break a tool call ──"
rc=0
printf 'not json' | env GUARDRAILS_STATE_DIR="$TMP/state" python3 "$HOOK" >"$TMP/o" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/o" ]; then ok "non-JSON stdin exits 0 and prints nothing"
else bad "non-JSON stdin: rc=$rc out=$(cat "$TMP/o")"; fi

printf 'garbage' >"$TMP/state/delegation-s4.count"
out="$(fire Bash s4)"
if [ "$(cat "$TMP/state/delegation-s4.count")" = "1" ] && [ -z "$out" ]; then
  ok "a corrupt counter file restarts at 1"
else
  bad "corrupt counter left $(cat "$TMP/state/delegation-s4.count")"
fi

out="$(printf '{"tool_name":"Bash","session_id":"../../etc/passwd"}' \
  | env GUARDRAILS_STATE_DIR="$TMP/state" python3 "$HOOK" 2>/dev/null)"
if [ -z "$out" ] && [ -f "$TMP/state/delegation-etcpasswd.count" ]; then
  ok "a session id full of path separators cannot escape the state directory"
else
  bad "session id sanitising failed: $(ls "$TMP/state")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
