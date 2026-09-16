#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/pkill_self_match_guard.py"
pass=0
fail=0

run() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$1" | python3 "$HOOK" 2>/dev/null
}

run_list() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": json.loads(sys.argv[1])}}))
' "$1" | python3 "$HOOK" 2>/dev/null
}

verdict_of() {
  local out="$1"
  if printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then
    printf 'deny'
  elif printf '%s' "$out" | grep -q '"additionalContext"'; then
    printf 'warn'
  else
    printf 'silent'
  fi
}

check() {
  local expect="$1" name="$2" cmd="$3" out verdict
  out="$(run "$cmd")"
  verdict="$(verdict_of "$out")"
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-56s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-56s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$out"
  fi
}

check_list() {
  local expect="$1" name="$2" argv_json="$3" out verdict
  out="$(run_list "$argv_json")"
  verdict="$(verdict_of "$out")"
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-56s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-56s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$out"
  fi
}

echo "MUST DENY — the 2026-08-11 self-kill (exit 144) this guard exists for:"
check deny "the original: pkill -f on a script name" "pkill -f 'watch-both.sh'"
check deny "an absolute path to pkill" "/usr/bin/pkill -f watch-both.sh"
check deny "the long flag" "pkill --full watch-both.sh"
check deny "bundled flags ending in f" "pkill -af watch-both.sh"
check deny "after a semicolon" "ls /tmp; pkill -f watch-both.sh"
check deny "inside a command substitution" "echo \$(pkill -f watch-both.sh)"
check deny "after a logical and" "test -f pid && pkill -f watch-both.sh"
check deny "before a heredoc" "pkill -f watch.sh; cat <<'EOF'
plain text
EOF"

echo
echo "FLAG ORDER, CLUSTERING AND QUOTING DO NOT CHANGE THE ANSWER:"
check deny "a signal before -f"              "pkill -9 -f watch-both.sh"
check deny "a named signal before -f"        "pkill -TERM -f watch-both.sh"
check deny "another flag with a value"       "pkill -u me -f watch-both.sh"
check deny "the long signal form"            "pkill --signal 9 -f watch-both.sh"
check deny "a double-quoted flag"            'pkill "-f" watch-both.sh'
check deny "a single-quoted flag"            "pkill '-f' watch-both.sh"
check deny "behind sudo"                     "sudo pkill -f watch-both.sh"
check deny "behind env"                      "env pkill -9 -f watch-both.sh"

echo
echo "NOTHING BEFORE A pkill CAN DROP IT FROM THE SCAN:"
check deny "after an arithmetic shift"       "echo \$((1<<3)); pkill -f watch-both.sh"
check deny "after an escaped apostrophe"     "echo don\\'t; pkill -f watch-both.sh"
check deny "after a quoted heredoc marker"   'echo "<<EOF"; pkill -f watch-both.sh'
check deny "after a heredoc that closed"     "cat <<EOF > /tmp/x
hello
EOF
pkill -f watch-both.sh"
check deny "after a here-string"             'cat <<<"$y"; pkill -f watch-both.sh'
check deny "after an unterminated quote"     "echo 'oops; pkill -f watch-both.sh"

echo "MUST STAY SILENT — the pattern is data, not a command position:"
check silent "the words inside a double-quoted string" "echo \"do not pkill -f foo\""
check silent "the words inside a single-quoted string" "echo 'never pkill -f foo'"
check silent "a heredoc body that mentions it" "python3 - <<'PY'
subprocess.run(['pkill', '-f', 'watch.sh'])
PY"
check silent "writing a script whose first word is pkill" "cat > /tmp/stop.sh <<'EOF'
pkill -f watch.sh
EOF"
check silent "an unquoted heredoc writing the same script" "cat > /tmp/stop.sh <<EOF
pkill -f watch.sh
EOF"
check silent "pkill without -f" "pkill mysqld"
check silent "the recommended read-only form" "/bin/ps -eo pid,etime,cmd | grep -E '[w]atch'"
check silent "kill by recorded pid" "kill \$(cat /var/run/watch.pid)"
check silent "an empty command" ""
check silent "gh --body string mentioning pkill -f" 'gh pr create --body "mentions pkill -f in the body"'

echo
echo "ISSUE #3 — argv --body is one token, not a new command:"
check_list silent "argv --body with newlines and pkill -f" '["gh","pr","create","--body","line1\npkill -f watch\n(quoted text)"]'
check_list silent "argv --body mentioning pkill -f" '["gh","pr","create","--body","mentions pkill -f"]'
check_list deny "argv real pkill -f" '["pkill","-f","watch-both.sh"]'
check_list deny "argv pkill --full" '["/usr/bin/pkill","--full","watch-both.sh"]'

echo
echo "PGREP WARNS BUT NEVER BLOCKS — a count of 0 or 1 is not evidence:"
check warn "pgrep -f" "pgrep -f watch-both.sh"
check warn "pgrep --full" "pgrep --full watch-both.sh"
check silent "pgrep without -f" "pgrep watchd"
check silent "pgrep -f quoted inside a string" "echo 'run pgrep -f watch'"

echo
echo "THE TEXTS CARRY THE FIX:"
out="$(run "pkill -f watch-both.sh")"
if printf '%s' "$out" | grep -q 'GUARDRAILS_ALLOW_PKILL_F=1'; then
  pass=$((pass + 1)); echo "  ok   the denial names its override"
else
  fail=$((fail + 1)); printf '  FAIL the denial does not name the override: %s\n' "$out"
fi
if printf '%s' "$out" | grep -q '"hookEventName": "PreToolUse"'; then
  pass=$((pass + 1)); echo "  ok   the denial is a PreToolUse decision"
else
  fail=$((fail + 1)); printf '  FAIL wrong event shape: %s\n' "$out"
fi
out="$(run "pgrep -f watch-both.sh")"
if printf '%s' "$out" | grep -q 'is not evidence'; then
  pass=$((pass + 1)); echo "  ok   the warning says why a low count proves nothing"
else
  fail=$((fail + 1)); printf '  FAIL the warning text is wrong: %s\n' "$out"
fi

echo
echo "THE OVERRIDE IS HONOURED:"
out="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "pkill -f watch-both.sh" | GUARDRAILS_ALLOW_PKILL_F=1 python3 "$HOOK" 2>/dev/null)"
if [ -z "$out" ]; then
  pass=$((pass + 1)); echo "  ok   GUARDRAILS_ALLOW_PKILL_F=1 stands the guard down"
else
  fail=$((fail + 1)); printf '  FAIL the override was ignored: %s\n' "$out"
fi

echo
echo "BROKEN INPUT — must never take the turn down:"
survives() {
  local name="$1" stdin="$2"
  if printf '%s' "$stdin" | python3 "$HOOK" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok   %-56s (exit 0)\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %-56s did not exit 0\n' "$name"
  fi
}
survives "non-JSON stdin" 'not json'
survives "an empty payload" '{}'
survives "an unbalanced quote" \
  '{"tool_name":"Bash","tool_input":{"command":"pkill -f \"unterminated"}}'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
