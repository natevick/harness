#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/done_means.py"
CURSOR="$ROOT/adapters/cursor"
HOOK="$ROOT/adapters/hookjson"
TMP="$(mktemp -d)"
export GUARDRAILS_STATE_DIR="$TMP/state"
mkdir -p "$GUARDRAILS_STATE_DIR"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

cli() {
  python3 "$CLI" "$@" >"$TMP/out" 2>"$TMP/err"
}

shows() {
  local name="$1" needle="$2"
  if grep -q "$needle" "$TMP/out"; then ok "$name"
  else bad "$name (missing $needle) $(cat "$TMP/out")"; fi
}

write_spec() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
path, done, run, flag, extra = sys.argv[1:]
doc = {"task": "value", "done": done, "checks": [{"id": "unit", "run": run}]}
if flag == "off":
    doc["checks"][0]["sabotage"] = False
if extra == "human":
    doc["human"] = ["a reader can explain the tradeoff"]
if extra == "none":
    doc["checks"] = []
if extra.startswith("mustnot:"):
    doc["paths"] = {"must_not_change": [extra.split(":", 1)[1]]}
if extra.startswith("must:"):
    doc["paths"] = {"must_change": [extra.split(":", 1)[1]]}
if extra == "vague-run":
    doc["checks"][0]["run"] = "loop until zero failing"
json.dump(doc, open(path, "w"))
PY
}

write_review() {
  python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
spec, verdict = sys.argv[1:]
ok = verdict == "pass"
digest = hashlib.sha256(open(spec, "rb").read()).hexdigest()
json.dump({
    "gaps": [] if ok else ["final state is not observable"],
    "observable": ok,
    "testable": ok,
    "scoped": ok,
    "stopping_point": ok,
    "spec_sha256": digest,
}, open(spec.replace(".json", ".review.json"), "w"))
PY
}

plant() {
  local repo="$1" body="$2"
  rm -rf "$repo"
  mkdir -p "$repo/src" "$repo/test"
  printf '1\n' > "$repo/src/value.txt"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  git -C "$repo" add src/value.txt
  git -C "$repo" commit -qm base
  printf '2\n' > "$repo/src/value.txt"
  printf '%s\n' "$body" > "$repo/test/check.sh"
}

cursor_fire() {
  printf '%s' "$2" | env GUARDRAILS_STATE_DIR="$GUARDRAILS_STATE_DIR" \
    python3 "$CURSOR/$1" >"$TMP/out" 2>"$TMP/err"
}

cursor_write() {
  cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"Write","session_id":"clear","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[1]+"/src/a.py","content":"x = 1\n"}}))' "$1")"
}

expect() {
  python3 -c "$2" "$TMP/out" && ok "$1" || bad "$1: $(cat "$TMP/out") err=$(cat "$TMP/err")"
}

echo "── a vague prompt warns or passes; it does not block the submit ──"
cursor_fire unbounded_goal_challenge.py "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"beforeSubmitPrompt","session_id":"vague","prompt":"Make the parser robust"}))')"
if [ ! -s "$TMP/out" ]; then ok "a subjective prompt is not blocked"
else bad "subjective prompt produced $(cat "$TMP/out")"; fi

cursor_fire unbounded_goal_challenge.py "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"beforeSubmitPrompt","session_id":"none","prompt":"Fix the bug"}))')"
if [ ! -s "$TMP/out" ]; then ok "a prompt with no measurable token is not blocked"
else bad "end state prompt produced $(cat "$TMP/out")"; fi

printf '%s' "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"loop","prompt":"Loop until zero failing"}))')" | \
  python3 "$HOOK/unbounded_goal_challenge.py" >"$TMP/out" 2>"$TMP/err"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
blob=json.dumps(d)
sys.exit(0 if d.get("decision")!="block" and "UNBOUNDED-WORK" in blob and "additionalContext" in blob else 1)
' "$TMP/out" && ok "until zero failing warns and does not block" || bad "hookjson warn: $(cat "$TMP/out")"

