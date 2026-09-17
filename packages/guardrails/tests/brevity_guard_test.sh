#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/brevity_guard.py"
PY="$(python3 -c 'import sys; print(sys.executable)')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
pass=0
fail=0
rc=0
err=""

FENCE="$(printf '\140\140\140')"
words() { "$PY" -c 'import sys; print(" ".join(["word"] * int(sys.argv[1])))' "$1"; }
fenced() { printf '%s\n%s\n%s\n' "$FENCE" "$(words "$1")" "$FENCE"; }
table() { "$PY" -c '
print("| a | b |"); print("|---|---|")
for i in range(60): print("| %d | %s |" % (i, "cell " * 12))'; }

state() { printf '%s' "$STATE"; }

fire() {
  local payload="$1" budget="${2:-150}" wait="${3:-2}" block_at="${4:-}"
  local out
  # Avoid empty "${arr[@]}" under set -u (bash 3.2 / macOS /bin/bash).
  if [ -n "$block_at" ]; then
    out="$(printf '%s' "$payload" \
      | env GUARDRAILS_BREVITY_BUDGET="$budget" GUARDRAILS_BREVITY_FLUSH_WAIT="$wait" \
        GUARDRAILS_STATE_DIR="$STATE" HOME="$TMP" \
        GUARDRAILS_BREVITY_BLOCK_AT="$block_at" \
        "$PY" "$HOOK" 2>"$TMP/stderr")"
  else
    out="$(printf '%s' "$payload" \
      | env GUARDRAILS_BREVITY_BUDGET="$budget" GUARDRAILS_BREVITY_FLUSH_WAIT="$wait" \
        GUARDRAILS_STATE_DIR="$STATE" HOME="$TMP" \
        "$PY" "$HOOK" 2>"$TMP/stderr")"
  fi
  rc=$?
  err="$(cat "$TMP/stderr")"
  printf '%s' "$out"
}

record() {
  local name="$1" expect="$2" got="$3"
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-54s (%s)\n' "$name" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-54s expected %s, got %s\n' "$name" "$expect" "$got"
    [ -n "$err" ] && printf '       stderr: %s\n' "$err"
  fi
}

payload_reply() {
  "$PY" -c '
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": sys.argv[3],
                  "cwd": "/tmp", "transcript_path": "/nonexistent",
                  "stop_hook_active": sys.argv[2] == "true",
                  "last_assistant_message": sys.argv[1]}))
' "$1" "${2:-false}" "s-$RANDOM$RANDOM"
}

verdict() { if [ "$rc" -eq 2 ]; then printf 'block'; else printf 'pass'; fi; }

check() {
  rm -rf "$(state)"
  fire "$(payload_reply "$3")" "${4:-150}" 2 "${5:-}" >/dev/null
  record "$1" "$2" "$(verdict)"
}

logged() { grep -q "$1" "$(state)/brevity.jsonl" 2>/dev/null; }
stated() { grep -q "$1" "$(state)"/brevity-last-*.json 2>/dev/null; }

echo "IT BLOCKS — past the block line (2x the budget by default) exits 2 with a rewrite instruction:"
check "400 prose words" block "$(words 400)"
check "prose past the line beside a big code block" block "$(words 400)$(fenced 400)"
check "the budget is configurable (10)" block "$(words 30)" 10

rm -rf "$(state)"
fire "$(payload_reply "$(words 400)")" >/dev/null
if printf '%s' "$err" | grep -q 'Reply was 400 prose words, budget 150'; then
  pass=$((pass + 1)); echo "  ok   stderr names the count and the budget"
else
  fail=$((fail + 1)); printf '  FAIL stderr did not name the count: %s\n' "$err"
fi
if printf '%s' "$err" | grep -q 'Rewrite: lead with the result'; then
  pass=$((pass + 1)); echo "  ok   stderr asks for a rewrite, not more text"
else
  fail=$((fail + 1)); printf '  FAIL stderr did not ask for a rewrite: %s\n' "$err"
fi

echo
echo "MUST NOT BLOCK — legitimate long output and compliant replies:"
check "400 words inside a code fence" pass "$(fenced 400)"
check "a 60-row markdown table" pass "$(table)"
check "a table plus 20 words of prose" pass "$(words 20)$(table)"
check "150 prose words, exactly at budget" pass "$(words 150)"
check "a short reply" pass "Shipped. CI green."
check "an empty reply" pass ""
check "an unclosed fence swallows the rest" pass "$(printf '%s\n%s\n' "$FENCE" "$(words 400)")"
check "the budget is configurable (500)" pass "$(words 300)" 500

