#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/commitment_guard.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

printf '{}' > "$TMP/settings.json"
printf 'next steps' > "$TMP/HANDOFF.md"

transcript() {
  python3 -c '
import json, sys
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
    fh.write(json.dumps({"type": "assistant",
                         "message": {"content": [{"type": "text", "text": sys.argv[2]}]}}) + "\n")
' "$1" "$2"
}

run_hook() {
  python3 -c '
import json, sys
print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test",
                  "stop_hook_active": sys.argv[2] == "true"}))
' "$1" "${2:-false}" | python3 "$HOOK" 2>"$TMP/err.txt"
}

check() {
  local expect="$1" name="$2" text="$3" stop_active="${4:-false}"
  local file="$TMP/t-$RANDOM.jsonl" verdict rc=0
  transcript "$file" "$text"
  run_hook "$file" "$stop_active" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then verdict="block"; else verdict="pass"; fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1))
    printf '  ok   %-58s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1))
    printf '  FAIL %-58s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$(cat "$TMP/err.txt")"
  fi
}

echo "── MUST BLOCK — a promise with nothing behind it ──"
check block "the overnight check that never got scheduled" \
  "I'll check the overnight window in the morning."
check block "I will …" "I will post the rule-126 numbers once the window closes."
check block "I'm going to …" "I'm going to sweep the remaining open PRs."
check block "shortly" "Handing this back. I'll follow up on the pending allowlist add shortly."
check block "I'll check back" "I'll check back after the deploy."
check block "tomorrow, no first-person future verb" "Tomorrow I take another pass at the ledger."
check block "an absolute path that does not exist" \
  "I'll write it up in /var/tmp/guardrails-not-a-real-file-93217.md."
check block "an away summary with an open decision" \
  "Next: your review of the brief and a yes on whether I branch and build. I'll pick it up from there."

echo "── MUST PASS — a mechanism is named ──"
check pass "a cron expression" \
  "I'll check it — scheduled: \`20 8 * * * run-job.sh x\`"
check pass "a cron line inside a fence" \
  "I'll re-run the window overnight.

