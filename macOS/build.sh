#!/bin/bash
# Builds Wiggle as a universal app (Apple Silicon + Intel), signs it ad-hoc and
# creates a DMG, all inside ./dist. Only needs Apple's Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Wiggle"
BUILD_DIR="build"
DIST_DIR="dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MIN_OS="12.0"
# Info.plist is the single source of truth for the version number.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ swiftc was not found. Install Apple's Command Line Tools with:"
  echo "   xcode-select --install"
  exit 1
fi

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR"

echo "🔨 Compiling (arm64)…"
swiftc -O -target "arm64-apple-macos$MIN_OS" Sources/main.swift \
  -framework Cocoa -framework IOKit -framework ServiceManagement \
  -o "$BUILD_DIR/$APP_NAME-arm64"

echo "🔨 Compiling (x86_64)…"
swiftc -O -target "x86_64-apple-macos$MIN_OS" Sources/main.swift \
  -framework Cocoa -framework IOKit -framework ServiceManagement \
  -o "$BUILD_DIR/$APP_NAME-x86_64"

echo "🔗 Creating universal binary…"
lipo -create "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64" \
  -output "$APP_DIR/Contents/MacOS/$APP_NAME"

cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns" || true

echo "✍️  Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP_DIR"

echo "💿 Creating DMG…"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST_DIR/$APP_NAME-$VERSION.dmg" >/dev/null

cp -R "$APP_DIR" "$DIST_DIR/"

echo ""
echo "✅ Done:"
echo "   App: $DIST_DIR/$APP_NAME.app   (run it with: open $DIST_DIR/$APP_NAME.app)"
echo "   DMG: $DIST_DIR/$APP_NAME-$VERSION.dmg"
