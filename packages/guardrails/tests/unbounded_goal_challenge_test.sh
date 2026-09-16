#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/unbounded_goal_challenge.py"
pass=0
fail=0

run() {
  python3 -c '
import json, sys
print(json.dumps({"prompt": sys.argv[1], "session_id": "test"}))
' "$1" | python3 "$HOOK" 2>/dev/null
}

check() {
  local expect="$1" name="$2" prompt="$3" out verdict
  out="$(run "$prompt")"
  if [ -n "$out" ]; then verdict="fire"; else verdict="silent"; fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1))
    printf '  ok   %-58s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1))
    printf '  FAIL %-58s expected %s, got %s\n' "$name" "$expect" "$verdict"
  fi
}

names() {
  local name="$1" kind="$2" prompt="$3" out
  out="$(run "$prompt")"
  if printf '%s' "$out" | grep -q "it names $kind"; then
    pass=$((pass + 1)); printf '  ok   %-58s (%s)\n' "$name" "$kind"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s did not name %s\n' "$name" "$kind"
  fi
}

NOTIFICATION='<task-notification>
<task-id>a65be43ddc4</task-id>
<status>completed</status>
<summary>Agent "panel sweep" finished</summary>
<note>A task-notification fires each time this agent stops with no live background
work. Do not loop on it forever or repeat the same check indefinitely.</note>
</task-notification>'

echo "── it still fires on an unbounded request ──"
check fire "an unbounded /goal" "/goal run the panel review until it comes back with nothing"
check fire "keep going, forever" "keep going forever on the WAF rules"
check fire "iterate until clean" "/loop iterate on the specs until clean"
check fire "repeat until no new findings" "repeat the sweep until no new findings"
check fire "a prompt that merely mentions the tag" \
  "Why did the guard fire on a <task-notification>? It said keep going until nothing is left."

echo "── the note classifies the terminator it found ──"
names "an exhaustion condition" "a 'until it returns nothing' condition" \
  "/goal run the panel review until it comes back with nothing"
names "a subjective condition" "a subjective completion condition" \
  "/loop keep going until you are satisfied"
names "an open-ended duration" "an open-ended duration" \
  "keep going forever on the WAF rules"

echo "── ordinary completion wording is not an unbounded loop ──"
check silent "iterate until done" "iterate until done"
check silent "until the migration is complete" \
  "/loop iterate on the specs until the migration is complete"
check silent "until it passes CI" "repeat the deploy until it passes CI"
check silent "until the tests pass" "keep going until the tests pass"
check silent "until the build finishes" "/goal repeat the build until it is finished"

echo "── it stays out of machine-generated prompts ──"
check silent "a real task-notification (the 2026-09-02 false positive)" "$NOTIFICATION"
check silent "a task-notification with a leading newline" "
$NOTIFICATION"
check silent "a system-reminder" \
  "<system-reminder>keep going until nothing is left, repeat forever</system-reminder>"
check silent "a bracketed system notification" \
  "[SYSTEM NOTIFICATION] the job will repeat each time indefinitely"
check silent "local command output" \
  "<local-command-stdout>iterate until clean, forever</local-command-stdout>"

echo "── it stays out of the way otherwise ──"
check silent "a bounded goal" "/goal 3 rounds of panel review, then report"
check silent "a plain question" "what is the behind-count on the checkout service?"
check silent "an empty prompt" ""
check silent "an unbounded phrase with no autonomous work" \
  "the incident ran until nothing was left of the cache"

echo "── broken input must never take the turn down ──"
survives() {
  local name="$1" stdin="$2"
  if printf '%s' "$stdin" | python3 "$HOOK" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok   %-58s (exit 0)\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s did not exit 0\n' "$name"
  fi
}
survives "non-JSON stdin" 'not json'
survives "an empty payload" '{}'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
