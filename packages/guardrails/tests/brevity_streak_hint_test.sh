#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/brevity_streak_hint.py"
PY="$(python3 -c 'import sys; print(sys.executable)')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"
pass=0
fail=0

seed() {
  printf '%s' "$2" > "$STATE/brevity-last-$1.json"
}

run() {
  printf '{"session_id":"%s"}' "$1" \
    | GUARDRAILS_STATE_DIR="$STATE" HOME="$TMP" "$PY" "$HOOK" 2>/dev/null
}

record() {
  local name="$1" expect="$2" output="$3" verdict
  if [ -n "$output" ]; then verdict="hint"; else verdict="silent"; fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-54s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-54s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$output"
  fi
}

echo "IT READS THE HOOK PAYLOAD AT ALL — the defect this test exists for:"
seed over '{"session":"over","words":300,"budget":150,"count":2,"source":"payload"}'
out="$(run over)"
record "an over-budget previous reply injects a hint" hint "$out"
if printf '%s' "$out" | grep -q '300 prose words, 2.0x the 150-word budget'; then
  pass=$((pass + 1)); echo "  ok   the hint carries the count and the multiple"
else
  fail=$((fail + 1)); printf '  FAIL the hint text is wrong: %s\n' "$out"
fi
if printf '%s' "$out" | grep -q '2nd over-budget reply'; then
  pass=$((pass + 1)); echo "  ok   the hint carries the streak position"
else
  fail=$((fail + 1)); printf '  FAIL the streak position is wrong: %s\n' "$out"
fi

echo
echo "THE TWO TIERS — the nudge says whether the reply was blocked or merely over:"
seed allowed '{"session":"allowed","words":160,"budget":150,"count":1,"blocked":false,"block_at":2.0,"source":"payload"}'
out="$(run allowed)"
record "an allowed overage still injects a hint" hint "$out"
if printf '%s' "$out" | grep -q '160 prose words, 1.1x the 150-word budget; allowed through, but over 300 words it would have been blocked'; then
  pass=$((pass + 1)); echo "  ok   it names the count and the block line, and says it was allowed"
else
  fail=$((fail + 1)); printf '  FAIL the allowed-tier text is wrong: %s\n' "$out"
fi
if printf '%s' "$out" | grep -q '1st over-budget reply'; then
  pass=$((pass + 1)); echo "  ok   an allowed overage still counts toward the streak"
else
  fail=$((fail + 1)); printf '  FAIL the streak position is wrong: %s\n' "$out"
fi
seed blocked '{"session":"blocked","words":320,"budget":150,"count":3,"blocked":true,"block_at":2.0,"source":"payload"}'
out="$(run blocked)"
if printf '%s' "$out" | grep -q '320 prose words, 2.1x the 150-word budget; blocked for passing 300 words, and rewritten'; then
  pass=$((pass + 1)); echo "  ok   a blocked reply is described as blocked"
else
  fail=$((fail + 1)); printf '  FAIL the blocked-tier text is wrong: %s\n' "$out"
fi
if printf '%s' "$out" | grep -q '3rd over-budget reply'; then
  pass=$((pass + 1)); echo "  ok   escalation is kept across both tiers"
else
  fail=$((fail + 1)); printf '  FAIL the streak position is wrong: %s\n' "$out"
fi
seed off '{"session":"off","words":800,"budget":150,"count":1,"blocked":false,"block_at":0.0,"source":"payload"}'
out="$(run off)"
if printf '%s' "$out" | grep -q '800 prose words, 5.3x the 150-word budget; allowed through; blocking is off'; then
  pass=$((pass + 1)); echo "  ok   with blocking off the hint says so instead of naming a line"
else
  fail=$((fail + 1)); printf '  FAIL the blocking-off text is wrong: %s\n' "$out"
fi

echo
echo "IT STAYS SILENT — anything that is not a fresh violation:"
seed under '{"session":"under","words":20,"budget":150,"count":0,"source":"payload"}'
record "a compliant previous reply" silent "$(run under)"
seed exact '{"session":"exact","words":150,"budget":150,"count":0,"source":"payload"}'
record "a reply exactly at budget" silent "$(run exact)"
seed unmeasured '{"session":"unmeasured","words":0,"budget":150,"count":0,"source":"unflushed"}'
record "an unmeasured reply" silent "$(run unmeasured)"
record "a session with no state file" silent "$(run nostate)"
seed stale '{"session":"stale","words":300,"budget":150,"count":1,"source":"payload"}'
touch -d '2 hours ago' "$STATE/brevity-last-stale.json"
record "state older than an hour" silent "$(run stale)"
seed corrupt 'not json'
record "corrupt state" silent "$(run corrupt)"

echo
echo "PER-SESSION — one session must not inject into another:"
seed other '{"session":"other","words":300,"budget":150,"count":1,"source":"payload"}'
record "a different session id" silent "$(run notother)"

echo
echo "BROKEN INPUT — must never take the turn down:"
survives() {
  local name="$1" stdin="$2"
  if printf '%s' "$stdin" | GUARDRAILS_STATE_DIR="$STATE" HOME="$TMP" "$PY" "$HOOK" \
    >/dev/null 2>&1
  then
    pass=$((pass + 1)); printf '  ok   %-54s (exit 0)\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %-54s did not exit 0\n' "$name"
  fi
}
survives "non-JSON stdin" 'not json'
survives "an empty payload" '{}'
survives "a session id full of path separators" '{"session_id":"../../etc/passwd"}'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
