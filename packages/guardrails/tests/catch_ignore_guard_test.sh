#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CHECK="$PKG/check.py"
FIX="$HERE/fixtures/catch_ignore"
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

scan() {
  python3 "$CHECK" catch-ignore --root "$1"
}

echo "RED — empty and no-op catches from the reviews fail and name the fix:"

out="$(scan "$FIX/red" 2>&1)"
rc=$?
needles="Handle it, rethrow it, or delete the try.
transport.js
session.js
protocol.test.js
reporters.py
minimal_websocket_server.rb
EmptyCatch.java
swallow.ex"
miss=""
if [ "$rc" -eq 0 ]; then
  miss="exit 0"
fi
while IFS= read -r needle; do
  [ -z "$needle" ] && continue
  printf '%s\n' "$out" | grep -q "$needle" || miss="$miss $needle"
done <<EOF
$needles
EOF
if [ -z "$miss" ]; then
  ok "vitest 3, 5, 6 plus python, ruby, java, elixir"
else
  bad "vitest 3, 5, 6 plus python, ruby, java, elixir ($miss)"
  printf '%s\n' "$out"
fi

echo
echo "GREEN — delete the try, the way the reviews fix them:"

out="$(scan "$FIX/green" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'catch-and-ignore:'; then
  ok "fixed examples have no swallow"
else
  bad "fixed examples have no swallow (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "ALLOW — a catch that rethrows, logs, returns a value, or is marked:"

out="$(scan "$FIX/allow" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'catch-and-ignore:'; then
  ok "handlers are not swallows"
else
  bad "handlers are not swallows (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "OPT-IN — disabled in the repo config, the red tree does not fail:"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/off.json" <<EOF
{"catchIgnore": {"enabled": false, "paths": ["$FIX/red"]}}
EOF
out="$(python3 "$CHECK" --config "$tmp/off.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'catch-and-ignore:'; then
  ok "enabled false skips the red tree"
else
  bad "enabled false skips the red tree (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "BASELINE — recorded swallows are quiet; a new one fails:"

python3 "$CHECK" catch-ignore --root "$FIX/red" --baseline "$tmp/base.json" --update-baseline >/dev/null 2>&1
out="$(python3 "$CHECK" catch-ignore --root "$FIX/red" --baseline "$tmp/base.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "recorded swallows are not new"
else
  bad "recorded swallows are not new (rc=$rc)"
  printf '%s\n' "$out"
fi

mkdir -p "$tmp/more"
cp "$FIX/red/"* "$tmp/more/"
printf 'try {\n  sink()\n} catch (error) {\n}\n' > "$tmp/more/fresh.js"
out="$(python3 "$CHECK" catch-ignore --root "$tmp/more" --baseline "$tmp/base.json" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'fresh.js' \
  && printf '%s\n' "$out" | grep -q 'Handle it, rethrow it, or delete the try.'; then
  ok "a new empty catch fails"
else
  bad "a new empty catch fails (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
echo "THIS REPO — grandfathered swallows stay quiet:"

out="$(python3 "$CHECK" catch-ignore --root "$ROOT" --baseline "$PKG/simplicity/catch-ignore-baseline.json" \
  --ignore '**/node_modules/**' --ignore '**/.git/**' --ignore '**/tests/fixtures/**' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "repo baseline"
else
  bad "repo baseline (rc=$rc)"
  printf '%s\n' "$out"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
