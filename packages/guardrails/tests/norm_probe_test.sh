#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SPEC_BASE_DIR="$ROOT/tests"
CLI="$ROOT/done_means.py"
CURSOR="$ROOT/adapters/cursor"
SIGN="$ROOT/tests/review_sign.py"
TMP="$(mktemp -d)"
export GUARDRAILS_STATE_DIR="$TMP/state"
mkdir -p "$GUARDRAILS_STATE_DIR"
. "$ROOT/tests/fixture.sh"
begin_reviewer_fixture
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
import json, os, sys
sys.path.insert(0, os.environ["SPEC_BASE_DIR"])
path, done, run, sabotage, author = sys.argv[1:]
from spec_base import ensure_base
doc = {"task": "value", "done": done, "checks": [{"id": "unit", "run": run}]}
doc["base"] = ensure_base(os.path.dirname(path) or ".")
if sabotage == "false":
    doc["checks"][0]["sabotage"] = False
    doc["checks"][0]["reason"] = "the check does not depend on the local diff"
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
if followup; then ok "a non-question stop is denied while the spec fails"
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
fire_write "$IDLE" "/etc/harness/reviewers.json"
if denied "protected:"; then ok "writing /etc/harness/reviewers.json is denied"
else bad "trust store write: $(cat "$TMP/out")"; fi
HARNESS_DONE="$(python3 -c 'import os,pwd; print(os.path.join(pwd.getpwuid(os.geteuid()).pw_dir, ".harness", "src", "packages", "guardrails", "guardrails", "done.py"))')"
fire_write "$IDLE" "$HARNESS_DONE"
if denied "protected:"; then ok "writing ~/.harness/src guard code is denied"
else bad "harness src write: $(cat "$TMP/out")"; fi
fire_write "$IDLE" "$IDLE/.cursor/environment.json"
if denied "protected:"; then ok "writing .cursor/environment.json is denied"
else bad "environment.json write: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "cp evil.json .cursor/hooks.json"
if denied "protected:"; then ok "cp onto .cursor/hooks.json is denied"
else bad "cp hooks: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "python3 -c 'open(\".cursor/hooks.json\",\"w\").write(\"{}\")'"
if denied "protected:"; then ok "python open of .cursor/hooks.json is denied"
else bad "python open: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "cp /tmp/t.json ${HOME}/.harness/reviewers.json # cloud-setup.sh"
if denied "protected:"; then ok "a cloud-setup.sh comment does not exempt a copy"
else bad "comment spoof: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "echo cloud-setup.sh && cp /tmp/t.json ${HOME}/.harness/reviewers.json"
if denied "protected:"; then ok "echo cloud-setup.sh does not exempt a copy"
else bad "echo spoof: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "cp x .claude/settings.json && true install.sh --harness"
if denied "protected:"; then ok "install.sh --harness later in the command does not exempt a copy"
else bad "install.sh spoof: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "install -m 644 /tmp/t.json /etc/harness/reviewers.json"
if denied "protected:"; then ok "install onto the trust store is denied"
else bad "install trust: $(cat "$TMP/out")"; fi
fire_shell "$IDLE" "echo x#; cp evil.json .cursor/hooks.json"
if denied "protected:"; then ok "a glued hash does not comment out the copy"
else bad "glued hash: $(cat "$TMP/out")"; fi
LINK="$TMP/hh"
rm -rf "$LINK"
ln -s "$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.geteuid()).pw_dir)')" "$LINK"
fire_write "$IDLE" "$LINK/.harness/src/packages/guardrails/guardrails/done.py"
if denied "protected:"; then ok "a write through a home symlink is denied"
else bad "symlink write: $(cat "$TMP/out")"; fi
SETUP="$TMP/setup-repo"
rm -rf "$SETUP"
mkdir -p "$SETUP"
setup_rc=0
"$ROOT/adapters/cursor/cloud-setup.sh" "$SETUP" >"$TMP/setup-out" 2>"$TMP/setup-err" || setup_rc=$?
if ps -eo args= | grep -q '[e]xec-daemon/index.js serve'; then
  if [ "$setup_rc" -eq 1 ] && grep -q "hooks will not load until the daemon restarts" "$TMP/setup-err" && [ ! -f "$SETUP/.cursor/hooks.json" ]; then
    ok "cloud-setup exits 1 and does not write hooks.json while the daemon is running"
  else
    bad "daemon cloud-setup rc=$setup_rc err=$(cat "$TMP/setup-err") file=$(ls "$SETUP/.cursor/hooks.json" 2>/dev/null)"
  fi
