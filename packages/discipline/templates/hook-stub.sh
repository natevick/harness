#!/usr/bin/env bash
# Hook stub — rename and wire into agent settings after two failures (or one severe).
# Exit 0 = allow; non-zero = block (semantics depend on your agent adapter).
set -euo pipefail

EVENT="${1:-unknown}"
PAYLOAD_FILE="${2:-/dev/stdin}"

# Read payload as DATA. Never eval it.
payload="$(cat "$PAYLOAD_FILE" 2>/dev/null || true)"

# TODO: match the failure mode this hook exists to stop.
# Example: refuse a dangerous pattern in the tool command field.
if printf '%s' "$payload" | grep -Eq 'REPLACE_WITH_FAILURE_PATTERN'; then
  echo "discipline-hook: blocked by $(basename "$0") on event=${EVENT}" >&2
  exit 2
fi

exit 0
