#!/usr/bin/env python3
"""Read what is currently published for Sunrise, without downloading anything.

Sunrise publishes two independent lanes, and this script names both:

  game      sunrise-org/sunrise           the engine, one rolling `nightly` release
                                          plus a `dev-<date>-<sha>` release per merge
  launcher  sunrise-org/sunrise-launcher  the launcher, plain version tags (v1.3.1)

The engine release body is not parsed: every release carries `sunrise-release.json`
with the commit and build name in it, so the file is the source of truth and the
body is only read for the human-readable build name. That file is also what the
launcher reads before it installs a build, so agreeing with it means agreeing with
the launcher.

Outputs (GITHUB_OUTPUT, when set):
  build, commit, short, version_tag, prerelease,
  game_tag, game_published,
  launcher_version, launcher_tag, launcher_published
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
GAME_REPO = "sunrise-org/sunrise"
LAUNCHER_REPO = "sunrise-org/sunrise-launcher"


def fetch_json(url):
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "H-RUST-sunrise"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=40) as response:
        return json.load(response)


def fetch_text(url, limit=2_000_000):
    """Fetch a small asset body (sunrise-release.json is ~300 bytes)."""
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    headers = {"User-Agent": "H-RUST-sunrise"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=40) as response:
        return response.read(limit).decode("utf-8", "replace")


def release_json(release):
    """Return the parsed sunrise-release.json of a release, or None.

    The asset lives on the release itself, so this reads what is attached rather than
    what the body claims. A release without it (the SDK-only ones) is not a build.
    """
    for asset in release.get("assets", []):
        if asset.get("name") != "sunrise-release.json":
            continue
        url = asset.get("browser_download_url")
        if not url:
            continue
        try:
            return json.loads(fetch_text(url))
        except (urllib.error.URLError, ValueError):
            return None
    return None


def newest_build(releases, channel="dev"):
    """Pick the build to package.

    `channel="dev"` (the default) takes the newest `dev-<date>-<sha>` release. That is a
    deliberate choice, not an accident: `nightly` is a rolling release whose assets are
    replaced only when a full nightly job runs, and it had been sitting on an eleven-day-old
    build while dev releases were landing daily. For a package that is rebuilt on demand,
    "newest build that exists" beats "newest build on the channel upstream recommends".

    The trade-off is real: dev releases are one per merge, and their own notes say they
    exist "to test it after merge". If a dev build misbehaves, pin `--channel nightly` (or
    `--build-tag nightly`) and compare -- that is what the two knobs are for.

    A rolling tag never moves its `published_at`, only its assets, so the build name comes
    from the release's own sunrise-release.json rather than from dates.
    """
    candidates = []
    for release in releases:
        tag = release.get("tag_name", "")
        if channel == "nightly" and tag != "nightly":
            continue
        if channel == "dev" and not tag.startswith("dev-"):
            continue
        meta = release_json(release)
        if not meta or not meta.get("commit") or not meta.get("build"):
            continue
        match = re.fullmatch(r"(?:nightly|dev)-(\d{4}-\d{2}-\d{2})-([0-9a-f]{7,40})", meta["build"])
        date = match.group(1) if match else (release.get("published_at") or "")[:10]
        candidates.append({
            "tag": tag,
            "build": meta["build"],
            "commit": meta["commit"],
            "short": meta["commit"][:7],
            "date": date,
            "launcher_min": meta.get("launcher_min", ""),
            "published_at": release.get("published_at", ""),
            "prerelease": bool(release.get("prerelease")),
            "assets": [a.get("name", "") for a in release.get("assets", [])],
        })
    if not candidates:
        raise RuntimeError(f"no {channel} release carries a sunrise-release.json with a commit")
    if channel == "nightly":
        return candidates[0]
    candidates.sort(key=lambda b: (b["date"], b["published_at"]), reverse=True)
    return candidates[0]


def newest_launcher(releases):
    best = None
    for release in releases:
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", release.get("tag_name", ""))
        if not match:
            continue
        key = tuple(int(part) for part in match.groups())
        if best is None or key > best[0]:
            best = (key, release)
    if best is None:
        raise RuntimeError("no vX.Y.Z launcher release found")
    release = best[1]
    return {
        "tag": release["tag_name"],
        "version": release["tag_name"].lstrip("v"),
        "published_at": release.get("published_at", ""),
        "assets": [a.get("name", "") for a in release.get("assets", [])],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", choices=["dev", "nightly"], default="dev",
                        help="which lane to package from; dev takes the newest build that exists")
    parser.add_argument("--launcher-tag", default="",
                        help="pin a launcher release instead of taking the newest")
    parser.add_argument("--build-tag", default="",
                        help="pin a game release instead of taking the newest build")
    args = parser.parse_args()

    game_releases = fetch_json(f"{API}/repos/{GAME_REPO}/releases?per_page=50")
    launcher_releases = fetch_json(f"{API}/repos/{LAUNCHER_REPO}/releases?per_page=30")

    if args.build_tag:
        build = next((r for r in game_releases if r.get("tag_name") == args.build_tag), None)
        if build is None:
            raise RuntimeError(f"release {args.build_tag} not in the newest 50 of {GAME_REPO}")
        # An explicit tag decides the lane; that is the point of pinning one.
        build = newest_build([build], "dev" if args.build_tag.startswith("dev-") else "nightly")
    else:
        build = newest_build(game_releases, args.channel)

    if args.launcher_tag:
        launcher = next((r for r in launcher_releases if r.get("tag_name") == args.launcher_tag), None)
        if launcher is None:
            raise RuntimeError(f"release {args.launcher_tag} not in the newest 30 of {LAUNCHER_REPO}")
        launcher = newest_launcher([launcher])
    else:
        launcher = newest_launcher(launcher_releases)

    # The version folder name is the build name with its lane prefix kept: it is what the
    # launcher shows and what the player reports back, so the package uses it verbatim.
    version_tag = build["build"]

    outputs = {
        "build": build["build"],
        "commit": build["commit"],
        "short": build["short"],
        "version_tag": version_tag,
        "prerelease": "true" if build["prerelease"] else "false",
        "game_tag": build["tag"],
        "game_published": build["published_at"],
        "launcher_version": launcher["version"],
        "launcher_tag": launcher["tag"],
        "launcher_published": launcher["published_at"],
    }
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")

    report = {
        **outputs,
        "game_assets": build["assets"],
        "launcher_assets": launcher["assets"],
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"probe failed: {error}", file=sys.stderr)
        sys.exit(1)