else
  ok "this environment has no exec daemon to race"
fi
WITH="$TMP/with-hooks"
rm -rf "$WITH"
mkdir -p "$WITH/.cursor"
"$ROOT/install.sh" --harness cursor --portable --force --target "$WITH/.cursor/hooks.json" >/dev/null
with_rc=0
HARNESS_ROOT="$(cd "$ROOT/../.." && pwd)" "$ROOT/adapters/cursor/cloud-setup.sh" "$WITH" >"$TMP/with-out" 2>"$TMP/with-err" || with_rc=$?
if [ -f /etc/harness/reviewers.json ]; then
  if [ "$with_rc" -eq 0 ]; then ok "cloud-setup self-test passes when the trust store is not writable"
  else bad "self-test rc=$with_rc $(cat "$TMP/with-err")"; fi
  if grep -q "Local hooks are advisory" "$ROOT/adapters/cursor/cloud-setup.sh" \
    && ! grep -q 'raise SystemExit("harness install is writable by this user' "$ROOT/adapters/cursor/cloud-setup.sh"; then
    ok "a writable install root does not fail cloud-setup"
  else bad "cloud-setup still treats a writable install root as fatal"; fi
else
  if [ "$with_rc" -ne 0 ] && grep -q "trust store" "$TMP/with-err"; then
    ok "cloud-setup self-test fails closed without a root trust store"
  else
    bad "missing trust store rc=$with_rc $(cat "$TMP/with-err")"
  fi
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
shows "probe B's tautology still passes under a stub" "still passed"
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

echo "── B1: the signature covers the whole review ──"
FLIP="$TMP/flip"
mkdir -p "$FLIP"
write_check "$FLIP/done-means.json" "true exits 0" "true" "false"
python3 "$SIGN" "$FLIP/done-means.json" "$REVIEWER_ID" "$REVIEW_PRIV" fail
python3 - "$FLIP/done-means.review.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["gaps"] = []
data["observable"] = True
data["testable"] = True
data["scoped"] = True
data["stopping_point"] = True
json.dump(data, open(path, "w"))
PY
rc=0
cli run "$FLIP" || rc=$?
if [ "$rc" -eq 1 ]; then ok "flipping a signed rejection does not make it pass"
else bad "flip rc=$rc $(cat "$TMP/out")"; fi
shows "the flipped review signature is rejected" "review signature is not valid"

echo "── B2: a trust store the agent can write is rejected ──"
python3 - "$ROOT" "$FLIP" "$TRUST" <<'PY'
import os, sys
root, repo, trust = sys.argv[1:]
sys.path.insert(0, root)
from guardrails.done import configure, finish_problems, release_trust
configure(trust=trust, enforce_ownership=True, require_live=False)
problems, _data = finish_problems(repo)
release_trust()
text = "\n".join(problems or [])
sys.exit(0 if "trust store is writable by this user" in text else 1)
PY
if [ "$?" -eq 0 ]; then ok "a user-writable trust store is rejected"
else bad "writable trust store was accepted"; fi

