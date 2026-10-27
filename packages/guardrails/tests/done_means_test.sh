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
if flag == "fail":
    doc["checks"][0]["fail_first"] = True
if flag == "off":
    doc["checks"][0]["sabotage"] = False
if extra == "human":
    doc["human"] = ["a reader can explain the tradeoff"]
if extra == "none":
    doc["checks"] = []
if extra.startswith("ci:"):
    doc["ci"] = [extra[3:]]
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
    "verdict": verdict,
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

echo "── vague goals are blocked and a concrete one is not ──"
cursor_fire unbounded_goal_challenge.py "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"beforeSubmitPrompt","session_id":"vague","prompt":"Make the parser robust"}))')"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("continue") is False and "only subjective completion words" in d.get("user_message","") else 1)
' "$TMP/out" && ok "subjective goal blocks the submit" || bad "subjective goal: $(cat "$TMP/out")"

cursor_fire unbounded_goal_challenge.py "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"beforeSubmitPrompt","session_id":"none","prompt":"Fix the bug"}))')"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("continue") is False and "no observable end state" in d.get("user_message","") else 1)
' "$TMP/out" && ok "no observable end state blocks the submit" || bad "end state: $(cat "$TMP/out")"

printf '%s' "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"loop","prompt":"Loop until zero failing"}))')" | \
  python3 "$HOOK/unbounded_goal_challenge.py" >"$TMP/out" 2>"$TMP/err"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("decision")=="block" and "UNBOUNDED-WORK" in d.get("reason","") else 1)
' "$TMP/out" && ok "until zero failing is a prompt block" || bad "hookjson block: $(cat "$TMP/out")"

cursor_fire unbounded_goal_challenge.py "$(python3 -c 'import json; print(json.dumps({"hook_event_name":"beforeSubmitPrompt","session_id":"clear","prompt":"Add src/tax.js so test/tax.test.js exits 0."}))')"
if [ ! -s "$TMP/out" ]; then ok "a concrete goal is not blocked"
else bad "concrete goal produced $(cat "$TMP/out")"; fi

echo "── edits wait for a valid spec and a passing review ──"
REPO="$TMP/work"
mkdir -p "$REPO"
cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"Write","session_id":"clear","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[1]+"/src/a.py","content":"x = 1\n"}}))' "$REPO")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "no done-means spec" in d.get("agent_message","") else 1)
' "$TMP/out" && ok "a task write with no spec is denied" || bad "missing spec: $(cat "$TMP/out")"

cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"beforeShellExecution","session_id":"clear","cwd":sys.argv[1],"command":"cat > "+sys.argv[1]+"/src/b.py <<EOF\nx = 1\nEOF"}))' "$REPO")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="deny" else 1)' "$TMP/out" \
  && ok "a shell heredoc is denied with the spec missing" || bad "heredoc deny: $(cat "$TMP/out") err=$(cat "$TMP/err")"

write_spec "$REPO/done-means.json" "make it robust" "true" "" ""
write_review "$REPO/done-means.json" pass
cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"Write","session_id":"clear","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[1]+"/src/a.py","content":"x = 1\n"}}))' "$REPO")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "done is vague" in d.get("agent_message","") else 1)
' "$TMP/out" && ok "a vague done sentence blocks the edit" || bad "vague spec: $(cat "$TMP/out")"

write_spec "$REPO/done-means.json" "test/tax.test.js exits 0" "true" "" "human"
write_review "$REPO/done-means.json" fail
cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"Write","session_id":"clear","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[1]+"/src/a.py","content":"x = 1\n"}}))' "$REPO")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "review failed" in d.get("agent_message","") else 1)
' "$TMP/out" && ok "a failing review blocks the edit" || bad "review fail: $(cat "$TMP/out")"

write_review "$REPO/done-means.json" pass
python3 -c 'open(sys.argv[1],"a").write("\n")' "$REPO/done-means.json"
cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"Write","session_id":"clear","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[1]+"/src/a.py","content":"x = 1\n"}}))' "$REPO")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("permission")=="deny" and "spec_sha256" in d.get("agent_message","") else 1)
' "$TMP/out" && ok "a stale review blocks the edit" || bad "stale review: $(cat "$TMP/out")"

write_spec "$REPO/done-means.json" "test/tax.test.js exits 0" "true" "" "human"
write_review "$REPO/done-means.json" pass
cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"Write","session_id":"clear","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[1]+"/src/a.py","content":"x = 1\n"}}))' "$REPO")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="allow" else 1)' "$TMP/out" \
  && ok "a clear spec and a passing review allow the edit" || bad "allow: $(cat "$TMP/out")"

