#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from guardrails.catch_ignore import apply_baseline, counts_of, scan_paths
from guardrails.duplicates import scan as scan_duplicates

DEFAULT_IGNORE = ["**/node_modules/**", "**/.git/**"]


def resolve(base, value):
    if not value:
        return value
    if os.path.isabs(value):
        return value
    return os.path.normpath(os.path.join(base, value))


def load_counts(path):
    if not path or not os.path.isfile(path):
        return None
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    entries = data.get("entries")
    if entries is None:
        return data.get("counts") or {}
    counts = {}
    for entry in entries:
        reason = str(entry.get("reason") or "").strip()
        if not reason:
            raise ValueError("catch-ignore baseline entry has no reason: %s:%s" % (
                entry.get("path"), entry.get("line")
            ))
        key = entry["fingerprint"]
        counts[key] = counts.get(key, 0) + int(entry.get("count", 1))
    return counts


def write_counts(path, counts):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(
        json.dumps({"version": 1, "counts": counts}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def emit(messages):
    messages = list(messages)
    for index, text in enumerate(messages):
        if index:
            print()
        print(text)
    return 1 if messages else 0


def run_duplicates(root, min_lines, min_tokens, baseline, ignore, update_baseline):
    if baseline and update_baseline:
        Path(baseline).parent.mkdir(parents=True, exist_ok=True)
        if not os.path.isfile(baseline):
            Path(baseline).write_text('{"version": 1, "fingerprints": {}}\n', encoding="utf-8")
    use_baseline = baseline if baseline and (update_baseline or os.path.isfile(baseline)) else None
    messages, error = scan_duplicates(
        root, min_lines, min_tokens, use_baseline, ignore, update_baseline
    )
    if error:
        print(error, file=sys.stderr)
        return 2
    if update_baseline:
        print("duplicate baseline updated: %s" % baseline, file=sys.stderr)
        return 0
    return emit(messages)


def run_catches(roots, ignore, baseline, update_baseline):
    found = scan_paths(roots, ignore)
    if update_baseline:
        write_counts(baseline, counts_of(found))
        print("catch-ignore baseline updated: %s" % baseline, file=sys.stderr)
        return 0
    try:
        counts = load_counts(baseline) if baseline else None
    except (OSError, ValueError, json.JSONDecodeError, KeyError) as error:
        print("catch-ignore baseline: %s" % error, file=sys.stderr)
        return 2
    found = apply_baseline(found, counts)
    return emit(item["message"] for item in found)


def ignore_list(values):
    if values:
        return values
    return list(DEFAULT_IGNORE)


def run_config(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    base = str(Path(path).resolve().parent)
    status = 0
    duplicates = data.get("duplicates") or {}
    catches = data.get("catchIgnore") or {}
    if duplicates.get("enabled"):
        paths = [resolve(base, item) for item in (duplicates.get("paths") or ["."])]
        baseline = resolve(base, duplicates.get("baseline"))
        ignore = duplicates.get("ignore") or list(DEFAULT_IGNORE)
        for root in paths:
            code = run_duplicates(
                root,
                int(duplicates.get("minLines", 5)),
                int(duplicates.get("minTokens", 50)),
                baseline,
                ignore,
                False,
            )
            status = max(status, code)
            if code == 2:
                return 2
    if catches.get("enabled"):
        paths = [resolve(base, item) for item in (catches.get("paths") or ["."])]
        baseline = resolve(base, catches.get("baseline"))
        ignore = catches.get("ignore") or list(DEFAULT_IGNORE)
        code = run_catches(paths, ignore, baseline, False)
        status = max(status, code)
    return status


def main(argv):
    parser = argparse.ArgumentParser(prog="check.py")
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command")

    duplicates = sub.add_parser("duplicates")
    duplicates.add_argument("--root", required=True)
    duplicates.add_argument("--min-lines", type=int, default=5)
    duplicates.add_argument("--min-tokens", type=int, default=50)
    duplicates.add_argument("--baseline", default="")
    duplicates.add_argument("--ignore", action="append")
    duplicates.add_argument("--update-baseline", action="store_true")

    catches = sub.add_parser("catch-ignore")
    catches.add_argument("--root", required=True)
    catches.add_argument("--baseline", default="")
    catches.add_argument("--ignore", action="append")
    catches.add_argument("--update-baseline", action="store_true")

    args = parser.parse_args(argv[1:])
    if args.config:
        return run_config(args.config)
    if args.command == "duplicates":
        return run_duplicates(
            args.root,
            args.min_lines,
            args.min_tokens,
            args.baseline,
            ignore_list(args.ignore),
            args.update_baseline,
        )
    if args.command == "catch-ignore":
        return run_catches(
            [args.root],
            ignore_list(args.ignore),
            args.baseline,
            args.update_baseline,
        )
    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
