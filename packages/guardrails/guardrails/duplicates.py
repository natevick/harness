import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

MESSAGE = (
    "duplicate logic: %s:%d-%d and %s:%d-%d are the same block.\n"
    "Extract one shared helper."
)

MARKER = re.compile(r"duplicate-ok:\s*\S")


def jscpd_invocation():
    override = os.environ.get("JSCPD")
    if override:
        return [override]
    root = Path(__file__).resolve().parent.parent / "node_modules"
    script = root / "jscpd" / "run-jscpd.js"
    if script.is_file():
        for binary in root.glob("jscpd-*/bin/jscpd"):
            mode = binary.stat().st_mode
            if not mode & 0o111:
                os.chmod(binary, mode | 0o755)
        return ["node", str(script)]
    local = root / ".bin" / "jscpd"
    if local.exists():
        return [str(local)]
    found = shutil.which("jscpd")
    if found:
        return [found]
    return None


def marked(path, start, end):
    try:
        rows = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return False
    first = max(1, start - 1)
    last = min(len(rows), end)
    for line in rows[first - 1:last]:
        if MARKER.search(line):
            return True
    return False


def format_clone(clone, root):
    first = clone["firstFile"]
    second = clone["secondFile"]
    left = first["name"]
    right = second["name"]
    if marked(os.path.join(root, left), first["start"], first["end"]) and marked(
        os.path.join(root, right), second["start"], second["end"]
    ):
        return None
    return MESSAGE % (
        left, first["start"], first["end"],
        right, second["start"], second["end"],
    )


def run_jscpd(root, min_lines, min_tokens, baseline, ignore, update_baseline):
    invocation = jscpd_invocation()
    if not invocation:
        return None, (
            "jscpd is not installed. From the repo root run: "
            "npm install --prefix packages/guardrails"
        )
    output = tempfile.mkdtemp(prefix="jscpd-")
    command = invocation + [
        "--min-lines", str(min_lines),
        "--min-tokens", str(min_tokens),
        "--reporters", "json",
        "--output", output,
        "--silent",
        "--no-colors",
        "--no-gitignore",
    ]
    if ignore:
        command.extend(["--ignore", ",".join(ignore)])
    if baseline:
        command.extend(["--baseline", os.path.abspath(baseline)])
        if update_baseline:
            command.append("--update-baseline")
        else:
            command.append("--fail-on-new-clones=0")
    command.append(".")
    try:
        completed = subprocess.run(
            command,
            cwd=root,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        shutil.rmtree(output, ignore_errors=True)
        return None, "jscpd failed to start: %s" % error
    report = os.path.join(output, "jscpd-report.json")
    if not os.path.isfile(report):
        detail = (completed.stderr or completed.stdout or "no report").strip()
        shutil.rmtree(output, ignore_errors=True)
        return None, "jscpd produced no report (exit %s): %s" % (completed.returncode, detail)
    try:
        data = json.loads(Path(report).read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        shutil.rmtree(output, ignore_errors=True)
        return None, "jscpd report is not JSON: %s" % error
    shutil.rmtree(output, ignore_errors=True)
    if completed.returncode not in (0, 1):
        detail = (completed.stderr or completed.stdout or "").strip()
        return None, "jscpd exited %s: %s" % (completed.returncode, detail)
    clones = data.get("duplicates") or []
    if baseline and not update_baseline:
        clones = [clone for clone in clones if clone.get("isNew")]
    return clones, ""


def scan(root, min_lines, min_tokens, baseline=None, ignore=None, update_baseline=False):
    root = os.path.abspath(root)
    clones, error = run_jscpd(
        root, min_lines, min_tokens, baseline, ignore or [], update_baseline
    )
    if error:
        return None, error
    messages = []
    for clone in clones:
        text = format_clone(clone, root)
        if text:
            messages.append(text)
    return messages, ""