echo "── the reviewer key is not taken from GUARDRAILS_REVIEWERS ──"
EVIL="$TMP/evil-trust.json"
python3 "$SIGN" --trust "$TRUST" "$TMP/reviewer.pub" "other@example.com"
python3 "$SIGN" --trust "$EVIL" "$TMP/reviewer.pub" "$REVIEWER_ID"
BYPASS="$TMP/bypass"
mkdir -p "$BYPASS"
write_check "$BYPASS/done-means.json" "true exits 0" "true" "false"
signed_review "$BYPASS/done-means.json"
rc=0
GUARDRAILS_REVIEWERS="$EVIL" cli run "$BYPASS" || rc=$?
if [ "$rc" -eq 1 ]; then ok "GUARDRAILS_REVIEWERS does not select the trust store"
else bad "reviewers override rc=$rc $(cat "$TMP/out")"; fi
shows "the real trust store rejected the reviewer" "not in the trust store"
python3 "$SIGN" --trust "$TRUST" "$TMP/reviewer.pub" "$REVIEWER_ID"

echo "── B6: AttributeError from a reverted symbol is not a red ──"
BPRIME="$TMP/bprime"
git_repo "$BPRIME"
mkdir -p "$BPRIME/pkg" "$BPRIME/test"
printf '%s\n' 'def other():' '    return 0' > "$BPRIME/pkg/mod.py"
printf '' > "$BPRIME/pkg/__init__.py"
git -C "$BPRIME" add pkg
git -C "$BPRIME" commit -qm base
printf '%s\n' 'def other():' '    return 0' 'def answer():' '    return 1' > "$BPRIME/pkg/mod.py"
python3 -c 'import pytest' >/dev/null 2>&1 || python3 -m pip install -q pytest
printf '%s\n' \
  'import sys' \
  'from pathlib import Path' \
  'sys.path.insert(0, str(Path(__file__).resolve().parents[1]))' \
  'import pkg.mod as mod' \
  'def test_answer():' \
  '    assert mod.answer() == mod.answer()' > "$BPRIME/test/test_answer.py"
write_check "$BPRIME/done-means.json" "pytest test_answer exits 0" "python3 -m pytest -q test/test_answer.py" "true"
signed_review "$BPRIME/done-means.json"
rc=0
cli run "$BPRIME" || rc=$?
if [ "$rc" -eq 1 ]; then ok "a pytest tautology over a new symbol is blocked"
else bad "bprime rc=$rc $(cat "$TMP/out")"; fi
shows "the stub leaves the tautology green" "still passed"
MASK="$TMP/mask"
git_repo "$MASK"
mkdir -p "$MASK/src"
printf '1\n' > "$MASK/src/app.py"
git -C "$MASK" add src/app.py
git -C "$MASK" commit -qm base
printf '2\n' > "$MASK/src/app.py"
printf '%s\n' 'import sys' 'sys.stderr.write("AssertionError\nE   AttributeError: no attribute answer\n")' 'raise SystemExit(1)' > "$MASK/test_mask.py"
mkdir -p "$MASK/test"
write_check "$MASK/done-means.json" "the mask exits 0" "python3 test_mask.py" "true"
signed_review "$MASK/done-means.json"
rc=0
cli run "$MASK" || rc=$?
if [ "$rc" -eq 1 ]; then ok "a printed AssertionError does not hide a final AttributeError"
else bad "mask rc=$rc $(cat "$TMP/out")"; fi
shows "the final exception line decides" "crash or import"

REAL="$TMP/realmod"
git_repo "$REAL"
git -C "$REAL" commit -q --allow-empty -m base
mkdir -p "$REAL/test"
printf '%s\n' 'def answer():' '    return 1' > "$REAL/answer.py"
printf '%s\n' \
  'import os, sys' \
  'sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))' \
  'import answer' \
  'assert answer.answer() == 1' > "$REAL/test/test_answer.py"
write_check "$REAL/done-means.json" "test/test_answer.py exits 0" "python3 test/test_answer.py" "true"
signed_review "$REAL/done-means.json"
rc=0
cli run "$REAL" || rc=$?
if [ "$rc" -eq 0 ]; then ok "a real assertion goes red when the new function is stubbed"
else bad "real assertion rc=$rc $(cat "$TMP/out")"; fi

