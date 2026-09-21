#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.0.0}"
VERSION="${VERSION#v}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like 1.2.3 or v1.2.3" >&2
    exit 1
fi

DIST_DIR="${DIST_DIR:-$PROJECT_ROOT/dist}"
APP_PATH="$DIST_DIR/LLMits.app"
DMG_PATH="$DIST_DIR/LLMits.dmg"
STAGING_DIR="$DIST_DIR/dmg-root"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$PROJECT_ROOT"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP_PATH" "$STAGING_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$STAGING_DIR"

ditto "$BIN_DIR/LLMits" "$APP_PATH/Contents/MacOS/LLMits"
ditto "$BIN_DIR/LLMits_LLMitsApp.bundle" "$APP_PATH/Contents/Resources/LLMits_LLMitsApp.bundle"
ditto "$PROJECT_ROOT/packaging/Info.plist" "$APP_PATH/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ditto "$APP_PATH" "$STAGING_DIR/LLMits.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "LLMits" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

(cd "$DIST_DIR" && shasum -a 256 "LLMits.dmg" > "LLMits.dmg.sha256")
rm -rf "$STAGING_DIR"

echo "Created $DMG_PATH"
echo "Created $DMG_PATH.sha256"
