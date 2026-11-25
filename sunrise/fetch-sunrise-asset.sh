#!/usr/bin/env bash
# Download one asset from a Sunrise release and check it against that release's own
# SHA256SUMS, plus the digest GitHub records for it.
#
# Same shape as tools/ci/fetch-verified-asset.sh, but for the Sunrise repositories and
# with the release tag as a parameter: Sunrise publishes the engine as a rolling
# `nightly` and as per-merge `dev-*` tags, and the launcher under plain `vX.Y.Z` tags,
# so the tag cannot be a constant the way `nightly` was for Horizon.
#
# Usage:
#   bash sunrise/fetch-sunrise-asset.sh <repo> <tag> <asset name> <output path>
#
#   repo   sunrise-org/sunrise | sunrise-org/sunrise-launcher
#   tag    nightly | dev-2026-11-24-3d34bbe | v1.3.1 | ...
#
# Exit code 0: the file is on disk and matches. 1: it does not (nothing is left behind).
set -uo pipefail

REPO=${1:?usage: fetch-sunrise-asset.sh <repo> <tag> <asset name> <output path>}
TAG=${2:?}
ASSET=${3:?}
OUT=${4:?}

BASE="https://github.com/${REPO}/releases/download/${TAG}"

mkdir -p "$(dirname "$OUT")"
TMP="$OUT.part"
trap 'rm -f "$TMP" "$TMP.sums"' EXIT

echo "==> ${REPO}@${TAG}: ${ASSET}"
# Large assets on a slow CDN; retry and resume rather than restart the transfer.
curl -fL --retry 5 --retry-all-errors --retry-delay 3 -C - -o "$TMP" "$BASE/$ASSET" \
  || { echo "::error title=Download failed::${ASSET} could not be fetched from ${REPO}@${TAG}"; exit 1; }
curl -fsSL --retry 5 --retry-all-errors -o "$TMP.sums" "$BASE/SHA256SUMS" \
  || { echo "::error title=Download failed::SHA256SUMS could not be fetched from ${REPO}@${TAG}"; exit 1; }

# The line is "<sha256>  <name>"; take the one for our asset, exactly.
WANT=$(awk -v want="$ASSET" '$2 == want { print $1 }' "$TMP.sums")
if [[ -z "$WANT" ]]; then
  echo "::error title=Checksum missing::${ASSET} is not listed in ${REPO}@${TAG}'s SHA256SUMS"
  exit 1
fi

GOT=$(sha256sum "$TMP" | cut -d' ' -f1)
if [[ "$GOT" != "$WANT" ]]; then
  echo "::error title=Checksum mismatch::${ASSET} is $GOT, SHA256SUMS says $WANT"
  exit 1
fi
echo "    sha256 $GOT matches SHA256SUMS"

# GitHub records a digest per asset. If it disagrees with SHA256SUMS, the manifest is not
# describing what GitHub is hosting, which is worth failing on rather than trusting.
API_DIGEST=$(curl -fsSL --retry 3 \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in data.get("assets", []):
    if a.get("name") == sys.argv[1]:
        print((a.get("digest") or "").removeprefix("sha256:"))
        break
' "$ASSET" 2>/dev/null)
if [[ -n "$API_DIGEST" && "$API_DIGEST" != "$GOT" ]]; then
  echo "::error title=Checksum disagrees with GitHub::SHA256SUMS says $WANT, GitHub records $API_DIGEST"
  exit 1
fi
[[ -n "$API_DIGEST" ]] && echo "    GitHub records the same digest"

rm -f "$TMP.sums"
mv "$TMP" "$OUT"
ls -lh "$OUT"
echo "    $OUT verified"
