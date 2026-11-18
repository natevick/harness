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
echo "NAME OR USER SELECTION DENIES — the 2026-11-18 incident and its relatives:"
check deny "the incident, verbatim"                     "pkill -u norm sleep"
check deny "a bare pattern"                             "pkill sleep"
check deny "a pattern, formerly allowed"                "pkill mysqld"
check deny "an absolute path"                           "/usr/bin/pkill -u norm sleep"
check deny "a numeric signal"                           "pkill -9 sleep"
check deny "a named signal"                             "pkill -KILL sleep"
check deny "a SIG-prefixed signal"                      "pkill -SIGTERM sleep"
check deny "the long signal form"                       "pkill --signal 9 sleep"
check deny "the long signal form with ="                "pkill --signal=KILL sleep"
check deny "user selector alone"                        "pkill -u norm"
check deny "real-uid selector"                          "pkill -U 1000"
check deny "long euid"                                  "pkill --euid norm sleep"
check deny "long uid with ="                            "pkill --uid=1000"
check deny "real-group selector"                        "pkill -G users"
check deny "combined short flags with a value"          "pkill -fu norm sleep"
check deny "combined flags, user selector, exact"       "pkill -xu norm sleep"
check deny "terminal selector"                          "pkill -t pts/1"
check deny "exact name"                                 "pkill -x sleep"
check deny "newest by name"                             "pkill -n sleep"
check deny "oldest by name"                             "pkill -o sleep"
check deny "a pgroup selector plus a pattern"           "pkill -g 123 sleep"
check deny "a pgroup selector plus a user"              "pkill -g 123 -u norm"
check deny "a non-numeric pgroup"                       "pkill -g abc"
check deny "a pgroup flag with no value"                "pkill --pgroup"
check deny "no selector at all"                         "pkill"
check deny "only a signal"                              "pkill -9"
check deny "pattern after --"                           "pkill -g 123 -- sleep"
check deny "pattern after a line continuation"         "pkill -u norm \\
  sleep"
check deny "pattern hidden behind a redirection"        "pkill sleep >/dev/null 2>&1 || true"
check deny "killall by name"                            "killall sleep"
check deny "killall by user"                            "killall -u norm sleep"
check deny "killall with a signal, absolute path"       "/usr/bin/killall -9 node"
check deny "killall by group flag"                      "killall -g 123"

echo
echo "KILL FED BY A NAME LOOKUP DENIES:"
check deny "kill of a pgrep substitution"               'kill $(pgrep sleep)'
check deny "kill -9 of a pgrep -u substitution"         'kill -9 $(pgrep -u norm sleep)'
check deny "kill of backticks"                          'kill `pgrep sleep`'
check deny "kill of a quoted substitution"              'kill "$(pgrep sleep)"'
check deny "kill of pidof"                              'kill $(pidof sleep)'
check deny "absolute kill"                              '/bin/kill $(pgrep sleep)'
check deny "lookup behind sudo inside the substitution" 'kill $(sudo pgrep sleep)'
check deny "lookup piped inside the substitution"       'kill $(pgrep sleep | head -1)'
check deny "pgrep piped to xargs kill"                  'pgrep sleep | xargs kill'
check deny "pgrep -u piped to xargs -r kill -9"         'pgrep -u norm sleep | xargs -r kill -9'
check deny "lookup, filter, then xargs kill"            'pgrep sleep | head -1 | xargs kill'
check deny "xargs with a value-taking option"           'pgrep sleep | xargs -I {} kill {}'
check deny "stderr merged before the pipe"              'pgrep sleep 2>&1 | xargs kill'
check deny "pidof piped to xargs kill"                  'pidof sleep | xargs kill'