\`\`\`
0 1 * * * /opt/jobs/run-job.sh waf-watch
\`\`\`"
check pass "crontab" "I will add it to my crontab tonight."
check pass "a PR URL" \
  "I'll take the video.js fallback — tracked at https://github.com/example-org/example-repo/pull/35287."
check pass "an issue URL" \
  "I'm going to park it on https://github.com/example-org/example-dotfiles/issues/7."
check pass "an absolute path that exists" \
  "I'll work from $TMP/settings.json in the morning."
check pass "a handoff file that exists" \
  "I'll resume this tomorrow from the handoff at $TMP/HANDOFF.md."
check pass "a TASKS.md row" "I'll pick up T20 — row added to TASKS.md."
check pass "ScheduleWakeup" "I will re-check the alarm — ScheduleWakeup set for 08:00 PT."
check pass "CronCreate" "I will schedule it — CronCreate for 08:00 PT."
check pass "a /loop" "I will keep at it — /loop every 20 minutes."
check pass "the explicit downgrade" \
  "I'd look at it tomorrow, but there is no mechanism behind that, so treat it as unowned."

echo "── MUST PASS — false positives this must not fire on ──"
check pass "no commitment at all" "22 passed, 0 failed. PR is up."
check pass "a promise inside a fenced block" \
  "The transcript said:

\`\`\`
I'll check the overnight window in the morning.
\`\`\`"
check pass "a promise in a quoted line" \
  "The user's words:

> I'll look at it tomorrow."
check pass "overnight with no first-person subject" \
  "The watch re-armed 09-01 and runs overnight until it self-retires 09-15."
check pass "an offer waiting on the user is not a commitment" \
  "The sweep is still paused — say the word and I'll uncomment it."
check pass "a conditional offer" \
  "If you want the overnight window checked, I'll take it."
check block "an offer plus a real promise still blocks" \
  "Say the word and I'll uncomment the sweep. Separately, I'll post the rule-126 numbers in the morning."

echo "── MUST PASS — an instruction to the user, then \"and I'll\" ──"
check pass "reply with a quoted phrase" 'Reply "apply phase 2" and I'"'"'ll push it.'
check pass "send, and I'll confirm" "Send a photo of the bottom label and I'll confirm."
check pass "either say **go** and I'll" "You can either say **go** and I'll launch it from here, or hold."
check block "narration with and I'll mid-sentence is still a promise" \
  "I'll run the suite and I'll push it tomorrow."

echo "── MUST PASS — a conditional or a question is not a promise ──"
check pass "a sentence starting with If" "If the preflight fails, I'll re-run it tomorrow."
check pass "If after a bullet and bold marker" "- **If** it misses, I'll come to you with the numbers tomorrow."
check block "a trailing if-clause is still a promise" "I'll merge it tomorrow if CI passes."
check pass "a question to the user" "Keep it, or I'll replace it some other way?"
check block "a question beside a real promise" "I'll check it tomorrow. Sound good?"
check pass "a real question about a promise" "Should I push this tonight?"
check block "a promise with a tag question" "I'll push the fix to main tonight, okay?"
check block "a tag question with no comma" "I'll push the fix to main tonight okay?"
check block "a tag question after a dash" "I'll push the fix tonight — does that work?"
check block "a promise behind an opener, then a tag" "Tonight I'll push the fix, right?"
check block "a conjunction opener, then a tag" "Okay, I'll push the fix tonight, yeah?"

echo "── MUST PASS — a mechanism was launched this turn ──"
launched() {
  local expect="$1" name="$2" tool="$3" input="$4" position="$5"
  local file="$TMP/l-$RANDOM.jsonl" verdict rc=0
  python3 -c '
import json, sys
path, tool, tool_input, position = sys.argv[1:5]
human = {"type": "user", "message": {"content": "go"}}
launch = {"type": "assistant", "message": {"content": [
    {"type": "tool_use", "id": "t1", "name": tool, "input": json.loads(tool_input)}]}}
result = {"type": "user", "message": {"content": [
    {"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}
final = {"type": "assistant", "message": {"content": [
    {"type": "text", "text": "I will pick this up when they report back."}]}}
wake = {"type": "user", "message": {"content": "<task-notification>done</task-notification>"}}
order = {
    "this-turn": [human, launch, result, final],
    "earlier-turn": [launch, result, human, final],
    "after-wake": [human, launch, result, wake, final],
}[position]
with open(path, "w") as fh:
    for record in order:
        fh.write(json.dumps(record) + "\n")
' "$file" "$tool" "$input" "$position"
  run_hook "$file" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then verdict="block"; else verdict="pass"; fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-58s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s expected %s, got %s\n' "$name" "$expect" "$verdict"
  fi
}
launched pass "a background Bash" Bash '{"command":"sleep 600","run_in_background":true}' this-turn
launched pass "an Agent" Agent '{"prompt":"review it"}' this-turn
launched pass "a SendMessage" SendMessage '{"to":"reviewer","message":"go"}' this-turn
launched pass "a Monitor" Monitor '{"command":"tail -f x"}' this-turn
launched pass "a CronCreate" CronCreate '{"cron":"0 8 * * *"}' this-turn
launched pass "a ScheduleWakeup" ScheduleWakeup '{"delaySeconds":600}' this-turn
launched pass "a launch before a task-notification wake, same turn" Agent '{"prompt":"x"}' after-wake
launched block "a foreground Bash is not a mechanism" Bash '{"command":"sleep 1"}' this-turn
launched block "a launch in an earlier turn does not cover this one" Agent '{"prompt":"x"}' earlier-turn

echo "── a malformed record in the turn must not take the guard down ──"
malformed() {
  local expect="$1" name="$2" message="$3" launch="$4"
  local file="$TMP/m-$RANDOM.jsonl" rc=0 verdict
  python3 -c '
import json, sys
path, message, launch = sys.argv[1:4]
records = [{"type": "user", "message": {"content": "go"}},
           {"type": "assistant", "message": json.loads(message)}]
if launch == "yes":
    records.append({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Agent", "input": {"prompt": "x"}}]}})
with open(path, "w") as fh:
    for record in records:
        fh.write(json.dumps(record) + "\n")
' "$file" "$message" "$launch"
  python3 -c '
import json, sys
print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test", "stop_hook_active": False,
                  "last_assistant_message": "I will pick this up tomorrow."}))
' "$file" | python3 "$HOOK" 2>"$TMP/err.txt" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then verdict="block"; else verdict="pass"; fi
  if [ "$verdict" = "$expect" ] && ! grep -q Traceback "$TMP/err.txt"; then
    pass=$((pass + 1)); printf '  ok   %-58s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$(tail -1 "$TMP/err.txt")"
  fi
}
malformed block "a null message" "null" no
malformed block "a string message" '"oops"' no
malformed pass "a null message before a launch" "null" yes

echo "── THE ACCEPTED LIST IS CONFIGURATION, NOT A HOUSE STYLE ──"
configured() {
  local expect="$1" name="$2" mechanisms="$3" text="$4"
  local file="$TMP/c-$RANDOM.jsonl" verdict rc=0
  transcript "$file" "$text"
  python3 -c '
import json, sys
print(json.dumps({"transcript_path": sys.argv[1], "session_id": "test",
                  "stop_hook_active": False}))
' "$file" | env GUARDRAILS_COMMITMENT_MECHANISMS="$mechanisms" python3 "$HOOK" \
    >/dev/null 2>"$TMP/err.txt" || rc=$?
  if [ "$rc" -eq 2 ]; then verdict="block"; else verdict="pass"; fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-58s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s expected %s, got %s\n' "$name" "$expect" "$verdict"
  fi
}
configured pass "a name the deployment configured is accepted" "crontab,Scheduler" \
  "I will re-check the alarm — Scheduler set for 08:00 PT."
configured block "the override replaces the defaults, it does not extend them" "crontab,Scheduler" \
  "I will re-check the alarm — ScheduleWakeup set for 08:00 PT."
configured block "a name in neither list is not a mechanism" "crontab" \
  "I will re-check the alarm — Scheduler set for 08:00 PT."
configured pass "a task file named in the list is accepted" "crontab,TASKS.md" \
  "I'll pick up T20 — row added to TASKS.md."

echo "── a mechanism token must be a mechanism ──"
check block "five numbers in a row are not a cron expression" \
  "I'll re-run the percentiles in the morning.

15 27 65 93 247"
check block "a bare slash in prose is not a path" \
  "I'll re-run the and/or split in the morning."

echo "── GUARDS ──"
check pass "stop_hook_active blocks only once" \
  "I'll check the overnight window in the morning." true

if run_hook "/nonexistent/transcript.jsonl" >/dev/null; then
  pass=$((pass + 1)); echo "  ok   a missing transcript exits 0"
else
  fail=$((fail + 1)); echo "  FAIL a missing transcript did not exit 0"
fi

if printf 'not json' | python3 "$HOOK" >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "  ok   non-JSON stdin exits 0"
else
  fail=$((fail + 1)); echo "  FAIL non-JSON stdin did not exit 0"
fi

echo "── FLUSH — the final message may land after the hook starts ──"
late="$TMP/late.jsonl"
python3 -c '
import json, sys
open(sys.argv[1], "w").write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
' "$late"
( sleep 0.5; python3 -c '
import json, sys
with open(sys.argv[1], "a") as fh:
    fh.write(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "text", "text": "I will post the numbers in the morning."}]}}) + "\n")
' "$late" ) &
late_rc=0
run_hook "$late" >/dev/null || late_rc=$?
if [ "$late_rc" -eq 2 ]; then
  pass=$((pass + 1)); echo "  ok   a message flushed 0.5s late is still read (block)"
else
  fail=$((fail + 1)); echo "  FAIL a late-flushed message was missed"
fi
wait

echo "── the deny text names the phrase and the fix ──"
file="$TMP/msg.jsonl"
transcript "$file" "I'll check the overnight window in the morning."
run_hook "$file" >/dev/null
if grep -q "Commitment without a mechanism: 'I'll check the overnight window in the morning.'" "$TMP/err.txt" &&
   grep -q "Build one (cron, task, file, PR) or downgrade the language" "$TMP/err.txt" &&
   grep -q "an absolute path that exists on disk" "$TMP/err.txt"; then
  pass=$((pass + 1)); echo "  ok   quotes the phrase and names the fix"
else
  fail=$((fail + 1)); echo "  FAIL message was: $(cat "$TMP/err.txt")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