echo
echo "THE MARGINAL TIER — over budget but under the block line is allowed and recorded:"
check "160 prose words" pass "$(words 160)"
if logged '"words": 160' && logged '"over": true' && logged '"blocked": false'; then
  pass=$((pass + 1)); echo "  ok   the 160-word overage is logged as over, not blocked"
else
  fail=$((fail + 1)); echo "  FAIL the 160-word overage was not logged as an allowed overage"
fi
if stated '"words": 160' && stated '"count": 1' && stated '"blocked": false'; then
  pass=$((pass + 1)); echo "  ok   the streak state carries the overage for the next prompt"
else
  fail=$((fail + 1)); echo "  FAIL the streak state does not carry the allowed overage"
fi
check "299 prose words, one under the default line" pass "$(words 299)"
check "300 prose words, exactly on the default line" pass "$(words 300)"
check "301 prose words, one over the default line" block "$(words 301)"
check "BLOCK_AT=1.5: 230 words is past 225" block "$(words 230)" 150 1.5
check "BLOCK_AT=1.5: 220 words is under 225" pass "$(words 220)" 150 1.5
check "BLOCK_AT=0: 800 words never blocks" pass "$(words 800)" 150 0
if logged '"words": 800' && logged '"over": true' && logged '"blocked": false'; then
  pass=$((pass + 1)); echo "  ok   BLOCK_AT=0 still records the overage"
else
  fail=$((fail + 1)); echo "  FAIL BLOCK_AT=0 did not record the overage"
fi

echo
echo "THE LOOP GUARD — it blocks at most once per turn:"
rm -rf "$(state)"
fire "$(payload_reply "$(words 400)" true)" >/dev/null
record "stop_hook_active suppresses the block" pass "$(verdict)"

echo
echo "NO TERMINAL NOISE — the count goes to the model, never to the user's feed:"
rm -rf "$(state)"
out="$(fire "$(payload_reply "$(words 400)")")"
if [ -z "$out" ]; then
  pass=$((pass + 1)); echo "  ok   a blocked reply prints nothing on stdout"
else
  fail=$((fail + 1)); printf '  FAIL printed on stdout: %s\n' "$out"
fi
rm -rf "$(state)"
out="$(fire "$(payload_reply "$(words 160)")")"
if [ -z "$out" ]; then
  pass=$((pass + 1)); echo "  ok   an allowed overage prints nothing on stdout"
else
  fail=$((fail + 1)); printf '  FAIL printed on stdout: %s\n' "$out"
fi

echo
echo "THE FLUSH RACE — the payload field is the source of truth:"
"$PY" - "$TMP" <<'PY'
import json, sys
root = sys.argv[1]
with open(f"{root}/t-stale.jsonl", "w") as fh:
    fh.write(json.dumps({"type": "assistant", "uuid": "u-old", "message": {
        "content": [{"type": "text", "text": "Pushing to the PR branch:"}]}}) + "\n")
PY
rm -rf "$(state)"
fire "$("$PY" -c '
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": "race-1", "cwd": "/tmp",
                  "transcript_path": sys.argv[1], "stop_hook_active": False,
                  "last_assistant_message": sys.argv[2]}))
' "$TMP/t-stale.jsonl" "$(words 400)")" >/dev/null
record "a 400-word reply behind a 4-word interstitial" block "$(verdict)"
if grep -q '"source": "payload"' "$(state)/brevity.jsonl" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok   the log records which source was measured"
else
  fail=$((fail + 1)); echo "  FAIL the log does not record the source"
fi

echo
echo "THE TRANSCRIPT FALLBACK — used only when the payload field is absent:"
payload_no_field() {
  "$PY" -c '
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": sys.argv[1], "cwd": "/tmp",
                  "transcript_path": sys.argv[2], "stop_hook_active": False}))
' "$1" "$2"
}
write_entry() {
  "$PY" -c '
import json, sys
with open(sys.argv[1], sys.argv[4]) as fh:
    fh.write(json.dumps({"type": "assistant", "uuid": sys.argv[2], "message": {
        "content": [{"type": "text", "text": sys.argv[3]}]}}) + "\n")
' "$1" "$2" "$3" "$4"
}