cursor_fire done_means_guard.py "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"beforeShellExecution","session_id":"clear","cwd":sys.argv[1],"command":"cat > "+sys.argv[1]+"/done-means.json <<EOF\n{}\nEOF"}))' "$REPO")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="allow" else 1)' "$TMP/out" \
  && ok "a shell heredoc of the spec file is allowed" || bad "spec heredoc: $(cat "$TMP/out") err=$(cat "$TMP/err")"

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
shows "subjective done is vague" "only subjective completion words"

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

printf 'exit 1\n' > "$PLAIN/probe.sh"
write_spec "$PLAIN/done-means.json" "probe.sh exits 0" "bash probe.sh" "fail" "human"
write_review "$PLAIN/done-means.json" pass
rc=0
cli run "$PLAIN" || rc=$?
[ "$rc" -eq 1 ] && ok "fail_first records the red run and still fails" || bad "first fail_first rc=$rc $(cat "$TMP/out")"
printf 'exit 0\n' > "$PLAIN/probe.sh"
rc=0
cli run "$PLAIN" || rc=$?
if [ "$rc" -eq 0 ]; then ok "fail_first passes after a recorded red run"
else bad "second fail_first rc=$rc $(cat "$TMP/out")"; fi
shows "human criteria are marked unenforced" "UNENFORCED"

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

echo "── sabotage evidence is required and a fake record does not pass ──"
LIVE="$TMP/live"
plant "$LIVE" "grep -qx 2 src/value.txt"
write_spec "$LIVE/done-means.json" "test/check.sh exits 0 when src/value.txt is 2" "bash test/check.sh" "" ""
write_review "$LIVE/done-means.json" pass
rc=0
cli validate "$LIVE" || rc=$?
[ "$rc" -eq 0 ] && ok "validate does not demand sabotage before done" || bad "validate rc=$rc $(cat "$TMP/out")"
rc=0
cli run "$LIVE" || rc=$?
[ "$rc" -eq 1 ] && ok "missing sabotage evidence blocks done" || bad "missing sabotage rc=$rc"
shows "missing evidence names the helper" "no sabotage evidence"

rc=0
cli sabotage "$LIVE" || rc=$?
[ "$rc" -eq 0 ] && ok "the helper records a real red then green" || bad "sabotage rc=$rc $(cat "$TMP/out")"
if [ "$(cat "$LIVE/src/value.txt")" = "2" ]; then ok "sabotage restores the fix"
else bad "value.txt is $(cat "$LIVE/src/value.txt")"; fi
rc=0
cli run "$LIVE" || rc=$?
[ "$rc" -eq 0 ] && ok "a live sabotage record lets run pass" || bad "live run rc=$rc $(cat "$TMP/out")"

python3 - "$LIVE/done-means.sabotage.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["fix_sha256"] = "deadbeef"
json.dump(doc, open(path, "w"))
PY
rc=0
cli run "$LIVE" || rc=$?
[ "$rc" -eq 1 ] && ok "a stale fix hash blocks done" || bad "stale hash rc=$rc"
shows "hash mismatch is named" "fix_sha256"

cli sabotage "$LIVE" >/dev/null
python3 - "$LIVE/done-means.sabotage.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["checks"][0]["red"]["exit"] = 0
json.dump(doc, open(path, "w"))
PY
rc=0
cli run "$LIVE" || rc=$?
[ "$rc" -eq 1 ] && ok "a red exit of 0 blocks done" || bad "red zero rc=$rc"
shows "zero red is rejected" "no failing red run"

WEAK="$TMP/weak"
plant "$WEAK" "exit 0"
write_spec "$WEAK/done-means.json" "test/check.sh exits 0 when src/value.txt is 2" "bash test/check.sh" "" ""
write_review "$WEAK/done-means.json" pass
python3 - "$ROOT" "$WEAK" <<'PY'
import json, os, sys
root, repo = sys.argv[1:]
sys.path.insert(0, root)
from guardrails.done import fix_sha
product = ["src/value.txt"]
json.dump({
    "method": "revert-nontest-diff",
    "base": "HEAD",
    "reverted": product,
    "fix_sha256": fix_sha(repo, product),
    "checks": [{
        "id": "unit",
        "run": "bash test/check.sh",
        "red": {"exit": 1, "output": "pretend failure"},
        "green": {"exit": 0, "output": "ok"},
    }],
}, open(os.path.join(repo, "done-means.sabotage.json"), "w"))
PY
rc=0
cli run "$WEAK" || rc=$?
[ "$rc" -eq 1 ] && ok "fake red evidence blocks done when the revert still passes" || bad "fake rc=$rc $(cat "$TMP/out")"
shows "the live revert is what fails the fake" "now exits 0"
if [ "$(cat "$WEAK/src/value.txt")" = "2" ]; then ok "a rejected sabotage still restores the tree"
else bad "weak value.txt is $(cat "$WEAK/src/value.txt")"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
