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

write_touch_spec() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, base, marker = sys.argv[1:]
json.dump({
    "task": "value",
    "done": "true exits 0",
    "base": base,
    "checks": [{"id": "marker", "run": "touch %s" % marker, "sabotage": False}],
}, open(path, "w"))
PY
}

write_true_spec() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, base = sys.argv[1:]
json.dump({
    "task": "value",
    "done": "true exits 0",
    "base": base,
    "checks": [{"id": "pass", "run": "true", "sabotage": False}],
}, open(path, "w"))
PY
}

gate() {
  HARNESS_REVIEWERS_JSON="$TRUST_JSON" python3 - "$ROOT" "$1" "$TRUST_JSON" "${2:-}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from ci_verify_review import verify_worktree
raise SystemExit(verify_worktree(sys.argv[2], sys.argv[3], sys.argv[4]))
PY
}

echo "── the workflow does not run the pull request tree before the verifier ──"
WF="$REPO_ROOT/.github/workflows/review-signature.yml"
python3 - "$WF" "$TMP" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
steps = []
current = None
mode = None
buf = []
for line in text.splitlines():
    if line.startswith("      - name:") or line.startswith("      - uses:"):
        if current is not None:
            steps.append((current, "\n".join(buf)))
        current = line.strip()
        buf = []
        mode = None
        continue
    if current is None:
        continue
    if line.startswith("        run: |"):
        mode = "block"
        continue
    if line.startswith("        run: "):
        buf.append(line.split("run:", 1)[1].strip())
        mode = None
        continue
    if mode == "block" and (line.startswith("          ") or line.strip() == ""):
        buf.append(line[10:] if line.startswith("          ") else "")
        continue
    mode = None
if current is not None:
    steps.append((current, "\n".join(buf)))
before = []
verifier = ""
for name, run in steps:
    if 'python3 "${verifier}"' in run:
        verifier = run
        break
    if run.strip():
        before.append(run)
if not verifier:
    raise SystemExit("verifier step missing")
invoke = re.compile(
    r"(?:^|[;&|]\s*|&&\s*|\|\|\s*)(?:bash|sh|python3|python|node)\s+\S*packages/"
)
hit = [run for run in before if invoke.search(run) or "packages/guardrails/ci_" in run]
if hit or "--base-ref" not in verifier:
    raise SystemExit("early step invokes packages/ or --base-ref is missing")
open(sys.argv[2] + "/install-run.sh", "w").write(before[-1] + "\n")
open(sys.argv[2] + "/verify-run.sh", "w").write(verifier + "\n")
PY
if [ "$?" -eq 0 ]; then ok "no step before the verifier runs a path under packages/"
else bad "a step before the verifier invokes packages/ or drops --base-ref"; fi
INSTALL_RUN="$TMP/install-run.sh"
VERIFY_RUN="$TMP/verify-run.sh"

echo "── npm ci --ignore-scripts uses the base lockfile, and the fallback too ──"
fake_npm() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/npm" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$NPM_LOG"
prefix="."
prev=""
for arg in "$@"; do
  if [ "$prev" = "--prefix" ]; then
    prefix="$arg"
  fi
  prev="$arg"
