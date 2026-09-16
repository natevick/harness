#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

harness=""
target=""
force=0

usage() {
  cat <<USAGE
usage: install.sh --harness <name> [--target <path>] [--force]

  --harness  claude-code | codex | kimi | grok
  --target   the config file to write. Omit it and the snippet is printed instead.
  --force    required to modify a file that already exists.

Default locations, all project scope:
  claude-code  <repo>/.claude/settings.local.json   (or ~/.claude/settings.json)
  codex        <repo>/.codex/hooks.json
  grok         <repo>/.grok/hooks/guardrails.json
  kimi         \$KIMI_CODE_HOME/config.toml, user scope only
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) harness="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$harness" ]; then
  usage >&2
  exit 2
fi

case "$harness" in
  claude-code|codex|grok) snippet="$here/install/$harness.json" ;;
  kimi) snippet="$here/install/kimi.toml" ;;
  *) printf 'unknown harness: %s\n' "$harness" >&2; exit 2 ;;
esac

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

python3 - "$snippet" "$root" "$target" "$force" <<'PY'
import json
import re
import shlex
import shutil
import sys
from pathlib import Path

snippet_path, root, target, force = sys.argv[1:5]
quoted = json.dumps(shlex.quote(root))[1:-1]
body = Path(snippet_path).read_text().replace("{{GUARDRAILS}}", quoted)

SCRIPT = re.compile(r"([A-Za-z0-9_]+\.py)")


def script_of(command):
    found = SCRIPT.findall(command or "")
    return found[-1] if found else None


if not target:
    print(body, end="" if body.endswith("\n") else "\n")
    raise SystemExit(0)

destination = Path(target)
if destination.exists() and force != "1":
    print("%s already exists; pass --force to modify it" % destination, file=sys.stderr)
    raise SystemExit(3)

destination.parent.mkdir(parents=True, exist_ok=True)

if snippet_path.endswith(".toml"):
    existing = destination.read_text() if destination.exists() else ""
    kept, current = [], []
    for line in existing.split("\n"):
        if line.strip() == "[[hooks]]" and current:
            kept.append(current)
            current = []
        current.append(line)
    if current:
        kept.append(current)

    wanted = [block for block in body.split("[[hooks]]\n") if block.strip()]
    names = {script_of(block) for block in wanted}
    survivors = [
        "\n".join(block) for block in kept
        if script_of("\n".join(block)) not in names
    ]
    if destination.exists():
        shutil.copyfile(destination, destination.with_suffix(destination.suffix + ".bak"))
    rendered = "\n".join(survivors).rstrip("\n")
    if rendered:
        rendered += "\n\n"
    rendered += "".join("[[hooks]]\n" + block for block in wanted)
    destination.write_text(rendered)
    print("%s: %d hook entries installed" % (destination, len(wanted)))
    raise SystemExit(0)

entries = json.loads(body)["hooks"]
settings = {}
if destination.exists():
    shutil.copyfile(destination, destination.with_suffix(destination.suffix + ".bak"))
    settings = json.loads(destination.read_text() or "{}")

hooks = settings.setdefault("hooks", {})
ours = {
    script_of(hook.get("command"))
    for groups in entries.values()
    for group in groups
    for hook in group["hooks"]
}

installed = 0
for event, groups in entries.items():
    existing = hooks.setdefault(event, [])
    for group in existing:
        group["hooks"] = [
            hook for hook in group.get("hooks", [])
            if script_of(hook.get("command")) not in ours
        ]
    for group in groups:
        match = next(
            (g for g in existing if g.get("matcher", "") == group.get("matcher", "")), None
        )
        if match is None:
            existing.append({"matcher": group.get("matcher", ""), "hooks": list(group["hooks"])})
        else:
            match.setdefault("hooks", []).extend(group["hooks"])
        installed += len(group["hooks"])
    hooks[event] = [group for group in existing if group.get("hooks")]

destination.write_text(json.dumps(settings, indent=2) + "\n")
print("%s: %d hook entries installed" % (destination, installed))
PY
