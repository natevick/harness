#!/usr/bin/env bash
# Check deps for the harness differential bench. Does not wire agent hooks.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<USAGE
usage: install.sh

  Verifies python3 and node are available, then prints how to run the bench.
  Credentials stay in your REAL_HOME; setup-jails.sh only symlinks them.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

missing=0
if ! command -v python3 >/dev/null 2>&1; then
  printf 'missing: python3\n' >&2
  missing=1
fi
if ! command -v node >/dev/null 2>&1; then
  printf 'missing: node (for differential.mjs)\n' >&2
  missing=1
fi
if [ "$missing" -ne 0 ]; then
  exit 1
fi

printf 'bench deps OK (python3 %s, node %s)\n' \
  "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" \
  "$(node -v)"

cat <<MSG

From $here:

  # optional: point jails at a non-default home
  REAL_HOME=\$HOME ./setup-jails.sh
  ./setup-runs.sh
  # then run seats / score — see README.md and REPORT.md

Read REPORT.md before comparing harness token counts (cache reads vs fresh input).
MSG