echo
echo "WRAPPERS AND SEPARATORS DO NOT HIDE IT:"
check deny "sudo"                                       "sudo pkill -u norm sleep"
check deny "sudo with a user option"                    "sudo -u norm pkill sleep"
check deny "env with an assignment"                     "env FOO=1 pkill sleep"
check deny "timeout with seconds"                       "timeout 5 pkill sleep"
check deny "timeout with a unit suffix"                 "timeout 5s pkill sleep"
check deny "timeout with a signal option"               "timeout -s KILL 5 pkill sleep"
check deny "nohup"                                      "nohup pkill sleep"
check deny "setsid"                                     "setsid pkill sleep"
check deny "xargs feeding pkill"                        "echo sleep | xargs pkill"
check deny "stacked wrappers"                           "timeout 900 sudo setsid nohup pkill sleep"
check deny "docker exec"                                "docker exec ctr pkill sleep"
check deny "docker exec with options and a user"        "docker exec -it -u root ctr pkill sleep"
check deny "docker exec into a shell"                   "docker exec ctr sh -c 'pkill sleep'"
check deny "sh -c"                                      "sh -c 'pkill -u norm sleep'"
check deny "bash -c double quoted"                      'bash -c "pkill sleep"'
check deny "bash -lc"                                   "bash -lc 'pkill sleep'"
check deny "bash -o pipefail -c"                        "bash -o pipefail -c 'pkill sleep'"
check deny "sh -c around a kill lookup"                 "sh -c 'kill \$(pgrep sleep)'"
check deny "sh -c with a double-quoted lookup"          'bash -c "kill $(pgrep sleep)"'
check deny "sh -c pkill -g fed by a lookup"             'sh -c "pkill -g $(pgrep sleep)"'
check deny "eval with a double-quoted lookup"           'eval "kill $(pgrep sleep)"'
check deny "a real pkill after a commit heredoc"        "git commit -m \"\$(cat <<'EOF'
x
EOF
)\"; pkill sleep"
check deny "after a semicolon"                          "true; pkill sleep"
check deny "after a logical and"                        "true && pkill sleep"
check deny "after a logical or"                         "false || pkill sleep"
check deny "after a pipe"                               "echo x | pkill sleep"
check deny "on a later line"                            "echo hi
pkill sleep"
check deny "in a subshell"                              "(pkill sleep)"
check deny "in a brace group"                           "{ pkill sleep; }"
check deny "after then"                                 "if true; then pkill sleep; fi"
check deny "negated"                                    "! pkill sleep"
check deny "in a loop body"                             'for p in a b; do pkill "$p"; done'
check deny "inside a substitution"                      'echo $(pkill sleep)'
check deny "inside a quoted substitution"               'echo "$(pkill sleep)"'
check deny "after a broker-run segment"                 'broker-run --sudo --reason x -- true; pkill sleep'

echo
echo "THE BROKERED ROUTE PASSES:"
check silent "the denial's own recommended command"     'timeout 900 broker-run --sudo --reason "stuck sleep from lane 3" -- /usr/bin/pkill -u norm sleep'
check silent "broker-run --sudo without timeout"        'broker-run --sudo --reason x -- /usr/bin/pkill -u norm foo'
check silent "broker-run --sudo around a kill lookup"   'broker-run --sudo --reason x -- /bin/kill $(pgrep -u norm foo)'
check silent "broker-run without --sudo is not ours"    'broker-run --reason x -- ls /tmp'

echo
echo "SCOPED KILLS PASS:"
check silent "pkill -g with a pgid"                     "pkill -g 123"
check silent "pkill -g with a signal"                   "pkill -TERM -g 123"
check silent "pkill -g with a list"                     "pkill -9 -g 123,456"
check silent "pkill --pgroup"                           "pkill --pgroup 123"
check silent "pkill --pgroup="                          "pkill --pgroup=123"
check silent "pkill -P parent"                          "pkill -P 123"
check silent "pkill -s session"                         "pkill -s 123"
check silent "pkill -g attached value"                  "pkill -g123"
check silent "pkill -g from a variable"                 'pkill -g "$PGID"'
check silent "pkill -g from a pidfile"                  'pkill -g "$(cat /run/x.pgid)"'
check silent "pkill -P of the shell itself"             'pkill -P $$'
check silent "pkill -g across a line continuation"      "pkill -g 123 \\
  -P 4"
