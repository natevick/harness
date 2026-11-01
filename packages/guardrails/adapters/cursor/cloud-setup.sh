#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/../.." && pwd)"
repo_root="$(cd "$package/../.." && pwd)"
repo="${1:-${CURSOR_PROJECT_DIR:-}}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "$repo" ]; then
  printf '%s\n' "usage: cloud-setup.sh <repo-dir>"
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    exit 0
  fi
  exit 2
fi

source_root="${HARNESS_ROOT:-$repo_root}"
hooks="$repo/.cursor/hooks.json"
install_root="/opt/harness"

daemon_running() {
  ps -eo args= 2>/dev/null | grep -q '[e]xec-daemon/index.js serve'
}

if [ ! -f "$hooks" ]; then
  if daemon_running; then
    printf '%s\n' "hooks will not load until the daemon restarts" >&2
    exit 1
  fi
fi

advisory=0
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
  advisory=1
  printf '%s\n' "WARNING: this host is local-advisory. The agent is root or has passwordless sudo, so on-box ownership is not a trust anchor. gate/review-signature in CI is the binding check." >&2
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p /etc/harness
    printf '%s\n' local-advisory > /etc/harness/host-mode
  else
    sudo mkdir -p /etc/harness
    printf '%s\n' local-advisory | sudo tee /etc/harness/host-mode >/dev/null
  fi
fi

if sudo -n true 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
  if [ "$(id -u)" -eq 0 ]; then
    rm -rf "$install_root"
    mkdir -p "$install_root"
    cp -a "$source_root/." "$install_root/"
    chown -R root:root "$install_root"
    find "$install_root" -type d -exec chmod 755 {} \;
    find "$install_root" -type f -exec chmod 644 {} \;
  else
    sudo rm -rf "$install_root"
    sudo mkdir -p "$install_root"
    sudo cp -a "$source_root/." "$install_root/"
    sudo chown -R root:root "$install_root"
    sudo find "$install_root" -type d -exec chmod 755 {} \;
    sudo find "$install_root" -type f -exec chmod 644 {} \;
  fi
  run_root="$install_root"
else
  run_root="$source_root"
fi

mkdir -p "$repo/.cursor"
python3 - "$package/adapters/cursor/install/cursor.json" "$run_root" "$hooks" <<'PY'
import json, sys
from pathlib import Path
snippet, root, dest = sys.argv[1:]
body = Path(snippet).read_text().replace(
    "{{GUARDRAILS}}", "%s/packages/guardrails" % root
)
Path(dest).write_text(json.dumps(json.loads(body), indent=2) + "\n")
PY

python3 - "$hooks" "$repo" "$run_root" "$advisory" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[3], "packages", "guardrails"))
from guardrails.done import trust_writable
hooks, repo, run_root, advisory = sys.argv[1:]
advisory = advisory == "1"
if not advisory:
    for path in (run_root, sys.prefix):
        if trust_writable(path):
            print(
                "WARNING: harness install is writable by this user: %s. "
                "Local hooks are advisory. gate/review-signature is the binding check." % path,
                file=sys.stderr,
            )
trust = "/etc/harness/reviewers.json"
if not os.path.isfile(trust) or trust_writable(trust):
    raise SystemExit("trust store missing or writable at %s" % trust)
import json, subprocess, tempfile
from pathlib import Path
settings = json.loads(Path(hooks).read_text())
commands = []
for entries in (settings.get("hooks") or {}).values():
    for entry in entries:
        command = entry.get("command") or ""
        if "python3 -s -E" not in command:
            raise SystemExit("hook command is not python3 -s -E: %s" % command)
        if command not in commands:
            commands.append(command)
state = tempfile.mkdtemp(prefix="hook-live-")
os.makedirs(state, mode=0o700, exist_ok=True)
spec_dir = tempfile.mkdtemp(prefix="hook-spec-")
Path(os.path.join(spec_dir, "done-means.json")).write_text(json.dumps({
    "task": "value",
    "done": "false exits 0",
    "base": "0123456789abcdef0123456789abcdef01234567",
    "checks": [{"id": "unit", "run": "false", "sabotage": False, "reason": "the command does not read the diff"}],
}))
write_event = json.dumps({
    "hook_event_name": "preToolUse",
    "tool_name": "Write",
    "session_id": "selftest",
    "cwd": repo,
    "tool_input": {"file_path": os.path.join(repo, ".cursor", "hooks.json"), "content": "{}\n"},
})
stop_event = json.dumps({
    "hook_event_name": "stop",
    "status": "completed",
    "session_id": "selftest",
    "cwd": spec_dir,
    "text": "The task is done.",
})
os.environ["GUARDRAILS_STATE_DIR"] = state
os.environ["GUARDRAILS_SESSION"] = "selftest"
env = dict(os.environ)
from guardrails.live import note_hook
note_hook("selftest")
saw = False
for command in commands:
    completed = subprocess.run(command, shell=True, input=write_event, capture_output=True, text=True, env=env)
    if completed.returncode != 0:
        raise SystemExit("hook command failed: %s" % command)
    if "done_means_guard.py" in command:
        saw = True
        if "deny" not in completed.stdout:
            raise SystemExit("done_means_guard allowed a write to .cursor/hooks.json")
        stopped = subprocess.run(command, shell=True, input=stop_event, capture_output=True, text=True, env=env)
        if stopped.returncode not in (0, 2) or "DONE-MEANS" not in (stopped.stdout + stopped.stderr):
            raise SystemExit("done_means_guard allowed a done claim against a failing spec")
if not saw:
    raise SystemExit("hooks.json does not register done_means_guard.py")
PY
