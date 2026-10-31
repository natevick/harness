#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/done_means.py"
CURSOR="$ROOT/adapters/cursor"
SIGN="$ROOT/tests/review_sign.py"
TMP="$(mktemp -d)"
export GUARDRAILS_STATE_DIR="$TMP/state"
mkdir -p "$GUARDRAILS_STATE_DIR"
. "$ROOT/tests/fixture.sh"
begin_reviewer_fixture
install_trust "$REVIEWER_ID"
trap 'end_reviewer_fixture; rm -rf "$TMP"' EXIT
pass=0
fail=0

git_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
}

write_check() {
  python3 - "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import json, sys
path, done, run, sabotage, author = sys.argv[1:]
doc = {"task": "value", "done": done, "checks": [{"id": "unit", "run": run}]}
if sabotage == "false":
    doc["checks"][0]["sabotage"] = False
if sabotage == "true":
    doc["checks"][0]["sabotage"] = True
if author:
    doc["author"] = author
json.dump(doc, open(path, "w"))
PY
}

unsigned_review() {
  python3 - "$1" <<'PY'
import hashlib, json, os, sys
spec = sys.argv[1]
digest = hashlib.sha256(open(spec, "rb").read()).hexdigest()
json.dump({
    "gaps": [],
    "observable": True,
    "testable": True,
    "scoped": True,
    "stopping_point": True,
    "spec_sha256": digest,
}, open(os.path.splitext(spec)[0] + ".review.json", "w"))
PY
}

signed_review() {
  python3 "$SIGN" "$1" "$REVIEWER_ID" "$REVIEW_PRIV" pass
}

claims() {
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from guardrails.goals import claims_done; raise SystemExit(0 if claims_done(sys.argv[2]) else 1)' "$ROOT" "$1"
}

stop_claim() {
  local repo="$1" text="$2"
  shift 2
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"stop","status":"completed","session_id":"probe-stop","cwd":sys.argv[1],"text":sys.argv[2]}))' "$repo" "$text" | \
    env GUARDRAILS_STATE_DIR="$GUARDRAILS_STATE_DIR" "$@" \
    python3 "$CURSOR/done_means_guard.py" >"$TMP/out" 2>"$TMP/err"
}

followup() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("followup_message") else 1)' "$TMP/out"
}

fire_write() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":"Write","session_id":"probe-idle","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"{}\n"}}))' "$1" "$2" | \
    env GUARDRAILS_STATE_DIR="$GUARDRAILS_STATE_DIR" \
    python3 "$CURSOR/done_means_guard.py" >"$TMP/out" 2>"$TMP/err"
}

fire_shell() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"beforeShellExecution","session_id":"probe-shell","cwd":sys.argv[1],"command":sys.argv[2]}))' "$1" "$2" | \
    env GUARDRAILS_STATE_DIR="$GUARDRAILS_STATE_DIR" \
    python3 "$CURSOR/done_means_guard.py" >"$TMP/out" 2>"$TMP/err"
}

denied() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="deny" and sys.argv[2] in d.get("agent_message","") else 1)' "$TMP/out" "$1"
}

allowed() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("permission")=="allow" else 1)' "$TMP/out"
}

echo "── done-claim phrases ──"
if claims "The task is done."; then ok "The task is done is a done claim"
else bad "The task is done was not a claim"; fi
if claims "All done, the task is complete."; then ok "All done is a done claim"
else bad "All done was not a claim"; fi
if claims "Finished: everything works and is shipped."; then ok "Finished is a done claim"
else bad "Finished was not a claim"; fi
if claims "The spec is written."; then bad "a status sentence was treated as done"
else ok "a status sentence is not a done claim"; fi

echo "── probe C: phrasing and the off switch ──"
PHRASE="$TMP/phrase"
mkdir -p "$PHRASE"
write_check "$PHRASE/done-means.json" "test/check.sh exits 0" "false" "false"
unsigned_review "$PHRASE/done-means.json"
stop_claim "$PHRASE" "All done, the task is complete."
if followup; then ok "All done is blocked while the spec fails"
else bad "All done was allowed: $(cat "$TMP/out")"; fi
stop_claim "$PHRASE" "Finished: everything works and is shipped."
if followup; then ok "Finished is blocked while the spec fails"
else bad "Finished was allowed: $(cat "$TMP/out")"; fi
stop_claim "$PHRASE" "The task is done." GUARDRAILS_DONE_MEANS=off
if followup; then ok "GUARDRAILS_DONE_MEANS=off does not stand the gate down"
else bad "off stood the gate down: $(cat "$TMP/out")"; fi
stop_claim "$PHRASE" "The spec is written."
if [ ! -s "$TMP/out" ]; then ok "a stop that does not claim done is left alone"
else bad "quiet stop produced $(cat "$TMP/out")"; fi

