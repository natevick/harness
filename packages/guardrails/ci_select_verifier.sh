#!/usr/bin/env bash
set -euo pipefail

worktree="${1:-.}"
base_ref="${2:-}"
default_branch="${3:-}"
own="$worktree/packages/guardrails/ci_verify_review.py"

if [ -z "$base_ref" ]; then
  printf '%s\n' "$own"
  exit 0
fi

git -C "$worktree" fetch origin "$base_ref"

if git -C "$worktree" cat-file -e "origin/${base_ref}:packages/guardrails/ci_verify_review.py" 2>/dev/null; then
  dest="$(mktemp -d)"
  git -C "$worktree" archive "origin/${base_ref}" packages/guardrails | tar -x -C "$dest"
  printf '%s\n' "$dest/packages/guardrails/ci_verify_review.py"
  exit 0
fi

if [ -n "$default_branch" ] && [ "$base_ref" = "$default_branch" ]; then
  printf 'bootstrap: origin/%s has no verifier yet; using this worktree'\''s copy\n' "$base_ref" >&2
  printf '%s\n' "$own"
  exit 0
fi

printf 'refusing to verify with this pull request'\''s copy; origin/%s has no verifier\n' "$base_ref" >&2
exit 1
