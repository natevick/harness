begin_reviewer_fixture() {
  openssl genpkey -algorithm ED25519 -out "$TMP/reviewer.pem"
  openssl pkey -in "$TMP/reviewer.pem" -pubout -out "$TMP/reviewer.pub"
  export REVIEW_PRIV="$TMP/reviewer.pem"
  export REVIEWER_ID="reviewer@example.com"
  TRUST="$TMP/reviewers.json"
  python3 - "$TRUST" "$TMP" <<'PY'
import os, sys
trust, tmp = sys.argv[1:]
parent = os.path.realpath(os.path.dirname(os.path.abspath(trust)))
root = os.path.realpath(tmp)
if os.path.commonpath([parent, root]) != root:
    raise SystemExit("fixture refuses to write a trust file outside TMP")
if os.path.abspath(trust) in (
    "/etc/harness/reviewers.json",
    os.path.realpath(os.path.join(os.path.expanduser("~"), ".harness", "reviewers.json")),
):
    raise SystemExit("fixture refuses to touch the real trust path")
PY
  python3 "$ROOT/tests/review_sign.py" --trust "$TRUST" "$TMP/reviewer.pub" "$REVIEWER_ID"
  mkdir -p "$GUARDRAILS_STATE_DIR"
  export GUARDRAILS_SESSION=test-session
  python3 -c 'import os,sys; sys.path.insert(0, sys.argv[1]); from guardrails.live import note_hook; note_hook(os.environ["GUARDRAILS_SESSION"])' "$ROOT"
}

end_reviewer_fixture() {
  return 0
}

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

cli() {
  python3 "$ROOT/tests/invoke_done.py" "$TRUST" "$@" >"$TMP/out" 2>"$TMP/err"
}

shows() {
  local name="$1" needle="$2"
  if grep -q "$needle" "$TMP/out"; then ok "$name"
  else bad "$name (missing $needle) $(cat "$TMP/out")"; fi
}