echo "── protected paths, and the installer still writes hooks ──"
IDLE="$TMP/idle"
mkdir -p "$IDLE/src"
fire_write "$IDLE" "$IDLE/src/a.py"
if allowed; then ok "an ordinary idle write is still allowed"
else bad "ordinary write: $(cat "$TMP/out")"; fi
fire_write "$IDLE" "$IDLE/.cursor/hooks.json"
if denied "protected:"; then ok "writing .cursor/hooks.json is denied"
else bad "hooks.json write: $(cat "$TMP/out")"; fi
fire_write "$IDLE" "$IDLE/mcp.json"
if denied "protected:"; then ok "writing mcp.json is denied"
else bad "mcp.json write: $(cat "$TMP/out")"; fi
fire_write "$IDLE" "$IDLE/.mcp.json"
if denied "protected:"; then ok "writing .mcp.json is denied"
else bad ".mcp.json write: $(cat "$TMP/out")"; fi
HOME_SETTINGS="$(python3 -c 'import os,pwd; print(os.path.join(pwd.getpwuid(os.geteuid()).pw_dir, ".claude", "settings.json"))')"
fire_write "$IDLE" "$HOME_SETTINGS"
if denied "protected:"; then ok "writing ~/.claude/settings.json is denied"
else bad "settings.json write: $(cat "$TMP/out")"; fi
CODEX="$(python3 -c 'import os,pwd; print(os.path.join(pwd.getpwuid(os.geteuid()).pw_dir, ".codex", "hooks.json"))')"
fire_write "$IDLE" "$CODEX"
if denied "protected:"; then ok "writing ~/.codex/hooks.json is denied"
else bad "codex hooks write: $(cat "$TMP/out")"; fi
fire_write "$IDLE" "$TRUST"
if denied "protected:"; then ok "writing the reviewer trust store is denied"
else bad "trust store write: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "cp evil.json .cursor/hooks.json"
if denied "protected:"; then ok "cp onto .cursor/hooks.json is denied"
else bad "cp hooks: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "python3 -c 'open(\".cursor/hooks.json\",\"w\").write(\"{}\")'"
if denied "protected:"; then ok "python open of .cursor/hooks.json is denied"
else bad "python open: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "$ROOT/adapters/cursor/cloud-setup.sh $IDLE"
if allowed; then ok "cloud-setup.sh is not blocked by the protected-path gate"
else bad "cloud-setup command: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "$ROOT/install.sh --harness cursor --force --target $IDLE/.cursor/hooks.json"
if allowed; then ok "install.sh --harness is not blocked by the protected-path gate"
else bad "install command: $(cat "$TMP/out")"; fi
SETUP="$TMP/setup-repo"
rm -rf "$SETUP"
mkdir -p "$SETUP"
if "$ROOT/adapters/cursor/cloud-setup.sh" "$SETUP" >"$TMP/setup-out" 2>"$TMP/setup-err"; then
  ok "cloud-setup.sh exits 0"
else
  bad "cloud-setup.sh exited $? $(cat "$TMP/setup-err")"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raise SystemExit(0 if d.get("hooks") else 1)' "$SETUP/.cursor/hooks.json"; then
  ok "cloud-setup.sh writes .cursor/hooks.json"
else
  bad "hooks.json missing or empty: $(cat "$SETUP/.cursor/hooks.json" 2>/dev/null)"
fi

echo "── probe A and the non-vacuous sabotage rule ──"
PROBE_A="$TMP/probe-a"
git_repo "$PROBE_A"
mkdir -p "$PROBE_A/src"
printf '1\n' > "$PROBE_A/src/app.py"
git -C "$PROBE_A" add src/app.py
git -C "$PROBE_A" commit -qm base
printf '2\n' > "$PROBE_A/src/app.py"
write_check "$PROBE_A/done-means.json" "python3 -c print exits 0" "python3 -c 'print(1)'" ""
unsigned_review "$PROBE_A/done-means.json"
rc=0
cli run "$PROBE_A" || rc=$?
if [ "$rc" -eq 1 ]; then ok "probe A is blocked"
else bad "probe A exited $rc $(cat "$TMP/out")"; fi
shows "probe A names the missing reviewer" "review missing reviewer"
shows "probe A names the missing test diff" "no test diff"

GAP1="$TMP/gap1"
git_repo "$GAP1"
mkdir -p "$GAP1/src"
printf '1\n' > "$GAP1/src/app.py"
git -C "$GAP1" add src/app.py
git -C "$GAP1" commit -qm base
printf '2\n' > "$GAP1/src/app.py"
write_check "$GAP1/done-means.json" "python3 -c print exits 0" "python3 -c 'print(1)'" ""
signed_review "$GAP1/done-means.json"
rc=0
cli run "$GAP1" || rc=$?
if [ "$rc" -eq 1 ]; then ok "a signed review still blocks a non-doc change with no test"
else bad "gap1 exited $rc $(cat "$TMP/out")"; fi
shows "the block is the missing test diff" "sabotage: non-doc change has no test diff"