cursor_fire unbounded_goal_challenge.py "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"beforeSubmitPrompt","session_id":"clear","prompt":"Add src/tax.js so test/tax.test.js exits 0."}))')"
if [ ! -s "$TMP/out" ]; then ok "a concrete goal is not blocked"
else bad "concrete goal produced $(cat "$TMP/out")"; fi

echo "── edits wait for a valid spec and a passing review ──"
REPO="$TMP/work"
mkdir -p "$REPO"
cursor_write "$REPO"
expect "a task write with no spec is denied" '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "no done-means spec" in d.get("agent_message","") else 1)
'

cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"beforeShellExecution","session_id":"clear","cwd":sys.argv[1],"command":"cat > "+sys.argv[1]+"/src/b.py <<EOF\nx = 1\nEOF"}))' "$REPO")"
expect "a shell heredoc is denied with the spec missing" 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="deny" else 1)'

write_spec "$REPO/done-means.json" "make it robust" "true" "" ""
write_review "$REPO/done-means.json" pass
cursor_write "$REPO"
expect "a vague done sentence blocks the edit" '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "done is vague" in d.get("agent_message","") else 1)
'

write_spec "$REPO/done-means.json" "test/tax.test.js exits 0" "true" "" "human"
write_review "$REPO/done-means.json" fail
cursor_write "$REPO"
expect "a failing review blocks the edit" '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "review failed" in d.get("agent_message","") else 1)
'

write_review "$REPO/done-means.json" pass
python3 -c 'import sys; open(sys.argv[1],"a").write("\n")' "$REPO/done-means.json"
cursor_write "$REPO"
expect "a stale review blocks the edit" '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "spec_sha256" in d.get("agent_message","") else 1)
'

write_spec "$REPO/done-means.json" "test/tax.test.js exits 0" "true" "" "human"
write_review "$REPO/done-means.json" pass
cursor_write "$REPO"
expect "a clear spec and a passing review allow the edit" 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="allow" else 1)'

cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"beforeShellExecution","session_id":"clear","cwd":sys.argv[1],"command":"cat > "+sys.argv[1]+"/done-means.json <<EOF\n{}\nEOF"}))' "$REPO")"
expect "a shell heredoc of the spec file is allowed" 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="allow" else 1)'

echo "── the validator rejects vague specs and runs real checks ──"
rc=0
cli validate "$ROOT/templates/done-means.json" || rc=$?
if [ "$rc" -eq 1 ]; then ok "the template does not validate as a finished spec"
else bad "template validate exited $rc"; fi
shows "placeholder is rejected" "placeholder"

PLAIN="$TMP/plain"
mkdir -p "$PLAIN"
write_spec "$PLAIN/done-means.json" "test/tax.test.js exits 0" "true" "" "none"
cli validate "$PLAIN" || true
shows "human-only spec has no runnable check" "no runnable check"

write_spec "$PLAIN/done-means.json" "make it robust" "true" "" ""
cli validate "$PLAIN" || true
shows "subjective done is vague" "no observable end state"

write_spec "$PLAIN/done-means.json" "test/tax.test.js exits 0" "true" "" "vague-run"
cli validate "$PLAIN" || true
shows "an until-zero command is vague" "run is vague"

write_spec "$PLAIN/done-means.json" "test/tax.test.js exits 0" "false" "off" "human"
write_review "$PLAIN/done-means.json" pass
rc=0
cli run "$PLAIN" || rc=$?
if [ "$rc" -eq 1 ]; then ok "a failing check blocks run"
else bad "failing check exited $rc $(cat "$TMP/out")"; fi
shows "the failure names the exit" "exited"

write_spec "$PLAIN/done-means.json" "make clean exits 0" "make clean" "" ""
write_review "$PLAIN/done-means.json" pass
rc=0
cli validate "$PLAIN" || rc=$?
if [ "$rc" -eq 0 ]; then ok "make clean is a command, not a vague sentence"
else bad "make clean rc=$rc $(cat "$TMP/out")"; fi

