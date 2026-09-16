"""Run a test suite and emit per-test outcomes as JSON on stdout.

Invoked as a subprocess by ``grade.py`` with the candidate repository as the
working directory, so a candidate that crashes, hangs, or calls ``sys.exit``
cannot take the grader down with it.

Usage: ``python3 _runner.py hidden|visible``
"""

from __future__ import annotations

import io
import json
import sys
import unittest


def test_ids(suite):
    """Flatten a possibly-nested suite into test ids."""
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from test_ids(item)
        else:
            yield item.id()


def load(mode: str) -> unittest.TestSuite:
    loader = unittest.defaultTestLoader
    if mode == "hidden":
        return loader.loadTestsFromName("hidden_tests")
    return loader.discover("tests", top_level_dir=".")


def main() -> int:
    mode = sys.argv[1]
    report: dict[str, object] = {"mode": mode}
    try:
        suite = load(mode)
        collected = list(test_ids(suite))
        result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
    except Exception as exc:  # a candidate can break importability outright
        report.update(
            {
                "load_error": f"{type(exc).__name__}: {exc}",
                "collected": [],
                "failed": {},
                "errored": {},
                "skipped": [],
                "passed": [],
            }
        )
        print(json.dumps(report))
        return 0

    failed = {test.id(): trace.strip().splitlines()[-1] for test, trace in result.failures}
    errored = {test.id(): trace.strip().splitlines()[-1] for test, trace in result.errors}
    skipped = [test.id() for test, _ in result.skipped]
    unsuccessful = set(failed) | set(errored) | set(skipped)

    report.update(
        {
            "load_error": None,
            "collected": collected,
            "passed": [name for name in collected if name not in unsuccessful],
            "failed": failed,
            "errored": errored,
            "skipped": skipped,
        }
    )
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
