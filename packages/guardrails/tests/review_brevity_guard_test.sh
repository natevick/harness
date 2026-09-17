#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/review_brevity_guard.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

FENCE="$(printf '\140\140\140')"
words() { python3 -c 'import sys; print(" ".join(["word"] * int(sys.argv[1])))' "$1"; }

record() {
  local name="$1" expect="$2" output="$3" verdict
  if printf '%s' "$output" | grep -q '"permissionDecision": "deny"'; then
    verdict="deny"
  else
    verdict="allow"
  fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-58s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$output"
  fi
}

check() {
  local expect="$1" name="$2" command="$3"
  record "$name" "$expect" "$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$command" | env GUARDRAILS_NOTIFY_COMMANDS=broker-run python3 "$HOOK" 2>/dev/null)"
}

check_mcp() {
  local expect="$1" name="$2" tool="$3" field="$4" text="$5"
  record "$name" "$expect" "$(python3 -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {sys.argv[2]: sys.argv[3]}}))
' "$tool" "$field" "$text" | python3 "$HOOK" 2>/dev/null)"
}

payload() { printf '%s' "$1" > "$TMP/payload.json"; }

words 201 > "$TMP/w201.md"
words 200 > "$TMP/w200.md"
words 401 > "$TMP/w401.md"
words 400 > "$TMP/w400.md"
words 151 > "$TMP/w151.md"

echo "── GITHUB REVIEWS — 200 body / 150 inline, and every comment names a fix ──"
payload "$(python3 -c '
import json
print(json.dumps({"body": " ".join(["word"] * 201), "event": "COMMENT", "comments": []}))
')"
check deny "a review body past 200" "gh api repos/o/r/pulls/7/reviews --input $TMP/payload.json"

payload "$(python3 -c '
import json
print(json.dumps({"body": "Short.", "comments": [
  {"path": "a.rb", "line": 4, "body": " ".join(["word"] * 151) + "\n\n**Fix:** Trim it."}]}))
')"
check deny "an inline comment past 150" "gh api repos/o/r/pulls/7/reviews --input $TMP/payload.json"

payload "$(python3 -c '
import json
print(json.dumps({"body": "Short.", "comments": [
  {"path": "a.rb", "line": 4, "body": "This reads oddly, but I am not asking for a change."}]}))
')"
check deny "an inline comment that names no fix" \
  "gh api repos/o/r/pulls/7/reviews --input $TMP/payload.json"

payload "$(python3 -c '
import json
print(json.dumps({"path": "a.rb", "line": 4, "body": "A thought with no ask."}))
')"
check deny "a single inline comment posted on its own" \
  "gh api repos/o/r/pulls/7/comments --input $TMP/payload.json"

check deny "gh pr review --body-file past 200" "gh pr review 7 --comment --body-file $TMP/w201.md"
check allow "gh pr review --body-file exactly at 200" \
  "gh pr review 7 --comment --body-file $TMP/w200.md"

payload "$(python3 -c '
import json
evidence = "```\n" + "\n".join(["2026-08-19 log line here"] * 300) + "\n```"
table = "| a | b |\n|---|---|\n" + "\n".join(["| 1 | 2 |"] * 200)
print(json.dumps({"body": "Two findings, both anchored.\n\n" + evidence + "\n\n" + table,
                  "comments": [{"path": "a.rb", "line": 4,
                                "body": "Off-by-one.\n\n```ruby\n" + "\n".join(["x = 1"] * 200) +
                                        "\n```\n\n**Fix:** Start at 0."}]}))
')"
check allow "evidence, fences and tables cost nothing" \
  "gh api repos/o/r/pulls/7/reviews --input $TMP/payload.json"