echo "── N2: the base is a signed SHA, not a movable ref ──"
REF="$TMP/refmove"
rm -rf "$REF"
mkdir -p "$REF/src"
git -C "$REF" init -q -b main
git -C "$REF" config user.email t@example.com
git -C "$REF" config user.name t
printf '1\n' > "$REF/src/app.py"
git -C "$REF" add src/app.py
git -C "$REF" commit -qm base
PARENT="$(git -C "$REF" rev-parse HEAD)"
git -C "$REF" checkout -q -b change
printf '2\n' > "$REF/src/app.py"
git -C "$REF" add src/app.py
git -C "$REF" commit -qm change
SPEC_BASE="$PARENT" write_check "$REF/done-means.json" "python3 -c print exits 0" "python3 -c 'print(1)'" ""
signed_review "$REF/done-means.json"
git -C "$REF" branch -f main HEAD
rc=0
cli run "$REF" || rc=$?
if [ "$rc" -eq 1 ]; then ok "moving main to HEAD does not hide the committed change"
else bad "ref move rc=$rc $(cat "$TMP/out")"; fi
shows "the signed base still sees the product diff" "no test diff"
git -C "$REF" update-ref -d refs/heads/main
rc=0
cli run "$REF" || rc=$?
if [ "$rc" -eq 1 ]; then ok "deleting the main ref does not fall back to HEAD"
else bad "deleted main rc=$rc $(cat "$TMP/out")"; fi

echo "── B7: base env and a missing spec fail closed ──"
PINNED="$TMP/pinned"
rm -rf "$PINNED"
mkdir -p "$PINNED/src"
git -C "$PINNED" init -q -b main
git -C "$PINNED" config user.email t@example.com
git -C "$PINNED" config user.name t
printf '1\n' > "$PINNED/src/app.py"
git -C "$PINNED" add src/app.py
git -C "$PINNED" commit -qm base
PARENT="$(git -C "$PINNED" rev-parse HEAD)"
git -C "$PINNED" checkout -q -b change
printf '2\n' > "$PINNED/src/app.py"
git -C "$PINNED" add src/app.py
git -C "$PINNED" commit -qm change
SPEC_BASE="$PARENT" write_check "$PINNED/done-means.json" "python3 -c print exits 0" "python3 -c 'print(1)'" ""
signed_review "$PINNED/done-means.json"
rc=0
GUARDRAILS_DONE_BASE=HEAD cli run "$PINNED" || rc=$?
if [ "$rc" -eq 1 ]; then ok "GUARDRAILS_DONE_BASE=HEAD does not hide a committed change"
else bad "base env rc=$rc $(cat "$TMP/out")"; fi
shows "the committed change still needs a test" "no test diff"

GONE="$TMP/gone"
git_repo "$GONE"
write_check "$GONE/done-means.json" "true exits 0" "true" "false"
git -C "$GONE" add done-means.json
git -C "$GONE" commit -qm spec
mv "$GONE/done-means.json" "$GONE/gone.json"
python3 - "$ROOT" "$GONE" "$TRUST" "$GUARDRAILS_STATE_DIR" <<'PY'
import os, sys
root, repo, trust, state = sys.argv[1:]
os.environ["GUARDRAILS_STATE_DIR"] = state
os.environ.pop("GUARDRAILS_DONE_MEANS", None)
sys.path.insert(0, root)
from guardrails.done import bind_trust
from guardrails.goals import check_stop
from guardrails.live import note_hook
bind_trust(trust, False)
note_hook("gone")
verdict = check_stop("hello", repo, "gone")
sys.exit(0 if verdict.decision == "deny" else 1)
PY
if [ "$?" -eq 0 ]; then ok "removing a committed spec denies the stop"
else bad "removed spec was allowed"; fi

