#!/usr/bin/env python3
"""Report whether a `sunrise-client --launch-api` dump still offers an option.

Used to assert the offline entry point (`--name`) survived into the build being packaged.
Offline play in Sunrise needs no launcher patch: the client takes the player name on its
own command line, so if that option disappears the whole premise of this package goes with
it. Reading it from `--launch-api` rather than grep-ing `--help` keeps the check stable --
the JSON is a published contract (docs/api/launch.md), the help text is prose.

Usage:
  python3 sunrise/check-launch-option.py <launch-api.json> <option, with dashes>

Exit 0: the option is listed. 1: it is not. 2: the JSON could not be read.
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: check-launch-option.py <launch-api.json> <option>", file=sys.stderr)
        return 2
    path, option = sys.argv[1], sys.argv[2]

    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as error:
        print(f"cannot read {path}: {error}")
        return 2

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

    names = set()
    for entry in data.get("options") or []:
        if isinstance(entry, dict):
            name = entry.get("name")
        else:
            name = entry
        if name:
            names.add(str(name))

    if option in names:
        return 0
    print(f"{option} is not among the {len(names)} launch options")
    return 1


if __name__ == "__main__":
    sys.exit(main())
