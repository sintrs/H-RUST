#!/usr/bin/env python3
"""Check that a `sunrise-client --launch-api` report describes the build we packaged.

The report is the client's own account of itself, and its `sunrise` field is the same
human-readable name the release body uses ("Nightly 2026-11-20 · 9425651"). Comparing it
against the version folder name is what catches a package whose folder was labelled with
one build while another build's files ended up inside it -- which is exactly the mistake
a "copy the tarball into a version folder" step can make, silently.

Usage:
  python3 sunrise/check-launch-api.py <version tag> <launch-api.json>

Prints one line. Exit 0: it matches. 1: it does not. 2: the JSON could not be read.
"""
import json
import re
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: check-launch-api.py <version tag> <launch-api.json>", file=sys.stderr)
        return 2
    want, path = sys.argv[1], sys.argv[2]

    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as error:
        print(f"cannot read {path}: {error}")
        return 2

    # --launch-api prints one JSON object, but a build could print a banner first.
    # Find the outermost object instead of insisting on a clean stream.
    data = None
    start = text.find("{")
    while start != -1 and data is None:
        try:
            data, _ = json.JSONDecoder().raw_decode(text[start:])
        except ValueError:
            start = text.find("{", start + 1)
    if not isinstance(data, dict):
        print("--launch-api printed no JSON object")
        return 2

    reported = (data.get("sunrise") or "").strip()
    if not reported:
        print("--launch-api no longer reports a 'sunrise' build name")
        return 1

    # Version folders are named after the build: nightly-<date>-<short>, dev-<date>-<short>.
    match = re.fullmatch(r"(?:nightly|dev)-(\d{4}-\d{2}-\d{2})-([0-9a-f]{7,40})", want)
    if not match:
        print(f"the version tag {want!r} is not a build name this check understands")
        return 1
    date, short = match.group(1), match.group(2)[:7]

    if date in reported and short in reported:
        print(f"reports {reported!r}, matches {want}")
        return 0
    print(f"the client reports {reported!r}, but the package is labelled {want}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