write_spec "$PLAIN/done-means.json" "test/tax.test.js exits 0" "true" "" "human"
write_review "$PLAIN/done-means.json" pass
rc=0
cli run "$PLAIN" || rc=$?
if [ "$rc" -eq 0 ]; then ok "a passing check lets run through"
else bad "passing check rc=$rc $(cat "$TMP/out")"; fi
shows "human criteria are marked unenforced" "UNENFORCED"
if [ ! -f "$PLAIN/done-means.receipt.jsonl" ]; then ok "run does not write a receipt"
else bad "receipt was written"; fi

python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["task"]="ship the REPLACE widget"; json.dump(d, open(p,"w"))' "$PLAIN/done-means.json"
cli validate "$PLAIN" || true
shows "REPLACE inside a task is the placeholder" "placeholder"

echo "── done is blocked when a check fails ──"
write_spec "$PLAIN/done-means.json" "test/tax.test.js exits 0" "false" "off" ""
write_review "$PLAIN/done-means.json" pass
cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"stop","status":"completed","session_id":"stop","cwd":sys.argv[1],"text":"This is done."}))' "$PLAIN")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "exited" in d.get("followup_message","") else 1)
' "$TMP/out" && ok "stop followup blocks a done claim while a check fails" || bad "stop: $(cat "$TMP/out") err=$(cat "$TMP/err")"

cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"stop","status":"completed","session_id":"stop","cwd":sys.argv[1],"text":"The spec is written."}))' "$PLAIN")"
if [ ! -s "$TMP/out" ]; then ok "a stop that does not claim done is left alone"
else bad "quiet stop produced $(cat "$TMP/out")"; fi

echo "── run reverts the non-test diff itself ──"
LIVE="$TMP/live"
plant "$LIVE" "grep -qx 2 src/value.txt"
write_spec "$LIVE/done-means.json" "test/check.sh exits 0 when src/value.txt is 2" "bash test/check.sh" "" ""
write_review "$LIVE/done-means.json" pass
rc=0
cli validate "$LIVE" || rc=$?
[ "$rc" -eq 0 ] && ok "validate does not revert" || bad "validate rc=$rc $(cat "$TMP/out")"
rc=0
cli sabotage "$LIVE" || rc=$?
[ "$rc" -eq 2 ] && ok "sabotage is not a subcommand" || bad "sabotage rc=$rc $(cat "$TMP/out")"
rc=0
cli run "$LIVE" || rc=$?
[ "$rc" -eq 0 ] && ok "a red revert and a green restore let run pass" || bad "live run rc=$rc $(cat "$TMP/out")"
if [ "$(cat "$LIVE/src/value.txt")" = "2" ]; then ok "run leaves the fix in place"
else bad "value.txt is $(cat "$LIVE/src/value.txt")"; fi
if [ ! -f "$LIVE/done-means.sabotage.json" ] && [ ! -f "$LIVE/done-means.receipt.jsonl" ]; then
  ok "run writes neither an evidence file nor a receipt"
else bad "extra artifact was written"; fi

WEAK="$TMP/weak"
plant "$WEAK" "exit 0"
write_spec "$WEAK/done-means.json" "test/check.sh exits 0 when src/value.txt is 2" "bash test/check.sh" "" ""
write_review "$WEAK/done-means.json" pass
rc=0
cli run "$WEAK" || rc=$?
[ "$rc" -eq 1 ] && ok "a revert that still passes blocks done" || bad "weak rc=$rc $(cat "$TMP/out")"
shows "the live revert is what fails" "still passed after reverting"
if [ "$(cat "$WEAK/src/value.txt")" = "2" ]; then ok "a failed revert leaves the fix in place"
else bad "weak value.txt is $(cat "$WEAK/src/value.txt")"; fi