check silent "pkill -g with redirections"               "pkill -g 123 >/dev/null 2>&1 || true"
check silent "pkill -g with a long signal"              "pkill --signal 9 -g 123"
check silent "pkill -g with echo"                       "pkill -e -g 123"
check silent "pkill -g behind sudo -u"                  "sudo -u norm pkill -g 123"
check silent "pkill -g in a container"                  "docker exec ctr pkill -g 123"
check silent "pkill -g inside sh -c"                    "sh -c 'pkill -g 123'"
check silent "kill by pid"                              "kill 123"
check silent "kill -9 by pid"                           "kill -9 123"
check silent "kill a process group"                     "kill -- -123"
check silent "kill -TERM a process group"               "kill -TERM -- -123"
check silent "kill from a pidfile"                      'kill $(cat /var/run/watch.pid)'
check silent "sh -c with a pidfile substitution"        'bash -c "kill $(cat /run/x.pid)"'
check silent "kill a variable"                          'kill $pid'
check silent "pgrep then an unrelated kill"             "pgrep sleep; kill 123"
check silent "pgrep counted, not killed"                "pgrep sleep | wc -l"
check silent "ps"                                       "ps -eo pid,etime,cmd"

echo
echo "TEXT THAT ONLY MENTIONS THE WORDS STAYS SILENT:"
check silent "grep for pkill"                           "grep -n pkill file"
check silent "echo with pkill -u"                       'echo "pkill -u"'
check silent "single-quoted killall"                    "echo 'killall sleep'"
check silent "a commit message"                         'git commit -m "stop using pkill -u norm sleep and killall"'
check silent "a PR body"                                'gh pr create --body "pkill -u norm sleep killed sleep infinity"'
check silent "a quoted heredoc body"                    "cat > /tmp/x.sh <<'EOF'
pkill -u norm sleep
killall node
EOF"
check silent "an unquoted heredoc body"                 "cat > /tmp/x.sh <<EOF
kill \$(pgrep sleep)
EOF"
check silent "a commit message heredoc naming pkill"    "git commit -m \"\$(cat <<'EOF'
pkill -u norm sleep killed the devcontainer
EOF
)\""
check silent "a PR body heredoc naming killall"         "gh pr create --body \"\$(cat <<'EOF'
killall node
EOF
)\""
check silent "kill mentioned in a quoted lookup"        'echo "do not kill $(pgrep sleep)"'
check silent "man page"                                 "man pkill"
check silent "command -v"                               "command -v pkill"
check silent "which"                                    "which killall"
check silent "a full-line comment"                      "echo hi
# pkill -u norm sleep"
check silent "a trailing comment"                       "echo hi # pkill sleep"
check silent "reading the guard source"                 "cat guardrails/pkill.py"

echo
echo "THE NAME DENIAL CARRIES THE ROUTE AND STAYS SHORT:"
name_text="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from guardrails import pkill
print(pkill.check_command("pkill -u norm sleep").reason)
' "$(cd "$(dirname "$HOOK")/../.." && pwd)")"
expect_in_text() {
  local name="$1" needle="$2"
  if printf '%s' "$name_text" | grep -qF -- "$needle"; then
    pass=$((pass + 1)); printf '  ok   the denial contains %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL the denial lacks %s (%s)\n' "$name" "$needle"
  fi
}
expect_in_text "the incident date"       "2026-11-18"
expect_in_text "the pgid route"          'kill -- -<pgid>'
expect_in_text "the pkill -g route"      'pkill -g <pgid>'
expect_in_text "the broker route"        'timeout 900 broker-run --sudo --reason "<why>" -- /usr/bin/pkill -u norm <pattern>'
expect_in_text "the container advice"    "container"
if [ -z "$name_text" ] || printf '%s' "$name_text" | grep -q 'GUARDRAILS_ALLOW'; then
  fail=$((fail + 1)); echo "  FAIL the name denial is empty or offers an env override"
