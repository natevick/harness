#!/usr/bin/env bash
# Wire this checkout's Cursor adapter into a repo's .cursor/hooks.json.
#
# Cursor cloud agents load project hooks when the exec daemon starts. Run this
# from the environment install step, after cloning harness, and before an agent
# turn. A hooks.json written after the daemon is up does not fire until the
# daemon is reloaded.
#
#   git clone --depth 1 https://github.com/natevick/harness.git "$HOME/.harness/src"
#   "$HOME/.harness/src/packages/guardrails/adapters/cursor/cloud-setup.sh" "$REPO"
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/../.." && pwd)"
repo="${1:-${CURSOR_PROJECT_DIR:-}}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "$repo" ]; then
  cat <<USAGE
usage: cloud-setup.sh <repo-dir>

Writes <repo-dir>/.cursor/hooks.json pointing at this harness checkout.
Clone harness first (see the comment at the top of this file). User-level
~/.cursor/hooks.json is not loaded by cloud agents.
USAGE
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    exit 0
  fi
  exit 2
fi

"$package/install.sh" --harness cursor --force --target "$repo/.cursor/hooks.json"
