#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/truncated_output_guard.py"
pass=0
fail=0

lines() { python3 -c 'import sys; print("\n".join("match %d" % i for i in range(int(sys.argv[1]))))' "$1"; }

run() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]},
                  "tool_response": {"stdout": sys.argv[2]}}))
' "$1" "$2" | python3 "$HOOK" 2>/dev/null
}

check() {
  local expect="$1" name="$2" cmd="$3" stdout="$4" out verdict
  out="$(run "$cmd" "$stdout")"
  if printf '%s' "$out" | grep -q '"additionalContext"'; then verdict="warn"; else verdict="silent"; fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-56s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-56s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$out"
  fi
}

echo "MUST WARN — output that landed exactly on its own cap:"
check warn "head -20 returning 20 lines" "grep -rn foo /srv/app | head -20" "$(lines 20)"
check warn "head -n 20 returning 20 lines" "grep -rn foo /srv/app | head -n 20" "$(lines 20)"
check warn "more lines than the cap" "grep -rn foo /srv/app | head -20" "$(lines 21)"
check warn "tail -5 returning 5 lines" "tail -5 /var/log/app.log" "$(lines 5)"
check warn "tail -n 5 returning 5 lines" "tail -n 5 /var/log/app.log" "$(lines 5)"
check warn "grep -m 3 returning 3 lines" "grep -m 3 foo /srv/app/big.txt" "$(lines 3)"
check warn "a SQL LIMIT returning that many rows" \
  "psql -Atc 'select id from users LIMIT 10'" "$(lines 10)"
check warn "the tightest cap in the command is the one that binds" \
  "grep -m 50 foo big.txt | head -4" "$(lines 4)"
check warn "blank lines do not pad the count" \
  "grep -rn foo /srv/app | head -3" "$(printf 'a\n\n\nb\n\nc')"

echo
echo "MUST STAY SILENT — nothing was cut off, or the count is meaningless:"
check silent "fewer lines than the cap" "grep -rn foo /srv/app | head -20" "$(lines 5)"
check silent "no cap in the command" "grep -rn foo /srv/app" "$(lines 400)"
check silent "a cap of zero" "head -0 /var/log/app.log" "$(lines 3)"
check silent "empty output" "grep -rn foo /srv/app | head -20" ""
check silent "a heredoc: the cap is source code, not a pipeline" \
  "python3 - <<'PY'
print(open('f').read()[:20])
PY" "$(lines 20)"
check silent "a heredoc body that contains a real cap" \
  "cat > /tmp/probe.sh <<'EOF'
grep -rn foo /srv | head -3
EOF" "$(lines 3)"
check silent "a compound command inflates the count" \
  "wc -l f; grep -rn foo . | head -20" "$(lines 20)"
check silent "an echo inflates the count" \
  "echo starting && grep -m1 foo f" "$(lines 1)"
check silent "a printf inflates the count" \
  "printf 'go\n'; grep -m1 foo f" "$(lines 1)"
check silent "no command at all" "" "$(lines 20)"

echo
echo "THE WARNING CARRIES THE NUMBERS:"
out="$(run "grep -rn foo /srv/app | head -20" "$(lines 20)")"
if printf '%s' "$out" | grep -q 'capped output at 20 and returned 20 non-empty'; then
  pass=$((pass + 1)); echo "  ok   it names the cap and the count"
else
  fail=$((fail + 1)); printf '  FAIL the message is wrong: %s\n' "$out"
fi
if printf '%s' "$out" | grep -q '"hookEventName": "PostToolUse"'; then
  pass=$((pass + 1)); echo "  ok   it is a PostToolUse context injection"
else
  fail=$((fail + 1)); printf '  FAIL wrong event shape: %s\n' "$out"
fi
if printf '%s' "$out" | grep -q 'permissionDecision'; then
  fail=$((fail + 1)); echo "  FAIL it must never block a completed command"
else
  pass=$((pass + 1)); echo "  ok   it never blocks — the command already ran"
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
survives "a response with no stdout key" \
  '{"tool_name":"Bash","tool_input":{"command":"head -5 f"},"tool_response":{}}'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
