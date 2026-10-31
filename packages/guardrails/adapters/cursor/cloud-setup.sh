#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/../.." && pwd)"
repo="${1:-${CURSOR_PROJECT_DIR:-}}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "$repo" ]; then
  cat <<USAGE
usage: cloud-setup.sh <repo-dir>

Checks the committed portable .cursor/hooks.json, then fail-closes unless the
hook scripts deny a protected write and a done claim. Clone harness to
\$HOME/.harness/src first. If hooks.json is missing and the exec daemon is
already running, this exits 1 and does not write the file.
USAGE
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    exit 0
  fi
  exit 2
fi

hooks="$repo/.cursor/hooks.json"

daemon_running() {
  ps -eo args= 2>/dev/null | grep -q '[e]xec-daemon/index.js serve'
}

if [ ! -f "$hooks" ]; then
  if daemon_running; then
    printf '%s\n' "hooks will not load until the daemon restarts" >&2
    exit 1
  fi
  "$package/install.sh" --harness cursor --portable --force --target "$hooks"
fi

python3 - "$hooks" "$repo" <<'PY'
import json, os, subprocess, sys, tempfile
from pathlib import Path

hooks_path, repo = sys.argv[1:]
if sys.version_info < (3, 10):
    raise SystemExit("python >= 3.10 is required")

parent = tempfile.mkdtemp(prefix="hook-selftest-")
key = os.path.join(parent, "k.pem")
message = os.path.join(parent, "m")
signature = os.path.join(parent, "s")
Path(message).write_bytes(b"x")
signed = subprocess.run(
    ["openssl", "genpkey", "-algorithm", "ED25519", "-out", key],
    capture_output=True,
)
if signed.returncode != 0:
    raise SystemExit("openssl genpkey failed")
raw = subprocess.run(
    ["openssl", "pkeyutl", "-sign", "-inkey", key, "-rawin", "-in", message, "-out", signature],
    capture_output=True,
)
if raw.returncode != 0:
    raise SystemExit("openssl pkeyutl -rawin failed")

trust = "/etc/harness/reviewers.json"
if not os.path.isfile(trust):
    raise SystemExit("trust store missing at %s" % trust)
uid = os.geteuid()
current = trust
seen = set()
while current and current not in seen:
    seen.add(current)
    info = os.stat(current)
    if info.st_uid == uid or os.access(current, os.W_OK):
        raise SystemExit("trust store is writable by this user")
    parent_dir = os.path.dirname(current)
    if parent_dir == current:
        break
    current = parent_dir

settings = json.loads(Path(hooks_path).read_text())
commands = []
for entries in (settings.get("hooks") or {}).values():
    for entry in entries:
        command = entry.get("command")
        if command and command not in commands:
            commands.append(command)
if not commands:
    raise SystemExit("hooks.json has no commands")

state = tempfile.mkdtemp(prefix="hook-live-")
os.makedirs(state, mode=0o700, exist_ok=True)
Path(os.path.join(state, "hook-live")).write_text("1")
spec_dir = tempfile.mkdtemp(prefix="hook-spec-")
Path(os.path.join(spec_dir, "done-means.json")).write_text(json.dumps({
    "task": "value",
    "done": "false exits 0",
    "checks": [{"id": "unit", "run": "false", "sabotage": False}],
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

env = dict(os.environ)
env["GUARDRAILS_STATE_DIR"] = state
saw_done = False
for command in commands:
    completed = subprocess.run(
        command, shell=True, input=write_event, capture_output=True, text=True, env=env,
    )
    if completed.returncode != 0:
        raise SystemExit("hook command failed: %s" % command)
    if "done_means_guard.py" in command:
        saw_done = True
        if '"permission": "deny"' not in completed.stdout and '"permission":"deny"' not in completed.stdout:
            raise SystemExit("done_means_guard allowed a write to .cursor/hooks.json")
        stopped = subprocess.run(
            command, shell=True, input=stop_event, capture_output=True, text=True, env=env,
        )
        if stopped.returncode != 0 or "followup_message" not in stopped.stdout:
            raise SystemExit("done_means_guard allowed a done claim against a failing spec")
if not saw_done:
    raise SystemExit("hooks.json does not register done_means_guard.py")
PY
