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
check silent "repeat inside repeated is not a marker" \
  "The numbers were repeated in the log."
check silent "implement dark mode names an outcome" "Implement dark mode"
check silent "until does not pair with a later paragraph" \
  "$(printf '%s\n' 'Implement the parser.' '' 'Leave it until the design is settled.' 'NOTHING gets posted.')"

echo "── a bounded until-clause is not an unbounded finish ──"
check silent "npm test zero failures, max 5 rounds" \
  'loop until `npm test` has zero failures, max 5 rounds'
check silent "zero failing tests" "loop until zero failing tests"
check silent "zero failures" "loop until zero failures"
check silent "backtick command is clean" 'loop until `npm test` is clean'
check silent "build is clean" "loop until the build is clean"
check silent "cap on an until-clause" "loop until clean, max 5 rounds"
check silent "cap on a subjective until-clause" "loop until you're satisfied, max 5 rounds"
check silent "time budget" "loop until clean, time budget"
check silent "double-quoted examples" \
  'Fix the guard so "loop until clean" still warns but "loop until `npm test` has zero failures, max 5 rounds" passes'
check silent "backtick-quoted example" \
  'Fix the guard so `loop until clean` still warns'
check fire "quoted example plus a bare until clean" \
  'Fix the guard so "loop until clean" still warns, then loop until clean'
check fire "a cited cap is not a cap" \
  'loop until clean, and the note says "max 5 rounds"'
check fire "a cited command is not the instruction" \
  'loop until clean, as in "loop until `npm test` has zero failures"'
check silent "period inside a quoted example" \
  'Fix the guard so "loop until clean. still warns" is quoted'
check fire "period inside a cited cap" \
  'loop until clean, he said "max 5 rounds. then stop"'
check fire "a later command does not cover an earlier sentence" \
  'loop until clean. Then run `npm test`.'

echo "── a bare unbounded finish still warns ──"
check fire "loop until clean" "loop until clean"
check fire "panel returns no findings" "keep going until the panel returns no findings"
check fire "repeat forever" "repeat forever"
check fire "loop until nothing" "loop until nothing"
check fire "until no more findings" "loop until no more findings"
check fire "until you're satisfied" "loop until you're satisfied"
check fire "keep going indefinitely" "keep going indefinitely"
check fire "forever keeps its warning beside a cap" "repeat forever, max 5 rounds"
check fire "forever beside five rounds" "repeat forever, five rounds"

echo "── a count of rounds needs no max ──"
check silent "3 rounds then report" "loop until clean, 3 rounds then report"
check silent "3 iterations" "loop until clean, 3 iterations"
check silent "4 attempts" "loop until clean, 4 attempts"
check silent "at most 3 rounds" "loop until clean, at most 3 rounds"
check silent "up to 2 iterations" "loop until clean, up to 2 iterations"
check silent "at most twenty attempts" "loop until clean, at most twenty attempts"

echo "── number words are caps ──"
check silent "max five rounds" "loop until clean, max five rounds"
check silent "ten minutes" "loop until clean, ten minutes"
check silent "nineteen rounds" "loop until clean, nineteen rounds"
check silent "sixty minutes" "loop until clean, sixty minutes"
check silent "hundred tokens" "loop until clean, hundred tokens"
check silent "one hour" "loop until clean, one hour"

echo "── a severity floor or diminishing returns is a bound ──"
check silent "nothing above medium" \
  "loop until clean, stop when a round returns nothing above medium"
check silent "nothing above critical" \
  "loop until clean, stop when a round returns nothing above critical"
check silent "previously known findings" \
  "loop until clean, stop when a round's findings are all previously known"
check silent "previously-known findings" \
  "loop until clean, stop when a round's findings are all previously-known"
check silent "below medium" "loop until clean, below medium"
check silent "below low" "loop until clean, below low"

echo "── every quoted bound in NOTE passes inside an until-sentence ──"
pkg="$(cd "$(dirname "$0")/.." && pwd)"
if ! bounds="$(python3 -c '
import re, sys
sys.path.insert(0, sys.argv[1])
from guardrails.goals import NOTE
found = re.findall(r"\"([^\"\n]+)\"", NOTE)
if not found:
    raise SystemExit(1)
sys.stdout.write("\n".join(found))
' "$pkg")"; then
  fail=$((fail + 1))
  printf '  FAIL %-58s extractor found no bounds\n' "NOTE quoted bounds"
else
  while IFS= read -r quote; do
    [ -n "$quote" ] || continue
    check silent "NOTE: $quote" "loop until clean, $quote"
  done <<EOF
$bounds
EOF
fi

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