python3 - "$ROOT" "$GONE" "$TRUST" "$GUARDRAILS_STATE_DIR" <<'PY'
import os, sys
root, repo, trust, state = sys.argv[1:]
os.environ["GUARDRAILS_STATE_DIR"] = state
os.environ["GUARDRAILS_DONE_MEANS"] = "/nonexistent/spec.json"
sys.path.insert(0, root)
from guardrails.done import bind_trust
from guardrails.goals import check_stop
from guardrails.live import note_hook
bind_trust(trust, False)
note_hook("missing")
verdict = check_stop("hello", repo, "missing-env")
sys.exit(0 if verdict.decision == "deny" else 1)
PY
if [ "$?" -eq 0 ]; then ok "a missing GUARDRAILS_DONE_MEANS path denies the stop"
else bad "missing spec path was allowed"; fi
SEEN="$TMP/seen"
rm -rf "$SEEN"
mkdir -p "$SEEN"
write_check "$SEEN/done-means.json" "true exits 0" "false" "false"
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$SEEN" "$TRUST" "$GUARDRAILS_STATE_DIR" "hello" seen-1 deny
rm -f "$SEEN/done-means.json"
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$SEEN" "$TRUST" "$GUARDRAILS_STATE_DIR" "hello" seen-1 deny
if [ "$?" -eq 0 ]; then ok "the same session still expects a spec after it is renamed away"
else bad "same-session rename was allowed"; fi
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$SEEN" "$TRUST" "$GUARDRAILS_STATE_DIR" "hello" seen-2 allow
if [ "$?" -eq 0 ]; then ok "a fresh session does not keep another session's spec marker"
else bad "fresh session was denied"; fi

echo "── B8: any non-question stop is denied while the gate fails ──"
PHRASES=(
  "The task is complete."
  "Task complete."
  "Implementation complete; tests pass."
  "**Done.**"
  "Done ✅"
  "✅ Done"
  "I've finished the change."
  "I have finished."
  "I've completed the task."
  "The change is in place and working."
  "Shipped."
  "All set."
  "Everything works now."
  "Wrapped up."
  "Complete."
)
phrase_rc=0
phrase_i=0
for phrase in "${PHRASES[@]}"; do
  phrase_i=$((phrase_i + 1))
  python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "$phrase" "phrase-$phrase_i" deny
  if [ "$?" -ne 0 ]; then phrase_rc=1; bad "allowed completion phrasing: $phrase"; fi
done
if [ "$phrase_rc" -eq 0 ]; then ok "fifteen completion phrasings are denied while the spec fails"; fi
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "Finished reading the logs, but I still need your input. Which branch?" ask warn
if [ "$?" -eq 0 ]; then ok "a question is not denied as a done claim"
else bad "question was denied"; fi
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "BLOCKED: the check is still red." blocked warn
blocked_rc=$?
if [ "$blocked_rc" -eq 0 ]; then ok "a BLOCKED: line is not denied"
else bad "BLOCKED was denied"; fi
loose_i=0
for loose in \
  "Done. Tests pass. Anything else?" \
  "The task is complete. Want me to open a PR?" \
  "Shipped, see https://example.com/run?id=1" \
  "Done. I ran \`curl localhost/?q=1\`." \
  "BLOCKED:"
do
  loose_i=$((loose_i + 1))
  python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "$loose" "loose-$loose_i" deny
  if [ "$?" -ne 0 ]; then bad "excused a done claim: $loose"; fi