done
mkdir -p "$prefix/node_modules"
printf '%s\n' "$prefix" > "$prefix/node_modules/from-prefix"
SH
  chmod +x "$bin/npm"
}
NPM_LOCK="$TMP/npm-lock"
rm -rf "$NPM_LOCK" "$TMP/npm-lock.git"
git init -q --bare -b trunk "$TMP/npm-lock.git"
git clone -q "$TMP/npm-lock.git" "$NPM_LOCK"
git_identity "$NPM_LOCK"
git -C "$NPM_LOCK" checkout -q -b trunk
mkdir -p "$NPM_LOCK/packages/guardrails"
printf '%s\n' '{"name":"guardrails","version":"0.0.0"}' > "$NPM_LOCK/packages/guardrails/package.json"
printf '%s\n' '{"name":"guardrails","lockfileVersion":3,"requires":true,"packages":{}}' > "$NPM_LOCK/packages/guardrails/package-lock.json"
git -C "$NPM_LOCK" add packages/guardrails
git -C "$NPM_LOCK" commit -qm lock
git -C "$NPM_LOCK" push -q -u origin trunk
fake_npm "$TMP/npm-bin"
export NPM_LOG="$TMP/npm-lock-log"
: > "$NPM_LOG"
PATH="$TMP/npm-bin:$PATH" GITHUB_WORKSPACE="$NPM_LOCK" BASE_REF=trunk bash "$INSTALL_RUN"
lock_prefix="$(cat "$NPM_LOCK/packages/guardrails/node_modules/from-prefix" 2>/dev/null || true)"
if grep -q -- '--ignore-scripts' "$NPM_LOG" && ! grep -q -- '--ignore-scripts=false' "$NPM_LOG" \
  && [ -n "$lock_prefix" ] && [ "$lock_prefix" != "$NPM_LOCK/packages/guardrails" ]; then
  ok "the base lockfile install uses npm ci --ignore-scripts"
else
  bad "base lockfile install log=$(cat "$NPM_LOG") prefix=$lock_prefix"
fi
NPM_ELSE="$TMP/npm-else"
rm -rf "$NPM_ELSE"
mkdir -p "$NPM_ELSE/packages/guardrails"
git -C "$NPM_ELSE" init -q
git_identity "$NPM_ELSE"
git -C "$NPM_ELSE" commit -q --allow-empty -m empty
export NPM_LOG="$TMP/npm-else-log"
: > "$NPM_LOG"
PATH="$TMP/npm-bin:$PATH" GITHUB_WORKSPACE="$NPM_ELSE" BASE_REF= bash "$INSTALL_RUN"
else_prefix="$(cat "$NPM_ELSE/packages/guardrails/node_modules/from-prefix" 2>/dev/null || true)"
if grep -q -- '--ignore-scripts' "$NPM_LOG" && ! grep -q -- '--ignore-scripts=false' "$NPM_LOG" \
  && [ "$else_prefix" = "$NPM_ELSE/packages/guardrails" ]; then
  ok "the fallback install uses npm ci --ignore-scripts"
else
  bad "fallback install log=$(cat "$NPM_LOG") prefix=$else_prefix"
fi

echo "── an unsigned spec does not run its check ──"
UNSIGN="$TMP/unsigned"
mkdir -p "$UNSIGN"
git -C "$UNSIGN" init -q
git_identity "$UNSIGN"
git -C "$UNSIGN" commit -q --allow-empty -m base
BASE="$(git -C "$UNSIGN" rev-parse HEAD)"
MARKER="$UNSIGN/ran-marker"
write_touch_spec "$UNSIGN/done-means.json" "$BASE" "$MARKER"
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
gate "$UNSIGN" || rc=$?
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
mkdir -p "$TMP/py-bin"
cat > "$TMP/py-bin/python3" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PY_LOG"
exit 0
SH
chmod +x "$TMP/py-bin/python3"
export PY_LOG="$TMP/py-log"
: > "$PY_LOG"
sel_rc=0
PATH="$TMP/py-bin:$PATH" GITHUB_WORKSPACE="$SELECT" BASE_REF=trunk DEFAULT_BRANCH=trunk \
  bash "$VERIFY_RUN" >"$TMP/sel-ok" 2>"$TMP/sel-err" || sel_rc=$?
if [ "$sel_rc" -eq 0 ] && grep -q 'bootstrap' "$TMP/sel-err"; then
  ok "the default branch may bootstrap its own verifier"
else
  bad "bootstrap rc=$sel_rc $(cat "$TMP/sel-err")"
fi
sel_rc=0
PATH="$TMP/py-bin:$PATH" GITHUB_WORKSPACE="$SELECT" BASE_REF=other DEFAULT_BRANCH=trunk \
  bash "$VERIFY_RUN" >"$TMP/sel-no" 2>"$TMP/sel-noerr" || sel_rc=$?
