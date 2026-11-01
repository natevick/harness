#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

python3 "$ROOT/ci_verify_review.py" --self-test
if [ "$?" -eq 0 ]; then ok "the canonical signature self-test passes"
else bad "self-test failed"; fi

openssl genpkey -algorithm ED25519 -out "$TMP/reviewer.pem"
openssl pkey -in "$TMP/reviewer.pem" -pubout -out "$TMP/reviewer.pub"
REVIEWER_ID="reviewer@example.com"
python3 "$ROOT/tests/review_sign.py" --trust "$TMP/reviewers.json" "$TMP/reviewer.pub" "$REVIEWER_ID"
TRUST_JSON="$(python3 -c 'import sys; print(open(sys.argv[1]).read())' "$TMP/reviewers.json")"

git_identity() {
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
}

sign_pass() {
  python3 "$ROOT/tests/review_sign.py" "$1" "$REVIEWER_ID" "$TMP/reviewer.pem" pass
}

echo "── npm ci ignores scripts and does not use the vulnerable line ──"
NPM="$ROOT/ci_npm.sh"
WF="$REPO_ROOT/.github/workflows/review-signature.yml"
if grep -q 'npm ci --ignore-scripts' "$NPM" && ! grep -q 'npm ci --prefix' "$NPM" && ! grep -q 'npm ci --prefix' "$WF"; then
  ok "npm ci --ignore-scripts is required"
else
  bad "npm install line is missing --ignore-scripts or still uses the vulnerable npm ci --prefix form"
fi
if grep -q 'package-lock.json' "$NPM"; then
  ok "npm ci installs from the base ref lockfile when that file exists"
else
  bad "npm ci does not consult the base lockfile"
fi

echo "── an unsigned spec does not run its check ──"
UNSIGN="$TMP/unsigned"
mkdir -p "$UNSIGN"
git -C "$UNSIGN" init -q
git_identity "$UNSIGN"
git -C "$UNSIGN" commit -q --allow-empty -m base
BASE="$(git -C "$UNSIGN" rev-parse HEAD)"
MARKER="$UNSIGN/ran-marker"
python3 - "$UNSIGN/done-means.json" "$BASE" "$MARKER" <<'PY'
import json, sys
path, base, marker = sys.argv[1:]
json.dump({
    "task": "value",
    "done": "true exits 0",
    "base": base,
    "checks": [{"id": "unit", "run": "touch %s" % marker, "sabotage": False}],
}, open(path, "w"))
PY
python3 - "$UNSIGN/done-means.json" <<'PY'
import hashlib, json, sys
spec = sys.argv[1]
digest = hashlib.sha256(open(spec, "rb").read()).hexdigest()
json.dump({
    "gaps": [],
    "observable": True,
    "testable": True,
    "scoped": True,
    "stopping_point": True,
    "spec_sha256": digest,
}, open(spec.replace(".json", ".review.json"), "w"))
PY
rc=0
HARNESS_REVIEWERS_JSON="$TRUST_JSON" python3 - "$ROOT" "$UNSIGN" "$TRUST_JSON" <<'PY' || rc=$?
import sys
sys.path.insert(0, sys.argv[1])
from ci_verify_review import verify_worktree
sys.exit(verify_worktree(sys.argv[2], sys.argv[3], ""))
PY
if [ "$rc" -ne 0 ] && [ ! -e "$MARKER" ]; then
  ok "an unsigned spec does not create its marker file"
else
  bad "unsigned marker rc=$rc exists=$( [ -e "$MARKER" ] && echo yes || echo no )"
fi

echo "── own-verifier fallback only on the default branch ──"
SELECT="$TMP/select"
rm -rf "$SELECT" "$TMP/select.git"
git init -q --bare -b trunk "$TMP/select.git"
git clone -q "$TMP/select.git" "$SELECT"
git_identity "$SELECT"
git -C "$SELECT" checkout -q -b trunk
mkdir -p "$SELECT/packages/guardrails"
printf '1\n' > "$SELECT/packages/guardrails/keep.txt"
git -C "$SELECT" add packages/guardrails/keep.txt
git -C "$SELECT" commit -qm trunk
git -C "$SELECT" push -q -u origin trunk
git -C "$SELECT" checkout -q -b other
printf '2\n' > "$SELECT/packages/guardrails/keep.txt"
git -C "$SELECT" commit -qam other
git -C "$SELECT" push -q -u origin other
sel_rc=0
bash "$ROOT/ci_select_verifier.sh" "$SELECT" trunk trunk >"$TMP/sel-ok" 2>"$TMP/sel-err" || sel_rc=$?
if [ "$sel_rc" -eq 0 ] && grep -q 'bootstrap' "$TMP/sel-err"; then
  ok "the default branch may bootstrap its own verifier"
