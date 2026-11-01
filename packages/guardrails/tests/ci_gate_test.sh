#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
export GUARDRAILS_STATE_DIR="$TMP/state"
mkdir -p "$GUARDRAILS_STATE_DIR"
. "$ROOT/tests/fixture.sh"
begin_reviewer_fixture
trap 'end_reviewer_fixture; rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

python3 "$ROOT/ci_verify_review.py" --self-test
if [ "$?" -eq 0 ]; then ok "the canonical signature self-test passes"
else bad "self-test failed"; fi

REPO="$TMP/repo"
rm -rf "$REPO"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf '1\n' > "$REPO/src-note"
mkdir -p "$REPO"
python3 - "$REPO/done-means.json" "$BASE" <<'PY'
import json, sys
path, base = sys.argv[1:]
json.dump({
    "task": "value",
    "done": "true exits 0",
    "base": base,
    "checks": [{"id": "unit", "run": "false", "sabotage": False, "reason": "the command does not read the diff"}],
}, open(path, "w"))
PY
python3 "$ROOT/tests/review_sign.py" "$REPO/done-means.json" "$REVIEWER_ID" "$REVIEW_PRIV" fail
TRUST_JSON="$(python3 -c 'import sys; print(open(sys.argv[1]).read())' "$TRUST")"
run_gate() {
  HARNESS_REVIEWERS_JSON="$TRUST_JSON" python3 - "$ROOT" "$REPO" "$TRUST_JSON" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from ci_verify_review import verify_worktree
sys.exit(verify_worktree(sys.argv[2], sys.argv[3], ""))
PY
}

rc=0
out="$(run_gate 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "secret is required"; then
  ok "a signed failing review does not pass the CI gate"
else bad "signed failure rc=$rc $out"; fi

python3 "$ROOT/tests/review_sign.py" "$REPO/done-means.json" "$REVIEWER_ID" "$REVIEW_PRIV" pass
python3 - "$REPO/done-means.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["checks"] = [{"id": "unit", "run": "true", "sabotage": False, "reason": "the command does not read the diff"}]
json.dump(data, open(path, "w"))
PY
rc=0
out="$(run_gate 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "secret is required"; then
  ok "rewriting the spec after signing does not pass the CI gate"
else bad "rewritten spec rc=$rc $out"; fi

rm -f "$REPO/done-means.json"
rc=0
out="$(run_gate 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "secret is required"; then
  ok "a deleted spec does not pass the CI gate"
else bad "deleted spec rc=$rc $out"; fi

python3 - "$REPO/done-means.json" "$BASE" <<'PY'
import json, sys
path, base = sys.argv[1:]
json.dump({
    "task": "value",
    "done": "true exits 0",
    "base": base,
    "checks": [{"id": "unit", "run": "true", "sabotage": False, "reason": "the command does not read the diff"}],
}, open(path, "w"))
PY
printf '2\n' > "$REPO/src-note"
git -C "$REPO" add src-note done-means.json
git -C "$REPO" commit -qm change
python3 "$ROOT/tests/review_sign.py" "$REPO/done-means.json" "$REVIEWER_ID" "$REVIEW_PRIV" pass
rc=0
out="$(run_gate 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then ok "a signed sabotage opt-out with a reason passes the CI gate"
else bad "opt-out rc=$rc $out"; fi

mkdir -p "$REPO/.cursor"
printf '%s\n' '{"version":1,"hooks":{}}' > "$REPO/.cursor/hooks.json"
git -C "$REPO" add .cursor/hooks.json
git -C "$REPO" commit -qm hooks
python3 - "$REPO/done-means.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["paths"] = {"allow_protected": [".cursor/hooks.json"]}
json.dump(data, open(path, "w"))
PY
python3 "$ROOT/tests/review_sign.py" "$REPO/done-means.json" "$REVIEWER_ID" "$REVIEW_PRIV" pass
rc=0
out="$(run_gate 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then ok "a signed spec may allow a .cursor/hooks.json change"
else bad "allowed hooks rc=$rc $out"; fi

python3 - "$REPO/done-means.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["checks"][0].pop("reason", None)
json.dump(data, open(path, "w"))
PY
python3 "$ROOT/tests/review_sign.py" "$REPO/done-means.json" "$REVIEWER_ID" "$REVIEW_PRIV" pass
rc=0
out="$(run_gate 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "sabotage opt-out needs a reason"; then
  ok "a sabotage opt-out without a reason does not pass the CI gate"
else bad "missing reason rc=$rc $out"; fi

WF="$(cd "$ROOT/../.." && pwd)/.github/workflows/review-signature.yml"
if grep -q 'npm ci --prefix packages/guardrails' "$WF" && grep -q 'pull_request.head.sha' "$WF"; then
  ok "the review workflow installs jscpd and checks out the PR head"
else bad "review workflow is missing npm ci or the PR head checkout"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