done
ok "question marks and a bare BLOCKED line do not excuse a done claim"
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "still working" cap deny
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "still working" cap deny
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "still working" cap deny
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "still working" cap warn
if [ "$?" -eq 0 ]; then ok "the fourth stop in a session is a notice, not another deny"
else bad "stop cap did not open"; fi
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "still working" cap deny new
if [ "$?" -eq 0 ]; then ok "a new turn resets the three-deny cap"
else bad "a new turn stayed at the cap"; fi
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "BLOCKED: the DB password rotation is done." pw warn
if [ "$?" -eq 0 ]; then ok "a BLOCKED line that mentions done is a notice"
else bad "BLOCKED DB password was denied"; fi
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "Is the migration done?" qdone warn
if [ "$?" -eq 0 ]; then ok "a question that contains done is not denied"
else bad "a done question was denied"; fi
empty_i=0
while [ "$empty_i" -lt 3 ]; do
  empty_i=$((empty_i + 1))
  python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "still working" "" deny
  if [ "$?" -ne 0 ]; then bad "an empty session id denied forever at try $empty_i"; fi
done
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$PHRASE" "$TRUST" "$GUARDRAILS_STATE_DIR" "still working" "" warn
if [ "$?" -eq 0 ]; then ok "an empty session id reaches the three-deny cap"
else bad "an empty session id never opened the cap"; fi

echo "── pytest E assert is an assertion, and a new non-Python file does not refuse sabotage ──"
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from guardrails.done import assertion_red
out = "F\nE   assert 1 == 2\n"
raise SystemExit(0 if assertion_red(1, out) else 1)
PY
if [ "$?" -eq 0 ]; then ok "a pytest E assert line counts as an assertion"
else bad "a pytest E assert line was treated as a crash"; fi

NEWF="$TMP/newfile"
git_repo "$NEWF"
mkdir -p "$NEWF"
printf '%s\n' 'def answer():' '    return 0' > "$NEWF/answer.py"
git -C "$NEWF" add answer.py
git -C "$NEWF" commit -qm base
printf '%s\n' 'def answer():' '    return 1' > "$NEWF/answer.py"
printf 'note\n' > "$NEWF/extra.txt"
mkdir -p "$NEWF/test"
printf '%s\n' \
  'import os, sys' \
  'sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))' \
  'import answer' \
  'assert answer.answer() == 1' > "$NEWF/test/test_answer.py"
write_check "$NEWF/done-means.json" "test/test_answer.py exits 0" "python3 test/test_answer.py" "true"
signed_review "$NEWF/done-means.json"
rc=0
cli run "$NEWF" || rc=$?
if [ "$rc" -eq 0 ]; then ok "a new non-Python file does not refuse a real assertion"
else bad "new file rc=$rc $(cat "$TMP/out")"; fi

echo "── an old spec deletion already on main does not deny a later session ──"
OLD="$TMP/old-spec"
rm -rf "$OLD"
mkdir -p "$OLD"
git -C "$OLD" init -q -b main
git -C "$OLD" config user.email t@example.com
git -C "$OLD" config user.name t
git -C "$OLD" commit -q --allow-empty -m base
write_check "$OLD/done-means.json" "true exits 0" "true" "false"
git -C "$OLD" add done-means.json
git -C "$OLD" commit -qm spec
git -C "$OLD" rm -q done-means.json
git -C "$OLD" commit -qm delete-spec
printf 'later\n' > "$OLD/later.txt"
git -C "$OLD" add later.txt
git -C "$OLD" commit -qm later
python3 "$ROOT/tests/check_stop.py" "$ROOT" "$OLD" "$TRUST" "$GUARDRAILS_STATE_DIR" "hello" old-session allow
if [ "$?" -eq 0 ]; then ok "a spec deleted on main does not deny a later session"
else bad "an old spec deletion denied a later session"; fi

rm -f "$GUARDRAILS_STATE_DIR/hook-live-$GUARDRAILS_SESSION"
rc=0
cli run "$DOC" || rc=$?
if [ "$rc" -eq 1 ]; then ok "run refuses when no hook has fired"
else bad "heartbeat rc=$rc $(cat "$TMP/out")"; fi
shows "the missing heartbeat is named" "hooks not live for this session"
python3 -c 'import os,sys; sys.path.insert(0, sys.argv[1]); from guardrails.live import note_hook; note_hook(os.environ["GUARDRAILS_SESSION"])' "$ROOT"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