echo
echo "── THE SHAPES THAT USED TO PASS UNMEASURED ──"
BIG="$(words 800)"
check deny "a semicolon inside the body"      "gh pr create --title t --body '$BIG; more'"
check deny "a pipe inside the body"           "gh pr create --title t --body '$BIG | x'"
check deny "a double ampersand inside the body" "gh pr create --title t --body '$BIG && y'"
check deny "a markdown table inside the body" "gh pr create --title t --body '$BIG
| a | b |'"
check deny "an environment prefix before gh"  "GH_HOST=github.com gh pr create --title t --body '$BIG'"
check deny "a gated call after another command" "echo starting && gh pr comment 7 --body '$BIG'"
check deny "a gated call after a semicolon"   "git fetch origin; gh pr create --title t --body '$BIG'"
check deny "a gated call ending a pipeline"   "cat notes.md | gh pr comment 7 --body '$BIG'"
check allow "a short gated call after another command" \
  "echo starting && gh pr comment 7 --body 'Rebased onto main.'"
check deny "two environment prefixes"         "GH_HOST=x GH_TOKEN=y gh pr comment 7 --body '$BIG'"
check deny "a wrapper before a double dash"   "broker-run --profile p -- gh pr comment 7 --body '$BIG'"
check deny "a body-file heredoc on stdin"     "gh pr create --title t --body-file - <<'EOF'
$BIG
EOF"
words 800 > "$TMP/long.md"
words 40 > "$TMP/short.md"
check deny "a cat substitution in the body"   "gh pr comment 7 --body \"\$(cat $TMP/long.md)\""
check deny "gh api -f body="                  "gh api repos/o/r/pulls/7/reviews -f body='$BIG'"
check deny "a commit message with a semicolon" "git commit -m '$BIG; more'"
check allow "a short body with a semicolon"   "gh pr create --title t --body 'Rebased; CI green.'"
check allow "a short cat substitution"        "gh pr comment 7 --body \"\$(cat $TMP/short.md)\""
check deny "an unreadable cat substitution"   "gh pr comment 7 --body \"\$(cat $TMP/gone.md)\""
check allow "a wrapper before an unrelated command" "broker-run --profile p -- bin/rspec spec/a_spec.rb"
check deny "a gated call that is not first on the line" "echo starting && gh pr comment 7 --body '$BIG'"
check deny "a gated call after a semicolon"   "git status; gh pr create --title t --body '$BIG'"
check deny "a gated call after a pipe"        "cat notes | gh pr comment 7 --body '$BIG'"

echo
echo "── PR BODIES — 400 ──"
check deny  "gh pr create --body-file past 400"  "gh pr create --title t --body-file $TMP/w401.md"
check allow "gh pr create --body-file at 400"    "gh pr create --title t --body-file $TMP/w400.md"
check deny  "gh pr create -F past 400"           "gh pr create --title t -F $TMP/w401.md"
check deny  "gh pr edit --body past 400"         "gh pr edit 7 --body '$(words 401)'"
check allow "gh pr edit --body under 400"        "gh pr edit 7 --body 'Rebased onto main.'"
check allow "gh pr create with no body at all"   "gh pr create --title t --fill"

echo
echo "── PR AND ISSUE COMMENTS — 150 ──"
check deny  "gh pr comment past 150"    "gh pr comment 7 --body '$(words 151)'"
check allow "gh pr comment at 150"      "gh pr comment 7 --body '$(words 150)'"
check deny  "gh issue comment past 150" "gh issue comment 7 --body-file $TMP/w151.md"
check allow "gh issue comment, two lines" "gh issue comment 7 --body 'Fixed in abc1234. Reopening if it recurs.'"

echo
echo "── COMMIT MESSAGES — 200 ──"
check deny  "git commit -m past 200"          "git commit -m '$(words 201)'"
check allow "git commit -m at 200"            "git commit -m '$(words 200)'"
check deny  "two -m flags summing past 200"   "git commit -m 'fix: thing' -m '$(words 200)'"
check deny  "git commit -F past 200"          "git commit -F $TMP/w201.md"
check allow "a conventional commit subject"   "git commit -m 'fix(hooks): stop double-counting a reply'"
check allow "git commit with no message flag" "git commit --amend --no-edit"

