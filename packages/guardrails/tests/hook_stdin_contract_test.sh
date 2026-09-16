#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(python3 -c 'import sys; print(sys.executable)')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

cat > "$TMP/detect.py" <<'PY'
import re
import sys
from pathlib import Path

OPENER = re.compile(r"\bpython3?\s+-\s*<<[-~]?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)")


def offends(path):
    lines = Path(path).read_text(errors="replace").split("\n")
    index = 0
    while index < len(lines):
        opener = OPENER.search(lines[index])
        if not opener:
            index += 1
            continue
        terminator = opener.group(1)
        index += 1
        body = []
        while index < len(lines) and lines[index].strip() != terminator:
            body.append(lines[index])
            index += 1
        if "sys.stdin" in "\n".join(body):
            return True
    return False


roots = [Path(root) for root in sys.argv[1:]]
scanned, found = 0, []
for root in roots:
    for script in sorted(root.rglob("*.sh")):
        if "/tests/" in str(script) and root.name != "fixtures":
            continue
        scanned += 1
        if offends(script):
            found.append(str(script))
print(scanned)
print("\n".join(found))
PY

scan() { "$PY" "$TMP/detect.py" "$1"; }

echo "A HOOK MUST BE ABLE TO READ ITS OWN PAYLOAD:"
echo "  a heredoc IS stdin, so 'python3 - <<PY' whose body reads sys.stdin reads an empty"
echo "  string. A hook shipped that way and never fired once."
result="$(scan "$ROOT")"
scanned="$(printf '%s' "$result" | head -1)"
offenders="$(printf '%s\n' "$result" | tail -n +2)"

if [ "${scanned:-0}" -gt 0 ]; then
  pass=$((pass + 1)); printf '  ok   the scan had a population to look at (%s files)\n' "$scanned"
else
  fail=$((fail + 1)); echo "  FAIL the scan found no shell scripts at all — it proved nothing"
fi

if [ -z "$offenders" ]; then
  pass=$((pass + 1)); echo "  ok   no script feeds python by heredoc and then reads stdin"
else
  fail=$((fail + 1))
  echo "  FAIL these scripts cannot see their payload — move the logic to a .py and exec it:"
  while IFS= read -r script; do printf '         %s\n' "$script"; done <<<"$offenders"
fi

echo
echo "  it is a change-detector: a planted offender must be caught, and a script that pipes"
echo "  its payload into 'python3 -c' must NOT be."
mkdir -p "$TMP/fixtures"
cat > "$TMP/fixtures/offender.sh" <<'FIXTURE'
#!/usr/bin/env bash
python3 - <<'PY'
import json, sys
json.load(sys.stdin)
PY
FIXTURE
cat > "$TMP/fixtures/innocent.sh" <<'FIXTURE'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" | python3 -c 'import json, sys; print(json.load(sys.stdin))'
python3 - <<'PY'
print("this heredoc never touches the payload")
PY
FIXTURE
caught="$(scan "$TMP/fixtures" | tail -n +2)"
if printf '%s' "$caught" | grep -q 'offender.sh'; then
  pass=$((pass + 1)); echo "  ok   a planted offender is detected"
else
  fail=$((fail + 1)); echo "  FAIL the detector missed a planted offender"
fi
if printf '%s' "$caught" | grep -q 'innocent.sh'; then
  fail=$((fail + 1)); echo "  FAIL the detector false-fired on a 'python3 -c' payload pipe"
else
  pass=$((pass + 1)); echo "  ok   a 'python3 -c' payload pipe is not flagged"
fi

echo
echo "EVERY ADAPTER MUST BE RUNNABLE AND READ STDIN:"
adapters=0
for adapter in "$ROOT"/adapters/hookjson/*.py; do
  case "$(basename "$adapter")" in hookio.py) continue ;; esac
  adapters=$((adapters + 1))
  if printf '{}' | env GUARDRAILS_STATE_DIR="$TMP/state" GUARDRAILS_BREVITY_FLUSH_WAIT=0.1 \
    "$PY" "$adapter" >/dev/null 2>"$TMP/err"; then
    pass=$((pass + 1)); printf '  ok   %-56s (exit 0)\n' "$(basename "$adapter") accepts a payload"
  else
    fail=$((fail + 1)); printf '  FAIL %s: %s\n' "$(basename "$adapter")" "$(cat "$TMP/err")"
  fi
done
if [ "$adapters" -ge 10 ]; then
  pass=$((pass + 1)); printf '  ok   all %d adapters were exercised\n' "$adapters"
else
  fail=$((fail + 1)); printf '  FAIL only %d adapters found — expected at least 10\n' "$adapters"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