rm -rf "$(state)"
write_entry "$TMP/t-fb.jsonl" u-1 "$(words 400)" w
fire "$(payload_no_field fb-1 "$TMP/t-fb.jsonl")" >/dev/null
record "an unseen last message is measured" block "$(verdict)"

rm -rf "$(state)"
mkdir -p "$(state)"
write_entry "$TMP/t-seen.jsonl" u-seen "$(words 400)" w
printf '{"session":"fb-2","uuid":"u-seen"}' > "$(state)/brevity-last-fb-2.json"
fire "$(payload_no_field fb-2 "$TMP/t-seen.jsonl")" 150 0.3 >/dev/null
record "an already-seen uuid is not re-measured" pass "$(verdict)"
if grep -q '"status": "unmeasured"' "$(state)/brevity.jsonl" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok   an unflushed reply is logged LOUDLY, not as compliance"
else
  fail=$((fail + 1)); echo "  FAIL an unflushed reply was logged as a clean run"
fi

rm -rf "$(state)"
mkdir -p "$(state)"
write_entry "$TMP/t-late.jsonl" u-seen "short interstitial" w
printf '{"session":"fb-3","uuid":"u-seen"}' > "$(state)/brevity-last-fb-3.json"
( sleep 0.4; write_entry "$TMP/t-late.jsonl" u-new "$(words 400)" a ) &
fire "$(payload_no_field fb-3 "$TMP/t-late.jsonl")" 150 3 >/dev/null
wait
record "a reply flushed 0.4s late is still measured" block "$(verdict)"

echo
echo "BROKEN INPUT — must never take the turn down:"
survives() {
  local name="$1" stdin="$2"
  if printf '%s' "$stdin" | GUARDRAILS_STATE_DIR="$STATE" HOME="$TMP" "$PY" "$HOOK" >/dev/null 2>&1
  then
    pass=$((pass + 1)); printf '  ok   %-54s (exit 0)\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %-54s did not exit 0\n' "$name"
  fi
}
survives "non-JSON stdin" 'not json'
survives "a missing transcript and no payload field" \
  '{"transcript_path":"/nonexistent","session_id":"x"}'
survives "an empty payload" '{}'

echo
echo "SIDE EFFECTS — the log and the streak state are the evidence trail:"
rm -rf "$(state)"
fire "$(payload_reply "$(words 300)")" >/dev/null
if [ -s "$(state)/brevity.jsonl" ]; then
  pass=$((pass + 1)); echo "  ok   brevity.jsonl written"
else
  fail=$((fail + 1)); echo "  FAIL brevity.jsonl not written"
fi
if [ -n "$(ls "$(state)"/brevity-last-*.json 2>/dev/null)" ]; then
  pass=$((pass + 1)); echo "  ok   per-session streak state written"
else
  fail=$((fail + 1)); echo "  FAIL per-session streak state not written"
fi
rm -rf "$(state)"
fire "$(payload_reply "Shipped.")" >/dev/null
if grep -q '"over": false' "$(state)/brevity.jsonl" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok   a compliant reply is logged too, so the denominator is visible"
else
  fail=$((fail + 1)); echo "  FAIL compliant replies are not logged"
fi

echo
echo "THE DEFAULT STATE DIRECTORY — no harness path, no configuration required:"
rm -rf "$TMP/.local"
printf '%s' "$(payload_reply "$(words 300)")" \
  | env -u GUARDRAILS_STATE_DIR -u XDG_STATE_HOME HOME="$TMP" "$PY" "$HOOK" >/dev/null 2>&1
if [ -s "$TMP/.local/state/harness-guardrails/brevity.jsonl" ]; then
  pass=$((pass + 1)); echo "  ok   state lands in \$HOME/.local/state/harness-guardrails"
else
  fail=$((fail + 1)); echo "  FAIL nothing written to the XDG default state directory"
fi
rm -rf "$TMP/.local"
printf '%s' "$(payload_reply "$(words 300)")" \
  | env -u GUARDRAILS_STATE_DIR XDG_STATE_HOME="$TMP/xdg" HOME="$TMP" "$PY" "$HOOK" >/dev/null 2>&1
if [ -s "$TMP/xdg/harness-guardrails/brevity.jsonl" ]; then
  pass=$((pass + 1)); echo "  ok   XDG_STATE_HOME is honoured"
else
  fail=$((fail + 1)); echo "  FAIL XDG_STATE_HOME was ignored"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
