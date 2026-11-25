#!/usr/bin/env python3
"""Confirm the release we downloaded is the build the probe named.

`nightly` is a rolling tag: its assets are replaced in place and its published_at never
moves. Between the probe reading sunrise-release.json and the download finishing, the
upstream job can push a newer build, in which case the package would be labelled with one
commit and contain another. The download's own SHA256SUMS cannot catch that -- it only
proves the file matches itself.

Usage:
  python3 sunrise/check-downloaded-build.py <expected commit> <downloaded sunrise-release.json>
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: check-downloaded-build.py <expected commit> <sunrise-release.json>", file=sys.stderr)
        return 2
    want, path = sys.argv[1], sys.argv[2]
    try:
        meta = json.load(open(path))
    except (OSError, ValueError) as error:
        print(f"::error title=Build metadata unreadable::{path}: {error}")
        return 1

    got = meta.get("commit", "")
    if got != want:
        print(f"::error title=Build moved::the probe saw {want}, the downloaded release says "
              f"{got or '(no commit)'}; re-run to pick up one consistent build")
        return 1
    print(f"downloaded release confirms commit {want} ({meta.get('build', '?')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