GREEN="$TMP/green"
plant "$GREEN" "if grep -qx 1 src/value.txt; then printf 'exit 1\n' > test/check.sh; exit 1; fi
exit 0"
write_spec "$GREEN/done-means.json" "test/check.sh exits 0 when src/value.txt is 2" "bash test/check.sh" "" ""
write_review "$GREEN/done-means.json" pass
rc=0
cli run "$GREEN" || rc=$?
[ "$rc" -eq 1 ] && ok "a red run that rewrites the test fails the restore" || bad "green rc=$rc $(cat "$TMP/out")"
shows "restore is checked" "failed after restore"
if grep -q "grep -qx 1" "$GREEN/test/check.sh"; then ok "the rewrite stays in the copy"
else bad "live test script was rewritten: $(cat "$GREEN/test/check.sh")"; fi

PATHS="$TMP/paths"
mkdir -p "$PATHS/src"
git -C "$PATHS" init -q
git -C "$PATHS" config user.email t@example.com
git -C "$PATHS" config user.name t
printf '1\n' > "$PATHS/src/a.txt"
git -C "$PATHS" add src/a.txt
git -C "$PATHS" commit -qm base
printf '2\n' > "$PATHS/src/a.txt"
write_spec "$PATHS/done-means.json" "src/a.txt contains 2" "true" "off" "must:src/a.txt"
write_review "$PATHS/done-means.json" pass
rc=0
cli run "$PATHS" || rc=$?
[ "$rc" -eq 0 ] && ok "must_change passes when the path changed" || bad "must rc=$rc $(cat "$TMP/out")"
write_spec "$PATHS/done-means.json" "src/a.txt contains 2" "true" "off" "must:src/missing.txt"
write_review "$PATHS/done-means.json" pass
rc=0
cli run "$PATHS" || rc=$?
[ "$rc" -eq 1 ] && ok "a missing must_change blocks run" || bad "missing path rc=$rc $(cat "$TMP/out")"
shows "the missing path is named" "did not change"
write_spec "$PATHS/done-means.json" "src/a.txt contains 2" "true" "off" "mustnot:src/a.txt"
write_review "$PATHS/done-means.json" pass
rc=0
cli run "$PATHS" || rc=$?
[ "$rc" -eq 1 ] && ok "must_not_change blocks a touched path" || bad "mustnot rc=$rc $(cat "$TMP/out")"
shows "the touched path is named" "changed"

echo "── an idle session is not a done claim ──"
IDLE="$TMP/idle"
mkdir -p "$IDLE"
cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"stop","status":"completed","session_id":"idle-cursor","cwd":sys.argv[1],"text":"Done."}))' "$IDLE")"
if [ ! -s "$TMP/out" ]; then ok "cursor stop ignores Done when no task or spec was opened"
else bad "idle cursor stop produced $(cat "$TMP/out")"; fi

rc=0
printf '%s' "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","session_id":"idle-hook","cwd":sys.argv[1],"last_assistant_message":"Ready for review."}))' "$IDLE")" | \
  python3 "$HOOK/done_means_guard.py" >"$TMP/out" 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ]; then ok "hookjson stop ignores Ready for review when no task or spec was opened"
else bad "idle hookjson stop rc=$rc out=$(cat "$TMP/out") err=$(cat "$TMP/err")"; fi

cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"stop","status":"completed","session_id":"clear","cwd":sys.argv[1],"text":"Done."}))' "$IDLE")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "no done-means spec" in d.get("followup_message","") else 1)
' "$TMP/out" && ok "a noted task still engages stop with no spec" || bad "task stop: $(cat "$TMP/out")"

echo "── the revert runs off the live tree ──"
SIDE="$TMP/side"
LIVE="$TMP/live2"
rm -f "$SIDE"
plant "$LIVE" "printf 'seen=%s live=%s cwd=%s\n' \"\$(cat src/value.txt)\" \"\$(cat $LIVE/src/value.txt)\" \"\$(pwd)\" >> $SIDE
grep -qx 2 src/value.txt"
write_spec "$LIVE/done-means.json" "test/check.sh exits 0 when src/value.txt is 2" "bash test/check.sh" "" ""
write_review "$LIVE/done-means.json" pass
python3 - "$LIVE" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
repo = sys.argv[1]
product = ["src/value.txt"]
digest = hashlib.sha256()
for rel in product:
    digest.update(rel.encode())
    digest.update(b"\0")
    full = os.path.join(repo, rel)
    if os.path.isfile(full):
        digest.update(Path(full).read_bytes())
    digest.update(b"\0")
