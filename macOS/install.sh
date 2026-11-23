#!/bin/bash
# Optional: builds Wiggle, copies it to an Applications folder and opens it.
# Uses /Applications when writable, otherwise ~/Applications (no admin needed).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

echo "📦 Copying to $DEST…"
pkill -x Wiggle 2>/dev/null || true
rm -rf "$DEST/Wiggle.app"
cp -R dist/Wiggle.app "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Wiggle.app" 2>/dev/null || true

open "$DEST/Wiggle.app"
echo "✅ Wiggle is running. Look for it in the menu bar."
