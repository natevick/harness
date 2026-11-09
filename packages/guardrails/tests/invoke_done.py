import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from guardrails.done import main


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: invoke_done.py <trust-json> <validate|run|hash> [spec]", file=sys.stderr)
        sys.exit(2)
    argv = ["done_means.py"] + sys.argv[2:]
    sys.exit(main(argv, trust=sys.argv[1], enforce_ownership=False))