json.dump({
    "method": "revert-nontest-diff",
    "base": "HEAD",
    "reverted": product,
    "fix_sha256": digest.hexdigest(),
    "checks": [{
        "id": "unit",
        "run": "bash test/check.sh",
        "red": {"exit": 1, "output": "red"},
        "green": {"exit": 0, "output": "green"},
    }],
}, open(os.path.join(repo, "done-means.sabotage.json"), "w"))
PY
rc=0
cli run "$LIVE" || rc=$?
python3 - "$SIDE" "$LIVE" <<'PY'
import os, sys
side, live = sys.argv[1:]
lines = open(side).read().splitlines() if os.path.isfile(side) else []
reds = []
for line in lines:
    parts = dict(item.split("=", 1) for item in line.split())
    if parts.get("seen") == "1":
        reds.append(parts)
if not reds:
    sys.exit(2)
live = os.path.abspath(live)
sys.exit(0 if all(row.get("live") == "2" and os.path.abspath(row.get("cwd", "")) != live for row in reds) else 1)
PY
saw=$?
if [ "$saw" -eq 0 ]; then ok "a red run leaves the live file in place"
else bad "live revert saw=$saw side=$(cat "$SIDE" 2>/dev/null) value=$(cat "$LIVE/src/value.txt") rc=$rc out=$(cat "$TMP/out")"; fi

echo "── a kill during the red run leaves the live tree ──"
HOLD="$TMP/hold"
MARK="$TMP/hold-mark"
rm -f "$MARK"
plant "$HOLD" "if grep -qx 1 src/value.txt; then touch '$MARK'; sleep 60; exit 1; fi
exit 0"
write_spec "$HOLD/done-means.json" "test/check.sh exits 0 when src/value.txt is 2" "bash test/check.sh" "" ""
write_review "$HOLD/done-means.json" pass
python3 - "$HOLD" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
repo = sys.argv[1]
product = ["src/value.txt"]
digest = hashlib.sha256()
for rel in product:
    digest.update(rel.encode())
    digest.update(b"\0")
    full = os.path.join(repo, rel)
    if os.path.isfile(full):
        digest.update(Path(full).read_bytes())
    digest.update(b"\0")
json.dump({
    "method": "revert-nontest-diff",
    "base": "HEAD",
    "reverted": product,
    "fix_sha256": digest.hexdigest(),
    "checks": [{
        "id": "unit",
        "run": "bash test/check.sh",
        "red": {"exit": 1, "output": "red"},
        "green": {"exit": 0, "output": "green"},
    }],
}, open(os.path.join(repo, "done-means.sabotage.json"), "w"))
PY
setsid python3 "$CLI" run "$HOLD" >"$TMP/hold-out" 2>"$TMP/hold-err" </dev/null &
hold_pid=$!
arrived=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 20 25 30; do
  if [ -f "$MARK" ]; then arrived=1; break; fi
  sleep 0.2
done
kill -9 -"$hold_pid" 2>/dev/null || kill -9 "$hold_pid" 2>/dev/null || true
wait "$hold_pid" 2>/dev/null || true
if [ "$arrived" -eq 1 ] && [ "$(cat "$HOLD/src/value.txt")" = "2" ]; then
  ok "killing the red run leaves the live tree"
else
  bad "kill safety arrived=$arrived value=$(cat "$HOLD/src/value.txt" 2>/dev/null) out=$(cat "$TMP/hold-out" 2>/dev/null) err=$(cat "$TMP/hold-err" 2>/dev/null)"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
