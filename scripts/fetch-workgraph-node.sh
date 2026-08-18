#!/bin/sh
set -eu

# Downloads the official Node.js binary used by WorkGraph.
# The uncompressed executable exceeds GitHub's 100 MB limit, so it is not
# stored in git. The built app still ships the extracted binary from Resources.

NODE_VERSION="v22.18.0"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/Sources/DevFlow/Resources/WorkGraphRuntime"
ARCH="${1:-arm64}"

case "$ARCH" in
  arm64)
    ARCHIVE="node-${NODE_VERSION}-darwin-arm64.tar.gz"
    DEST_NAME="node-arm64"
    EXPECTED_SHA="2c12913cba67af77ded8a399df3fd91c2e7f8628c7079da40bb9ff33bf00dfc0"
    ;;
  x86_64|x64)
    ARCHIVE="node-${NODE_VERSION}-darwin-x64.tar.gz"
    DEST_NAME="node-x86_64"
    EXPECTED_SHA="9c8aa1e5ff5780b38cc1134e2263d84e2f4308eb84c02515e3af33936ca02cdc"
    ;;
  *)
    echo "Unsupported architecture: $ARCH (use arm64 or x86_64)" >&2
    exit 1
    ;;
esac

DEST="$DEST_DIR/$DEST_NAME"
if [ -x "$DEST" ]; then
  echo "Already present: $DEST"
  exit 0
fi

URL="https://nodejs.org/dist/${NODE_VERSION}/${ARCHIVE}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workgraph-node.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fsSL "$URL" -o "$TMP/$ARCHIVE"
ACTUAL_SHA="$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{ print $1 }')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "Checksum mismatch for $ARCHIVE" >&2
  echo "expected $EXPECTED_SHA" >&2
  echo "actual   $ACTUAL_SHA" >&2
  exit 1
fi

tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
EXTRACTED="$(find "$TMP" -type f -path '*/bin/node' | head -n 1)"
if [ -z "$EXTRACTED" ]; then
  echo "Failed to find bin/node in $ARCHIVE" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$EXTRACTED" "$DEST"
chmod 755 "$DEST"
echo "Wrote $DEST"
