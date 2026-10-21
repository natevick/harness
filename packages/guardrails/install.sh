#!/usr/bin/env bash
# Install harvested hooks into a coding-agent harness.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

harness=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--harness" ]; then
    harness="$arg"
  fi
  prev="$arg"
done

case "$harness" in
  cursor) exec "$here/adapters/cursor/install.sh" "$@" ;;
  *) exec "$here/adapters/hookjson/install.sh" "$@" ;;
esac
