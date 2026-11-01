#!/usr/bin/env bash
set -euo pipefail

repo="${1:-.}"
base_ref="${2:-}"
prefix="$repo/packages/guardrails"

if [ -n "$base_ref" ]; then
  git -C "$repo" fetch origin "$base_ref"
fi

if [ -n "$base_ref" ] && git -C "$repo" cat-file -e "origin/${base_ref}:packages/guardrails/package-lock.json" 2>/dev/null; then
  dest="$(mktemp -d)"
  git -C "$repo" archive "origin/${base_ref}" packages/guardrails/package.json packages/guardrails/package-lock.json | tar -x -C "$dest"
  npm ci --ignore-scripts --prefix "$dest/packages/guardrails"
  rm -rf "$prefix/node_modules"
  mkdir -p "$prefix"
  mv "$dest/packages/guardrails/node_modules" "$prefix/node_modules"
else
  npm ci --ignore-scripts --prefix "$prefix"
fi