if [ "$sel_rc" -ne 0 ] && grep -q 'refusing' "$TMP/sel-noerr"; then
  ok "a non-default base without a verifier is refused"
else
  bad "non-default fallback rc=$sel_rc $(cat "$TMP/sel-noerr")"
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
sign_pass "$DUP/done-means.json"
rc=0
gate "$DUP" >"$TMP/dup-out" 2>"$TMP/dup-err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'duplicate key' "$TMP/dup-out" && [ ! -e "$DUP_MARK" ]; then
  ok "a signed duplicate-key spec does not run the check"
else
  bad "duplicate key rc=$rc $(cat "$TMP/dup-out") marker=$( [ -e "$DUP_MARK" ] && echo yes || echo no )"
fi
REV="$TMP/dup-review"
mkdir -p "$REV"
git -C "$REV" init -q
git_identity "$REV"
git -C "$REV" commit -q --allow-empty -m base
REV_BASE="$(git -C "$REV" rev-parse HEAD)"
REV_MARK="$REV/ran-marker"
write_touch_spec "$REV/done-means.json" "$REV_BASE" "$REV_MARK"
sign_pass "$REV/done-means.json"
python3 - "$REV/done-means.review.json" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = '"observable": true'
if needle not in text:
    raise SystemExit("review has no observable true")
open(path, "w").write(text.replace(needle, '"observable": false, "observable": true', 1))
PY
rc=0
gate "$REV" >"$TMP/rev-out" 2>"$TMP/rev-err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'duplicate key: observable' "$TMP/rev-out" && [ ! -e "$REV_MARK" ]; then
  ok "a duplicate key in a signed review does not run the check"
else
  bad "review duplicate rc=$rc $(cat "$TMP/rev-out") marker=$( [ -e "$REV_MARK" ] && echo yes || echo no )"
fi

echo "── a bare origin exercises --base-ref ──"
BARE="$TMP/bare.git"
WORK="$TMP/bare-work"
rm -rf "$BARE" "$WORK"
git init -q --bare -b trunk "$BARE"
git clone -q "$BARE" "$WORK"
git_identity "$WORK"
git -C "$WORK" checkout -q -b trunk
printf '0\n' > "$WORK/note"
git -C "$WORK" add note
git -C "$WORK" commit -qm older
printf '1\n' > "$WORK/note"
git -C "$WORK" commit -qam base
git -C "$WORK" push -q -u origin trunk
git -C "$WORK" checkout -q -b change
printf '2\n' > "$WORK/note"
git -C "$WORK" commit -qam change
MERGE="$(git -C "$WORK" merge-base refs/remotes/origin/trunk HEAD)"
OLDER="$(git -C "$WORK" rev-parse refs/remotes/origin/trunk^)"
write_true_spec "$WORK/done-means.json" "$MERGE"
sign_pass "$WORK/done-means.json"
rc=0
gate "$WORK" trunk || rc=$?
if [ "$rc" -eq 0 ]; then ok "a bare origin merge-base passes --base-ref"
else bad "bare origin pass rc=$rc"; fi

write_true_spec "$WORK/done-means.json" "$OLDER"
sign_pass "$WORK/done-means.json"
out="$(gate "$WORK" trunk 2>&1 || true)"
if printf '%s' "$out" | grep -q 'not the merge-base'; then
  ok "an older ancestor is not the merge-base"
else
  bad "older ancestor was accepted: $out"
fi

