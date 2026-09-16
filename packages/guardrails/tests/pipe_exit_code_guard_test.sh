#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/pipe_exit_code_guard.py"
TMP_ERR="$(mktemp)"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_ERR" "$TMP_OUT"' EXIT
pass=0
fail=0

run() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$1" | python3 "$HOOK" 2>/dev/null
}

check() {
  local expect="$1" name="$2" cmd="$3"
  local out verdict
  out="$(run "$cmd")"

  if printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then
    verdict="deny"
  else
    verdict="allow"
  fi

  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1))
    printf '  ok   %-52s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1))
    printf '  FAIL %-52s expected %s, got %s\n' "$name" "$expect" "$verdict"
  fi
}

echo "MUST DENY — the 2026-08-05 false passes this guard exists for:"
check deny "shellcheck | head, then \$?"      'shellcheck foo.sh | head -15; echo exit=$?'
check deny "script | tail, then \$?"          './test-api.sh | tail -2; echo exit=$?'
check deny "grep | wc, then \$?"              'grep -r foo . | wc -l; rc=$?'
check deny "| cut"                            'cat f | cut -d, -f1; rc=$?'
check deny "spaced pipe"                      'cmd   |   head -5 ; echo $?'
check deny "second pipe is the filter"        'cat f | grep x | head -3; echo $?'

echo
echo "MUST ALLOW — reading \$? here is already correct or deliberate:"
check allow "PIPESTATUS is the right fix"     'cmd | head -20; rc=${PIPESTATUS[0]}'
check allow "set -o pipefail rescues it"      'set -o pipefail; cmd | head -20; rc=$?'
check allow "explicit pipe-exit-ok override"  'cmd | head -20; echo $?  # pipe-exit-ok'
check allow "no \$? at all"                   'shellcheck foo.sh | head -15'
check allow "no pipe at all"                  'shellcheck foo.sh; echo exit=$?'
check allow "last stage is not a filter"      'cmd | grep -q x; [ $? -eq 0 ] && echo yes'
check allow "\$? precedes the pipe"           'cmd; echo $?; other | head -3'
check allow "an empty command"                ''

echo
echo "EQUIVALENT SPELLINGS OF THE SAME READ — all deny:"
check deny "the braced form \${?}"           'cmd | head -3; echo ${?}'
check deny "a second \$? after a clean one"  'a; echo $?; b | head -3; echo $?'
check deny "an absolute path to the filter"  'cmd | /usr/bin/head -3; echo $?'
check deny "a newline after the pipe"        'cmd |
head -3; echo $?'
check deny "pipefail set after the read"     'cmd | head -3; echo $?; set -o pipefail'
check deny "the word PIPESTATUS as prose"    'echo PIPESTATUS; cmd | head -3; echo $?'
check deny "a command between the two"       'cmd | head -3; other_cmd; echo $?'
check deny "the read inside double quotes"   'cmd | head -5; echo "exit=$?"'

echo
echo "THE PATTERN AS DATA IS NOT A READ — writing a script must not be blocked:"
check allow "a quoted heredoc body"          "cat > run.sh <<'EOF'
cmd | head -5; echo \$?
EOF"
check allow "an unquoted heredoc body"       "cat > run.sh <<EOF
cmd | head -5; echo \$?
EOF"
check allow "an indented heredoc body"       "cat > run.sh <<~EOF
  cmd | head -5; echo \$?
  EOF"
check allow "a single-quoted echo"           "echo 'cmd | head -5; echo \$?'"
check allow "a single-quoted printf argument" "printf '%s\\n' 'x | tail -1; echo \$?' > t.sh"
check allow "a heredoc with no read at all"  "cat > run.sh <<'EOF'
cmd | head -5
EOF"

echo "THE DENIAL NAMES THE FILTER IT CAUGHT:"
out="$(run 'grep -r foo . | wc -l; rc=$?')"
if printf '%s' "$out" | grep -q 'reads \$? after piping into `wc`'; then
  pass=$((pass + 1)); printf '  ok   %-52s (wc)\n' "the last filter is quoted back"
else
  fail=$((fail + 1)); printf '  FAIL the denial does not name wc: %s\n' "$out"
fi
out="$(run 'cat f | grep x | head -3; echo $?')"
if printf '%s' "$out" | grep -q 'reads \$? after piping into `head`'; then
  pass=$((pass + 1)); printf '  ok   %-52s (head)\n' "the LAST filter wins, not the first"
else
  fail=$((fail + 1)); printf '  FAIL the denial does not name head: %s\n' "$out"
fi

echo
echo "A DENIAL IS NOT A CRASH — a hook that raises fails OPEN:"
rc=0
printf '{"tool_name":"Bash","tool_input":{"command":"grep -r foo . | wc -l; rc=$?"}}' \
  | python3 "$HOOK" >"$TMP_OUT" 2>"$TMP_ERR" || rc=$?
if [ "$rc" -eq 0 ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP_OUT"; then
  pass=$((pass + 1)); printf '  ok   %-52s (exit 0)\n' "the Claude shape exits 0 with parseable JSON"
else
  fail=$((fail + 1)); printf '  FAIL rc=%s stdout: %s\n' "$rc" "$(cat "$TMP_OUT")"
fi
if grep -q 'DENIED' "$TMP_ERR" && ! grep -q 'Traceback' "$TMP_ERR"; then
  pass=$((pass + 1)); printf '  ok   %-52s (stderr)\n' "stderr carries the reason, not a traceback"
else
  fail=$((fail + 1)); printf '  FAIL stderr was: %s\n' "$(cat "$TMP_ERR")"
fi

echo
echo "BROKEN INPUT — must never take the turn down:"
survives() {
  local name="$1" stdin="$2"
  if printf '%s' "$stdin" | python3 "$HOOK" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok   %-52s (exit 0)\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %-52s did not exit 0\n' "$name"
  fi
}
survives "non-JSON stdin" 'not json'
survives "an empty payload" '{}'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
