#!/usr/bin/env bash
# Install harness packages. Guardrails by default; discipline and bench opt-in.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

harness=""
target=""
force=0
with_discipline=0
with_bench=0
skip_guardrails=0

usage() {
  cat <<USAGE
usage: install.sh --harness <name> [options]

Install what people can run today (guardrails hooks), optionally stage the
factory playbook and check bench deps.

  --harness <name>     claude-code | codex | kimi | grok   (required unless --skip-guardrails)
  --target <path>      config file for guardrails (omit = print snippet only)
  --force              overwrite existing guardrails config / discipline home
  --with-discipline    stage packages/discipline templates under ~/.harness/discipline
  --with-bench         verify bench deps and print how to run
  --skip-guardrails    only run the opt-in packages (still need those flags)
  --all                shorthand: guardrails + discipline + bench

Examples:
  ./install.sh --harness claude-code --target ~/.claude/settings.json --force
  ./install.sh --harness claude-code --all --force
  ./packages/guardrails/install.sh --harness codex --target .codex/hooks.json --force
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) harness="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    --with-discipline) with_discipline=1; shift ;;
    --with-bench) with_bench=1; shift ;;
    --skip-guardrails) skip_guardrails=1; shift ;;
    --all) with_discipline=1; with_bench=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$skip_guardrails" -eq 0 ] && [ -z "$harness" ]; then
  usage >&2
  exit 2
fi

if [ "$skip_guardrails" -eq 0 ]; then
  args=(--harness "$harness")
  [ -n "$target" ] && args+=(--target "$target")
  [ "$force" -eq 1 ] && args+=(--force)
  printf '==> packages/guardrails\n'
  "$root/packages/guardrails/install.sh" "${args[@]}"
fi

if [ "$with_discipline" -eq 1 ]; then
  printf '==> packages/discipline\n'
  dargs=()
  [ "$force" -eq 1 ] && dargs+=(--force)
  "$root/packages/discipline/install.sh" "${dargs[@]+"${dargs[@]}"}"
fi

if [ "$with_bench" -eq 1 ]; then
  printf '==> packages/bench\n'
  "$root/packages/bench/install.sh"
fi

printf '\nDone. Package READMEs have receipts and caveats.\n'
