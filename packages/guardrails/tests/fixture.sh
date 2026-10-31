begin_reviewer_fixture() {
  openssl genpkey -algorithm ED25519 -out "$TMP/reviewer.pem"
  openssl pkey -in "$TMP/reviewer.pem" -pubout -out "$TMP/reviewer.pub"
  export REVIEW_PRIV="$TMP/reviewer.pem"
  export REVIEWER_ID="reviewer@example.com"
  TRUST="$(python3 -c 'import os,pwd; print(os.path.join(pwd.getpwuid(os.geteuid()).pw_dir, ".harness", "reviewers.json"))')"
  if [ -f "$TRUST" ]; then cp "$TRUST" "$TMP/trust-backup"; fi
  mkdir -p "$(dirname "$TRUST")"
  export TRUST
}

end_reviewer_fixture() {
  if [ -f "$TMP/trust-backup" ]; then
    cp "$TMP/trust-backup" "$TRUST"
  else
    rm -f "$TRUST"
  fi
}

install_trust() {
  python3 - "${2:-$TRUST}" "$TMP/reviewer.pub" "$1" <<'PY'
import json, sys
path, pub, reviewer = sys.argv[1:]
json.dump({reviewer: open(pub).read()}, open(path, "w"))
PY
}

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