DOC="$TMP/doc"
git_repo "$DOC"
printf '1\n' > "$DOC/README.md"
git -C "$DOC" add README.md
git -C "$DOC" commit -qm base
printf '2\n' > "$DOC/README.md"
write_check "$DOC/done-means.json" "true exits 0" "true" ""
signed_review "$DOC/done-means.json"
rc=0
cli run "$DOC" || rc=$?
if [ "$rc" -eq 0 ]; then ok "a doc-only change does not need a test diff"
else bad "doc run rc=$rc $(cat "$TMP/out")"; fi

echo "── probe B: an import crash is not an assertion failure ──"
PROBE_B="$TMP/probe-b"
git_repo "$PROBE_B"
git -C "$PROBE_B" commit -q --allow-empty -m base
mkdir -p "$PROBE_B/test"
printf '%s\n' 'def answer():' '    return 1' > "$PROBE_B/answer.py"
printf '%s\n' \
  'import os' \
  'import sys' \
  'sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))' \
  'import answer' \
  'assert answer.answer() == answer.answer()' > "$PROBE_B/test/test_answer.py"
write_check "$PROBE_B/done-means.json" "test/test_answer.py exits 0" "python3 test/test_answer.py" "true"
signed_review "$PROBE_B/done-means.json"
rc=0
cli run "$PROBE_B" || rc=$?
if [ "$rc" -eq 1 ]; then ok "probe B is blocked"
else bad "probe B exited $rc $(cat "$TMP/out")"; fi
shows "probe B rejects the import crash" "crash or import"
if [ "$(cat "$PROBE_B/answer.py")" = "$(printf '%s\n' 'def answer():' '    return 1')" ]; then
  ok "probe B leaves the new module in place"
else
  bad "answer.py changed: $(cat "$PROBE_B/answer.py")"
fi

echo "── a landed hook file is protected; an untracked install is not ──"
LAND="$TMP/landed"
git_repo "$LAND"
mkdir -p "$LAND/.cursor"
printf '%s\n' '{"version":1,"hooks":{}}' > "$LAND/.cursor/hooks.json"
git -C "$LAND" add .cursor/hooks.json
git -C "$LAND" commit -qm base
printf '%s\n' '{"version":1,"hooks":{"stop":[]}}' > "$LAND/.cursor/hooks.json"
write_check "$LAND/done-means.json" "true exits 0" "true" "false"
signed_review "$LAND/done-means.json"
rc=0
cli run "$LAND" || rc=$?
if [ "$rc" -eq 1 ]; then ok "a tracked hooks.json edit is blocked"
else bad "landed hooks rc=$rc $(cat "$TMP/out")"; fi
shows "the landed hook file is named" "protected:"

UNTRACKED="$TMP/untracked"
git_repo "$UNTRACKED"
printf '1\n' > "$UNTRACKED/README.md"
git -C "$UNTRACKED" add README.md
git -C "$UNTRACKED" commit -qm base
mkdir -p "$UNTRACKED/.cursor"
printf '%s\n' '{"version":1,"hooks":{}}' > "$UNTRACKED/.cursor/hooks.json"
write_check "$UNTRACKED/done-means.json" "true exits 0" "true" "false"
signed_review "$UNTRACKED/done-means.json"
rc=0
cli run "$UNTRACKED" || rc=$?
if [ "$rc" -eq 0 ]; then ok "an untracked hooks.json from install does not fail run"
else bad "untracked hooks rc=$rc $(cat "$TMP/out")"; fi

echo "── the reviewer is a different identity, and an env path cannot replace the trust store ──"
SAME="$TMP/same"
mkdir -p "$SAME"
write_check "$SAME/done-means.json" "true exits 0" "true" "false" "$REVIEWER_ID"
signed_review "$SAME/done-means.json"
rc=0
cli validate "$SAME" || rc=$?
if [ "$rc" -eq 1 ]; then ok "a review signed by the spec author is blocked"
else bad "same author rc=$rc $(cat "$TMP/out")"; fi
shows "the author match is what fails" "reviewer matches the spec author"

EVIL="$TMP/evil-trust.json"
install_trust "other@example.com"
install_trust "$REVIEWER_ID" "$EVIL"
BYPASS="$TMP/bypass"
mkdir -p "$BYPASS"
write_check "$BYPASS/done-means.json" "true exits 0" "true" "false"
signed_review "$BYPASS/done-means.json"
rc=0
GUARDRAILS_REVIEWERS="$EVIL" cli run "$BYPASS" || rc=$?
if [ "$rc" -eq 1 ]; then ok "GUARDRAILS_REVIEWERS does not select the trust store"
else bad "reviewers override rc=$rc $(cat "$TMP/out")"; fi
shows "the real trust store rejected the reviewer" "not in the trust store"
install_trust "$REVIEWER_ID"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
