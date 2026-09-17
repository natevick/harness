#!/usr/bin/env bash
# Stage the factory playbook templates. Never auto-edits CLAUDE.md / settings —
# that is the operator's call (provenance).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target="${HARNESS_DISCIPLINE_HOME:-$HOME/.harness/discipline}"
force=0

usage() {
  cat <<USAGE
usage: install.sh [--target <dir>] [--force]

  Copies docs/ and templates/ into a local discipline home so the playbook
  is one path away. Does NOT edit CLAUDE.md, settings.json, or hooks/.

  --target  destination (default: \$HARNESS_DISCIPLINE_HOME or ~/.harness/discipline)
  --force   replace an existing destination

After install, open docs/doctrine.md and docs/playbook.md, then copy a stub
from templates/ when a correction repeats. Scheduled collectors propose only.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -e "$target" ] && [ "$force" -ne 1 ]; then
  printf '%s already exists; pass --force to replace it\n' "$target" >&2
  exit 3
fi

mkdir -p "$target"
rm -rf "$target/docs" "$target/templates"
cp -R "$here/docs" "$target/docs"
cp -R "$here/templates" "$target/templates"
cp "$here/README.md" "$target/README.md"

cat <<MSG
discipline staged at $target

Next (manual — do not skip):
  1. Read $target/docs/doctrine.md
  2. Walk $target/docs/playbook.md the next time a correction repeats
  3. Copy a stub from $target/templates/ and register it yourself
  4. Optionally paste the doctrine bullet into your agent instructions — you approve that edit

Collectors under docs/audit-retro.md propose into reviews/; they never install.
MSG
