import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from guardrails.done import canonical_review


def sign_bytes(message, private_key):
    parent = tempfile.mkdtemp()
    try:
        message_path = os.path.join(parent, "msg")
        signature_path = os.path.join(parent, "sig")
        Path(message_path).write_bytes(message)
        subprocess.check_call(
            [
                "openssl", "pkeyutl", "-sign", "-inkey", private_key,
                "-rawin", "-in", message_path, "-out", signature_path,
            ],
            stdout=subprocess.DEVNULL,
        )
        return Path(signature_path).read_bytes().hex()
    finally:
        for name in ("msg", "sig"):
            path = os.path.join(parent, name)
            if os.path.isfile(path):
                os.remove(path)
        os.rmdir(parent)


def write_review(spec, reviewer, private_key, verdict):
    ok = verdict == "pass"
    document = {
        "gaps": [] if ok else ["final state is not observable"],
        "observable": ok,
        "testable": ok,
        "scoped": ok,
        "stopping_point": ok,
        "spec_sha256": hashlib.sha256(Path(spec).read_bytes()).hexdigest(),
        "reviewer": reviewer,
    }
    document["signature"] = sign_bytes(canonical_review(document), private_key)
    Path(os.path.splitext(spec)[0] + ".review.json").write_text(json.dumps(document))
    return document["spec_sha256"]


def write_unsigned_review(spec):
    document = {
        "gaps": [],
        "observable": True,
        "testable": True,
        "scoped": True,
        "stopping_point": True,
        "spec_sha256": hashlib.sha256(Path(spec).read_bytes()).hexdigest(),
    }
    Path(os.path.splitext(spec)[0] + ".review.json").write_text(json.dumps(document))


def write_trust(path, reviewer, public_pem_path):
    pem = Path(public_pem_path).read_text()
    Path(path).write_text(json.dumps({reviewer: pem}))


def main(argv):
    if len(argv) == 3 and argv[1] == "--unsigned":
        write_unsigned_review(argv[2])
        return 0
    if len(argv) >= 2 and argv[1] == "--trust":
        if len(argv) != 5:
            print("usage: review_sign.py --trust <path> <public-pem> <reviewer>", file=sys.stderr)
            return 2
        write_trust(argv[2], argv[4], argv[3])
        return 0
    if len(argv) != 5:
        print("usage: review_sign.py <spec> <reviewer> <private-key> <pass|fail>", file=sys.stderr)
        return 2
    write_review(argv[1], argv[2], argv[3], argv[4])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