echo
echo "── NOTIFICATIONS — 150 ──"
check deny  "broker-run --notify past 150" "broker-run --notify '$(words 151)'"
check allow "broker-run --notify at 150"   "broker-run --notify '$(words 150)'"
check allow "broker-run --notify reading STDIN" "broker-run --notify"
check allow "broker-run running a command"      "broker-run --profile oss --cred TOKEN -- gh pr list"

echo
echo "── CHAT MESSAGES — 150 ──"
check_mcp deny  "slack_send_message past 150" mcp__claude_ai_Slack__slack_send_message \
  message "$(words 151)"
check_mcp allow "slack_send_message at 150" mcp__claude_ai_Slack__slack_send_message \
  message "$(words 150)"
check_mcp deny  "slack_send_message_draft past 150" \
  mcp__claude_ai_Slack__slack_send_message_draft message "$(words 151)"
check_mcp allow "a chat message full of fenced evidence" \
  mcp__claude_ai_Slack__slack_send_message message \
  "$(printf 'Reader is saturated.\n%s\n%s\n%s\n' "$FENCE" "$(words 400)" "$FENCE")"

echo
echo "── TRACKER COMMENTS — 150 ──"
check_mcp deny  "save_comment past 150"           mcp__linear__save_comment body "$(words 151)"
check_mcp allow "save_comment at 150"             mcp__linear__save_comment body "$(words 150)"
check_mcp deny  "save_comment on a second server past 150" \
  mcp__linear-team__save_comment body "$(words 151)"
check_mcp deny  "save_issue description past 150" mcp__linear__save_issue description "$(words 151)"
check_mcp allow "save_issue with no description"  mcp__linear__save_issue state Todo

echo
echo "── IT STAYS OUT OF THE WAY ──"
check allow "a plain PR read"          "gh pr view 7 --json headRefOid"
check allow "a checks read"            "gh pr checks 362"
check allow "an unrelated api call"    "gh api repos/o/r/pulls/7/files --paginate"
check deny  "an unreadable payload is unmeasurable, not fine" \
  "gh api repos/o/r/pulls/7/reviews --input $TMP/nope.json"
check deny  "a payload that is not JSON is unmeasurable" \
  "gh api repos/o/r/pulls/7/reviews --input $HOOK"
check allow "git status"               "git status --short"
check allow "git push"                 "git push -u origin example/thing"
check allow "an unrelated command"     "bin/rspec spec/models/a_spec.rb"
check_mcp allow "an unrelated MCP tool" mcp__linear__list_issues query "everything"

echo
echo "── THE OVERRIDE IS HONOURED ──"
out="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "gh pr comment 7 --body '$(words 151)'" \
  | GUARDRAILS_ALLOW_LONG_REVIEW=1 python3 "$HOOK" 2>/dev/null)"
if [ -z "$out" ]; then
  pass=$((pass + 1))
  printf '  ok   %-58s (allow)\n' "GUARDRAILS_ALLOW_LONG_REVIEW=1 stands the guard down"
else
  fail=$((fail + 1))
  printf '  FAIL %-58s expected allow\n' "GUARDRAILS_ALLOW_LONG_REVIEW=1 stands the guard down"
fi

echo
echo "── THE BUDGETS ARE CONFIGURABLE ──"
out="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "gh pr comment 7 --body '$(words 40)'" \
  | GUARDRAILS_MESSAGE_WORDS=20 python3 "$HOOK" 2>/dev/null)"
if printf '%s' "$out" | grep -q 'budget 20'; then
  pass=$((pass + 1)); printf '  ok   %-58s (deny)\n' "GUARDRAILS_MESSAGE_WORDS lowers the bar"
else
  fail=$((fail + 1)); printf '  FAIL %-58s got: %s\n' "GUARDRAILS_MESSAGE_WORDS lowers the bar" "$out"
fi

echo
echo "── BROKEN INPUT — must never take the turn down ──"
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
survives "an unbalanced quote in the command" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"unterminated"}}'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
