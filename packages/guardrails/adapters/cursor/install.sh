#!/usr/bin/env bash
# Register the Cursor adapter. Prints the snippet, or merges it into hooks.json.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

target=""
force=0
portable=0

usage() {
  cat <<USAGE
usage: install.sh --harness cursor [--target <path>] [--force] [--portable]

  --target    .cursor/hooks.json or ~/.cursor/hooks.json. Omit to print the snippet.
  --force     required to modify a file that already exists.
  --portable  point commands at \${HARNESS_ROOT:-\$HOME/.harness/src} instead of
              this checkout. Commit that file; clone harness to that path on the VM.

Project hooks (.cursor/hooks.json) run from the repo root and are what Cursor
cloud agents load. User hooks (~/.cursor/hooks.json) apply to the desktop app;
a cloud agent VM does not load them.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --harness)
      if [ "${2:-}" != "cursor" ]; then
        printf 'this installer only wires cursor (got %s)\n' "${2:-}" >&2
        exit 2
      fi
      shift 2
      ;;
    --target) target="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    --portable) portable=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

snippet="$here/install/cursor.json"
if [ ! -f "$snippet" ]; then
  printf 'missing registration template: %s\n' "$snippet" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is not on PATH; the guards cannot run. Install Python 3.10 or newer.\n' >&2
  exit 1
fi
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  printf 'python3 is %s; the guards need 3.10 or newer.\n' \
    "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" >&2
  exit 1
fi

python3 - "$snippet" "$root" "$target" "$force" "$portable" <<'PY'
import json
import re
import shlex
import shutil
import sys
from pathlib import Path

snippet_path, root, target, force, portable = sys.argv[1:6]
if portable == "1":
    root_ref = "${HARNESS_ROOT:-$HOME/.harness/src}/packages/guardrails"
else:
    root_ref = shlex.quote(root)
body = Path(snippet_path).read_text().replace("{{GUARDRAILS}}", root_ref)
snippet = json.loads(body)

SCRIPT = re.compile(r"([A-Za-z0-9_]+\.py)")


def script_of(command):
    found = SCRIPT.findall(command or "")
    return found[-1] if found else None


ours = {
    script_of(hook.get("command"))
    for hooks in snippet["hooks"].values()
    for hook in hooks
}

if not target:
    print(body, end="" if body.endswith("\n") else "\n")
    raise SystemExit(0)

def looks_claude(settings):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return False
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if isinstance(group, dict) and "hooks" in group:
                return True
    return False


destination = Path(target)
if destination.exists() and force != "1":
    print("%s already exists; pass --force to modify it" % destination, file=sys.stderr)
    raise SystemExit(3)

destination.parent.mkdir(parents=True, exist_ok=True)
settings = {"version": 1, "hooks": {}}
if destination.exists():
    shutil.copyfile(destination, destination.with_suffix(destination.suffix + ".bak"))
    settings = json.loads(destination.read_text() or "{}")
    if looks_claude(settings):
        print(
            "%s is Claude-shaped settings, not Cursor hooks.json; refusing to merge" % destination,
            file=sys.stderr,
        )
        raise SystemExit(4)

settings.setdefault("version", 1)
hooks = settings.setdefault("hooks", {})
installed = 0
for event, entries in snippet["hooks"].items():
    existing = hooks.setdefault(event, [])
    kept = [
        hook for hook in existing
        if script_of(hook.get("command")) not in ours
    ]
    kept.extend(entries)
    hooks[event] = kept
    installed += len(entries)

destination.write_text(json.dumps(settings, indent=2) + "\n")
print("%s: %d hook entries installed" % (destination, installed))
PY
