import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from guardrails.done import canonical_review, signature_ok


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
        ["openssl", "pkeyutl", "-sign", "-inkey", private_key, "-rawin", "-in", message_path, "-out", signature_path],
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


def verify_repo():
    secret = os.environ.get("HARNESS_REVIEWERS_JSON") or ""
    if not secret.strip():
        print(
            "HARNESS_REVIEWERS_JSON secret is required. "
            "On a VM where the agent has root, only this CI identity can verify the review."
        )
        return 1
    try:
        trust = json.loads(secret)
    except ValueError:
        print("HARNESS_REVIEWERS_JSON is not JSON")
        return 1
    root = Path(__file__).resolve().parents[2]
    review_path = root / "done-means.review.json"
    if not review_path.is_file():
        print("no done-means.review.json at %s" % review_path)
        return 1
    data = json.loads(review_path.read_text())
    reviewer = data.get("reviewer")
    signature = data.get("signature")
    if not isinstance(reviewer, str) or not isinstance(signature, str):
        print("done-means.review.json has no reviewer signature")
        return 1
    pem = trust.get(reviewer) if isinstance(trust, dict) else None
    if not isinstance(pem, str) or not signature_ok(pem, canonical_review(data), signature):
        print("done-means.review.json signature is not valid for the CI trust store")
        return 1
    return 0


def main(argv):
    failed = self_test()
    if "--self-test" in argv:
        return failed
    if failed:
        return failed
    return verify_repo()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
