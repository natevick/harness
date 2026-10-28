#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CHECK="$PKG/check.py"
FIX="$HERE/fixtures/duplicates"
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

dup() {
  python3 "$CHECK" duplicates --root "$1" --min-lines 5 --min-tokens 25
}

echo "RED — duplicated blocks from the reviews fail and name the fix:"

out="$(dup "$FIX/junit-before" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] \
  && printf '%s\n' "$out" | grep -q 'Extract one shared helper' \
  && printf '%s\n' "$out" | grep -q 'ProtocolTest.java' \
  && printf '%s\n' "$out" | grep -q 'ForkedSurefireIT.java' \
  && printf '%s\n' "$out" | grep -q 'DiscoveryTest.java' \
  && printf '%s\n' "$out" | grep -q 'ClientRun.java'; then
  ok "junit finding 2, helpers copied across four classes"
else
  bad "junit finding 2, helpers copied across four classes (rc=$rc)"
  printf '%s\n' "$out"
fi

out="$(dup "$FIX/ruby-before" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] \
  && printf '%s\n' "$out" | grep -q 'Extract one shared helper' \
  && printf '%s\n' "$out" | grep -q 'stdio_transport_spec.rb' \
  && printf '%s\n' "$out" | grep -q 'stdio_controller_spec.rb'; then
  ok "ruby finding 1, identical ENV around blocks"
else
  bad "ruby finding 1, identical ENV around blocks (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "GREEN — the review's extract-one-helper fix passes:"

out="$(dup "$FIX/junit-after" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'duplicate logic:'; then
  ok "junit helpers live once on ClientRun"
else
  bad "junit helpers live once on ClientRun (rc=$rc)"
  printf '%s\n' "$out"
fi

out="$(dup "$FIX/ruby-after" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'duplicate logic:'; then
  ok "ruby ENV save/restore is one with_env"
else
  bad "ruby ENV save/restore is one with_env (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "OPT-IN — a repo that does not enable the guard is not failed:"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/off.json" <<EOF
{
  "duplicates": {"enabled": false, "paths": ["$FIX/junit-before"], "minLines": 5, "minTokens": 25},
  "catchIgnore": {"enabled": false}
}
EOF
out="$(python3 "$CHECK" --config "$tmp/off.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'duplicate logic:'; then
  ok "enabled false skips the junit copies"
else
  bad "enabled false skips the junit copies (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "BASELINE — clones already recorded are quiet; a new copy fails:"

python3 "$CHECK" duplicates --root "$FIX/ruby-before" --min-lines 5 --min-tokens 25 \
  --baseline "$tmp/base.json" --update-baseline >/dev/null 2>&1
out="$(python3 "$CHECK" duplicates --root "$FIX/ruby-before" --min-lines 5 --min-tokens 25 \
  --baseline "$tmp/base.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "recorded ENV clone is not new"
else
  bad "recorded ENV clone is not new (rc=$rc)"
  printf '%s\n' "$out"
fi

mkdir -p "$tmp/more"
cp "$FIX/ruby-before/"* "$tmp/more/"
cp "$FIX/ruby-before/stdio_transport_spec.rb" "$tmp/more/extra_spec.rb"
out="$(python3 "$CHECK" duplicates --root "$tmp/more" --min-lines 5 --min-tokens 25 \
  --baseline "$tmp/base.json" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'extra_spec.rb' \
  && printf '%s\n' "$out" | grep -q 'Extract one shared helper'; then
  ok "a third copy of the ENV block is new"
else
  bad "a third copy of the ENV block is new (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "LINE EXCEPTION — duplicate-ok on both copies, with a reason, stands down:"

mkdir -p "$tmp/marked"
cp "$FIX/ruby-before/stdio_transport_spec.rb" "$FIX/ruby-before/stdio_controller_spec.rb" "$tmp/marked/"
python3 - "$tmp/marked" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for path in root.glob("*.rb"):
    text = path.read_text()
    path.write_text("# duplicate-ok: kept while the specs still boot the fake transport\n" + text)
PY
out="$(dup "$tmp/marked" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "marked pair is allowed"
else
  bad "marked pair is allowed (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "THIS REPO — the one CI command stays quiet on the grandfathered baseline:"

out="$(python3 "$CHECK" --config "$PKG/simplicity.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "simplicity.json"
else
  bad "simplicity.json (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