echo "── a tag named origin/<base> cannot choose the verifier ──"
SH="$TMP/shadow.git"
SW="$TMP/shadow-src"
rm -rf "$SH" "$SW"
git init -q --bare -b trunk "$SH"
git clone -q "$SH" "$SW"
git_identity "$SW"
git -C "$SW" checkout -q -b trunk
printf 'old\n' > "$SW/old.txt"
git -C "$SW" add old.txt
git -C "$SW" commit -qm old
OLD="$(git -C "$SW" rev-parse HEAD)"
mkdir -p "$SW/packages/guardrails"
printf '%s\n' 'import sys' 'sys.exit(0)' > "$SW/packages/guardrails/ci_verify_review.py"
git -C "$SW" add packages/guardrails/ci_verify_review.py
git -C "$SW" commit -qm stub
STUB="$(git -C "$SW" rev-parse HEAD)"
printf '%s\n' 'import sys' 'raise SystemExit(1)' > "$SW/packages/guardrails/ci_verify_review.py"
git -C "$SW" commit -qam reject
git -C "$SW" push -q -u origin trunk
git -C "$SW" tag -f origin/trunk "$STUB"
git -C "$SW" push -q origin refs/tags/origin/trunk
AT="$TMP/shadow-pr"
git clone -q "$SH" "$AT"
git -C "$AT" fetch -q origin "+refs/tags/origin/trunk:refs/tags/origin/trunk"
mkdir -p "$AT/packages/guardrails"
printf '%s\n' 'import sys' 'sys.exit(0)' > "$AT/packages/guardrails/ci_verify_review.py"
rc=0
GITHUB_WORKSPACE="$AT" BASE_REF=trunk DEFAULT_BRANCH=trunk HARNESS_REVIEWERS_JSON="$TRUST_JSON" \
  bash "$VERIFY_RUN" >"$TMP/tag-a" 2>"$TMP/tag-a-err" || rc=$?
if [ "$rc" -ne 0 ]; then ok "a shadow tag with a stub verifier does not pass"
else bad "stub tag passed: $(cat "$TMP/tag-a") $(cat "$TMP/tag-a-err")"; fi
git -C "$SW" tag -f origin/trunk "$OLD"
git -C "$SW" push -q --force origin refs/tags/origin/trunk
git -C "$AT" fetch -q origin "+refs/tags/origin/trunk:refs/tags/origin/trunk"
rc=0
GITHUB_WORKSPACE="$AT" BASE_REF=trunk DEFAULT_BRANCH=trunk HARNESS_REVIEWERS_JSON="$TRUST_JSON" \
  bash "$VERIFY_RUN" >"$TMP/tag-b" 2>"$TMP/tag-b-err" || rc=$?
if [ "$rc" -ne 0 ]; then ok "a shadow tag with no verifier does not bootstrap the pull request"
else bad "empty tag bootstrapped: $(cat "$TMP/tag-b") $(cat "$TMP/tag-b-err")"; fi

LEG="$TMP/shadow-legit"
rm -rf "$SW/packages/guardrails"
mkdir -p "$SW/packages/guardrails"
cp -a "$ROOT/." "$SW/packages/guardrails/"
rm -rf "$SW/packages/guardrails/node_modules" "$SW/packages/guardrails/__pycache__"
git -C "$SW" add -A packages/guardrails
git -C "$SW" commit -qm real
git -C "$SW" push -q origin trunk
git clone -q "$SH" "$LEG"
git -C "$LEG" fetch -q origin "+refs/tags/origin/trunk:refs/tags/origin/trunk"
LEG_BASE="$(git -C "$LEG" rev-parse refs/remotes/origin/trunk)"
write_true_spec "$LEG/done-means.json" "$LEG_BASE"
sign_pass "$LEG/done-means.json"
rc=0
GITHUB_WORKSPACE="$LEG" BASE_REF=trunk DEFAULT_BRANCH=trunk HARNESS_REVIEWERS_JSON="$TRUST_JSON" \
  bash "$VERIFY_RUN" >"$TMP/tag-ok" 2>"$TMP/tag-ok-err" || rc=$?
if [ "$rc" -eq 0 ]; then ok "a signed spec still passes while the shadow tag exists"
else bad "signed spec with tag rc=$rc $(cat "$TMP/tag-ok") $(cat "$TMP/tag-ok-err")"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
