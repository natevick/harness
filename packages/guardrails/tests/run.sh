#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_STATE_DIR="$(mktemp -d)"
export GUARDRAILS_STATE_DIR
trap 'rm -rf "$GUARDRAILS_STATE_DIR"' EXIT

echo "Offline suite. The live harness probes are in tests/live/run.sh and are NOT run"
echo "from here: they spend tokens on real model turns."

total_pass=0
total_fail=0
files=0
broken=""

for test in "$HERE"/*_test.sh; do
  name="$(basename "$test")"
  files=$((files + 1))
  printf '\n=== %s ===\n' "$name"

  output="$(bash "$test" 2>&1)"
  status=$?
  printf '%s\n' "$output"

  summary="$(printf '%s\n' "$output" | grep -Eo '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [ -z "$summary" ]; then
    broken="$broken $name"
    total_fail=$((total_fail + 1))
    printf '!!! %s produced no pass/fail summary (exit %d) — treated as a failure\n' \
      "$name" "$status"
    continue
  fi

  passed="${summary%% passed*}"
  failed="${summary##*, }"
  failed="${failed%% failed}"
  total_pass=$((total_pass + passed))
  total_fail=$((total_fail + failed))

  if [ "$status" -ne 0 ] && [ "$failed" -eq 0 ]; then
    broken="$broken $name"
    total_fail=$((total_fail + 1))
    printf '!!! %s reported 0 failures but exited %d — treated as a failure\n' "$name" "$status"
  fi
done

printf '\n────────────────────────────────────────\n'
if [ "$files" -eq 0 ]; then
  echo "no test files found — the runner proved nothing"
  exit 1
fi

printf '%d test files, %d passed, %d failed\n' "$files" "$total_pass" "$total_fail"
[ -n "$broken" ] && printf 'files with no usable result:%s\n' "$broken"
[ "$total_fail" -eq 0 ]