else
  bad "bootstrap rc=$sel_rc $(cat "$TMP/sel-err")"
fi
sel_rc=0
bash "$ROOT/ci_select_verifier.sh" "$SELECT" other trunk >"$TMP/sel-no" 2>"$TMP/sel-noerr" || sel_rc=$?
if [ "$sel_rc" -ne 0 ] && grep -q 'refusing' "$TMP/sel-noerr"; then
  ok "a non-default base without a verifier is refused"
else
  bad "non-default fallback rc=$sel_rc $(cat "$TMP/sel-noerr")"
fi
if ! grep -q '"main"' "$ROOT/ci_select_verifier.sh"; then
  ok "verifier selection does not hard-code the default branch name"
else
  bad "verifier selection hard-codes main"
fi

echo "── checkout persists no credentials and re-runs when the PR is edited ──"
if grep -q 'persist-credentials: false' "$WF" && grep -q 'edited' "$WF" && grep -q 'repository.default_branch' "$WF"; then
  ok "checkout drops credentials and the gate follows the default branch"
else
  bad "workflow is missing persist-credentials, edited, or default_branch"
fi

echo "── duplicate JSON keys are rejected before checks run ──"
DUP="$TMP/dup"
mkdir -p "$DUP"
git -C "$DUP" init -q
git_identity "$DUP"
git -C "$DUP" commit -q --allow-empty -m base
DUP_BASE="$(git -C "$DUP" rev-parse HEAD)"
DUP_MARK="$DUP/ran-marker"
python3 - "$DUP/done-means.json" "$DUP_BASE" "$DUP_MARK" <<'PY'
import sys
path, base, marker = sys.argv[1:]
open(path, "w").write(
    '{"task":"value","task":"again","done":"true exits 0","base":"%s",'
    '"checks":[{"id":"unit","run":"touch %s","sabotage":false}]}' % (base, marker)
)
PY
rc=0
python3 "$ROOT/done_means.py" run "$DUP" >"$TMP/dup-out" 2>"$TMP/dup-err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'duplicate key' "$TMP/dup-out" && [ ! -e "$DUP_MARK" ]; then
  ok "a duplicate JSON key does not run the check"
else
  bad "duplicate key rc=$rc $(cat "$TMP/dup-out")"
fi

echo "── a bare origin exercises --base-ref ──"
BARE="$TMP/bare.git"
WORK="$TMP/bare-work"
rm -rf "$BARE" "$WORK"
git init -q --bare -b trunk "$BARE"
git clone -q "$BARE" "$WORK"
git_identity "$WORK"
git -C "$WORK" checkout -q -b trunk
printf '1\n' > "$WORK/note"
git -C "$WORK" add note
git -C "$WORK" commit -qm base
git -C "$WORK" push -q -u origin trunk
git -C "$WORK" checkout -q -b change
printf '2\n' > "$WORK/note"
git -C "$WORK" commit -qam change
MERGE="$(git -C "$WORK" merge-base origin/trunk HEAD)"
python3 - "$WORK/done-means.json" "$MERGE" <<'PY'
import json, sys
path, base = sys.argv[1:]
json.dump({
    "task": "value",
    "done": "true exits 0",
    "base": base,
    "checks": [{"id": "unit", "run": "true", "sabotage": False}],
}, open(path, "w"))
PY
sign_pass "$WORK/done-means.json"
rc=0
HARNESS_REVIEWERS_JSON="$TRUST_JSON" python3 - "$ROOT" "$WORK" "$TRUST_JSON" <<'PY' || rc=$?
import sys
sys.path.insert(0, sys.argv[1])
from ci_verify_review import verify_worktree
sys.exit(verify_worktree(sys.argv[2], sys.argv[3], "trunk"))
PY
if [ "$rc" -eq 0 ]; then ok "a bare origin merge-base passes --base-ref"
else bad "bare origin pass rc=$rc"; fi

WRONG="$(git -C "$WORK" rev-parse HEAD)"
python3 - "$WORK/done-means.json" "$WRONG" <<'PY'
import json, sys
path, base = sys.argv[1:]
data = json.load(open(path))
data["base"] = base
json.dump(data, open(path, "w"))
PY
sign_pass "$WORK/done-means.json"
rc=0
out="$(HARNESS_REVIEWERS_JSON="$TRUST_JSON" python3 - "$ROOT" "$WORK" "$TRUST_JSON" <<'PY' 2>&1 || true
import sys
sys.path.insert(0, sys.argv[1])
from ci_verify_review import verify_worktree
sys.exit(verify_worktree(sys.argv[2], sys.argv[3], "trunk"))
PY
)"
if printf '%s' "$out" | grep -q 'not the merge-base'; then
  ok "a base that is not the merge-base fails --base-ref"
else
  bad "wrong merge-base was accepted: $out"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
