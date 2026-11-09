import os
import subprocess
import sys


def ensure_base(repo):
    pinned = os.environ.get("SPEC_BASE", "").strip()
    if pinned:
        return pinned
    head = subprocess.run(
        ["git", "-C", repo, "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
    )
    if head.returncode != 0:
        subprocess.check_call(["git", "-C", repo, "init", "-q"])
        subprocess.check_call(["git", "-C", repo, "config", "user.email", "t@example.com"])
        subprocess.check_call(["git", "-C", repo, "config", "user.name", "t"])
        subprocess.check_call(["git", "-C", repo, "commit", "-q", "--allow-empty", "-m", "base"])
        head = subprocess.run(
            ["git", "-C", repo, "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
        )
    return head.stdout.strip()


if __name__ == "__main__":
    print(ensure_base(sys.argv[1]))
