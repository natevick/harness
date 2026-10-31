import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def sign(spec, reviewer, private_key):
    digest = hashlib.sha256(Path(spec).read_bytes()).hexdigest()
    message = ("%s\n%s\n" % (digest, reviewer)).encode()
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
        return digest, Path(signature_path).read_bytes().hex()
    finally:
        for name in ("msg", "sig"):
            path = os.path.join(parent, name)
            if os.path.isfile(path):
                os.remove(path)
        os.rmdir(parent)


def write_review(spec, reviewer, private_key, verdict):
    ok = verdict == "pass"
    digest, signature = sign(spec, reviewer, private_key)
    document = {
        "gaps": [] if ok else ["final state is not observable"],
        "observable": ok,
        "testable": ok,
        "scoped": ok,
        "stopping_point": ok,
        "spec_sha256": digest,
        "reviewer": reviewer,
        "signature": signature,
    }
    Path(os.path.splitext(spec)[0] + ".review.json").write_text(json.dumps(document))
    return digest


def main(argv):
    if len(argv) != 5:
        print("usage: review_sign.py <spec> <reviewer> <private-key> <pass|fail>", file=sys.stderr)
        return 2
    write_review(argv[1], argv[2], argv[3], argv[4])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
