#!/usr/bin/env bash
# Give each seat a pristine, independent copy of the fixture as a git repo, so
# afterwards `git diff` shows exactly what that seat changed (and proves whether
# it touched test/).
set -euo pipefail

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEATS=(claude claude-cfg codex grok)

for seat in "${SEATS[@]}"; do
  dest="$BENCH/runs/$seat"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -r "$BENCH/fixture/." "$dest/"
  git -C "$dest" init -q
  git -C "$dest" add -A
  git -C "$dest" -c user.email=bench@local -c user.name=bench commit -qm "fixture: pricing engine with failing suite"
  # node --test exits non-zero while the suite is still red; that is expected here.
  failing=$( (cd "$dest" && node --test 2>&1 || true) | grep -E '^# fail ' | awk '{print $3}')
  echo "$seat: seeded, $failing failing tests, HEAD=$(git -C "$dest" rev-parse --short HEAD)"
done