else
  pass=$((pass + 1)); echo "  ok   the name denial offers no env override"
fi
lines="$(printf '%s\n' "$name_text" | wc -l | tr -d ' ')"
if [ -n "$name_text" ] && [ "$lines" -ge 1 ] && [ "$lines" -le 12 ]; then
  pass=$((pass + 1)); printf '  ok   the denial is %s lines (max 12)\n' "$lines"
else
  fail=$((fail + 1)); printf '  FAIL the denial is %s lines (max 12)\n' "$lines"
fi
out="$(run "pkill -f \"mix test\"")"
if printf '%s' "$out" | grep -q 'broker-run' && ! printf '%s' "$out" | grep -q 'GUARDRAILS_ALLOW_PKILL_F'; then
  pass=$((pass + 1)); echo "  ok   pkill -f with a pattern shows the name text, not the -f override"
else
  fail=$((fail + 1)); printf '  FAIL pkill -f with a pattern showed the wrong text: %s\n' "$out"
fi
out="$(run "pkill -f -g 123")"
if printf '%s' "$out" | grep -q 'matches the shell running it'; then
  pass=$((pass + 1)); echo "  ok   pkill -f with no name selected shows the self-match text"
else
  fail=$((fail + 1)); printf '  FAIL pkill -f -g text lost: %s\n' "$out"
fi
out="$(run "pkill -u norm sleep")"
if printf '%s' "$out" | grep -q 'broker-run'; then
  pass=$((pass + 1)); echo "  ok   the hook output for the incident command names the broker route"
else
  fail=$((fail + 1)); printf '  FAIL the hook output lacks the route: %s\n' "$out"
fi

echo
echo "PGREP WARNS BUT NEVER BLOCKS — a count of 0 or 1 is not evidence:"
check warn "pgrep -f" "pgrep -f watch-both.sh"
check warn "pgrep --full" "pgrep --full watch-both.sh"
check silent "pgrep without -f" "pgrep watchd"
check silent "pgrep -f quoted inside a string" "echo 'run pgrep -f watch'"

echo
echo "THE TEXTS CARRY THE FIX:"
out="$(run "pkill -f -g 123")"
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
echo "THE -f OVERRIDE ONLY STANDS DOWN THE SELF-MATCH RULE, NEVER THE NAME GATE:"
run_with() {
  local override="$1" cmd="$2"
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$cmd" | GUARDRAILS_ALLOW_PKILL_F="$override" python3 "$HOOK" 2>/dev/null
}
out="$(run_with 1 "pkill -f -g 123")"
if [ -z "$out" ]; then
  pass=$((pass + 1)); echo "  ok   GUARDRAILS_ALLOW_PKILL_F=1 stands down -f when no name is selected"
else
  fail=$((fail + 1)); printf '  FAIL the override was ignored: %s\n' "$out"
fi
out="$(run_with 1 "pkill -f watch-both.sh")"
if [ "$(verdict_of "$out")" = "deny" ] && ! printf '%s' "$out" | grep -q 'GUARDRAILS_ALLOW_PKILL_F'; then
  pass=$((pass + 1)); echo "  ok   with the override set, a name still denies and offers no override"
else
  fail=$((fail + 1)); printf '  FAIL override leaked past the name gate: %s\n' "$out"
fi
out="$(run_with 1 "pkill -u norm sleep")"
if [ "$(verdict_of "$out")" = "deny" ]; then
  pass=$((pass + 1)); echo "  ok   the incident command denies even with the override set"
else
  fail=$((fail + 1)); printf '  FAIL the incident command passed under the override: %s\n' "$out"
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
