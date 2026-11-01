import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from guardrails.done import canonical_review, main, signature_ok


def self_test():
    parent = tempfile.mkdtemp(prefix="ci-review-")
    private_key = os.path.join(parent, "k.pem")
    public_key = os.path.join(parent, "p.pem")
    made = subprocess.run(
        ["openssl", "genpkey", "-algorithm", "ED25519", "-out", private_key],
        capture_output=True,
    )
    if made.returncode != 0:
        print("openssl genpkey failed")
        return 1
    published = subprocess.run(
        ["openssl", "pkey", "-in", private_key, "-pubout", "-out", public_key],
        capture_output=True,
    )
    if published.returncode != 0:
        print("openssl pkey failed")
        return 1
    document = {
        "gaps": [],
        "observable": True,
        "reviewer": "ci@example.com",
        "scoped": True,
        "spec_sha256": "abc",
        "stopping_point": True,
        "testable": True,
    }
    message = canonical_review(document)
    message_path = os.path.join(parent, "m")
    signature_path = os.path.join(parent, "s")
    Path(message_path).write_bytes(message)
    signed = subprocess.run(
        [
            "openssl", "pkeyutl", "-sign", "-inkey", private_key,
            "-rawin", "-in", message_path, "-out", signature_path,
        ],
        capture_output=True,
    )
    if signed.returncode != 0:
        print("openssl sign failed")
        return 1
    signature = Path(signature_path).read_bytes().hex()
    pem = Path(public_key).read_text()
    if not signature_ok(pem, message, signature):
        print("self-test did not verify a canonical signature")
        return 1
    flipped = dict(document)
    flipped["observable"] = False
    if signature_ok(pem, canonical_review(flipped), signature):
        print("self-test accepted a signature over a changed review")
        return 1
    return 0


def verify_worktree(worktree, trust_json, base_ref=""):
    if not (trust_json or "").strip():
        print(
            "HARNESS_REVIEWERS_JSON secret is required. "
            "On a host where the agent is root or has passwordless sudo, this CI identity is the binding check."
        )
        return 1
    spec = os.path.join(worktree, "done-means.json")
    if not os.path.isfile(spec):
        print("done-means spec is missing at %s" % spec)
        return 1
    parent = tempfile.mkdtemp(prefix="ci-trust-")
    trust_path = os.path.join(parent, "reviewers.json")
    Path(trust_path).write_text(trust_json)
    return main(
        ["done_means.py", "run", spec],
        trust=trust_path,
        enforce_ownership=False,
        require_live=False,
        ci_base_ref=base_ref or "",
    )


def main_cli(argv):
    if "--self-test" in argv:
        return self_test()
    worktree = os.getcwd()
    base_ref = ""
    args = argv[1:]
    index = 0
    while index < len(args):
        if args[index] == "--worktree" and index + 1 < len(args):
            worktree = args[index + 1]
            index += 2
            continue
        if args[index] == "--base-ref" and index + 1 < len(args):
            base_ref = args[index + 1]
            index += 2
            continue
        index += 1
    failed = self_test()
    if failed:
        return failed
    return verify_worktree(worktree, os.environ.get("HARNESS_REVIEWERS_JSON") or "", base_ref)


if __name__ == "__main__":
    sys.exit(main_cli(sys.argv))
