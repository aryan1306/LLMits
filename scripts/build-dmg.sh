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
ditto "$PROJECT_ROOT/packaging/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
ditto "$PROJECT_ROOT/packaging/Info.plist" "$APP_PATH/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

SIGNING_ARGS=()
if [[ -n "${CODESIGN_P12_BASE64:-}" || -n "${CODESIGN_P12_PATH:-}" ]]; then
    # Import the stable signing identity into a throwaway keychain so every release keeps the same
    # designated requirement and macOS Keychain trust survives updates.
    : "${CODESIGN_P12_PASSWORD:?Set CODESIGN_P12_PASSWORD for the signing certificate}"
    SIGNING_DIR="$(mktemp -d)"
    SIGNING_KEYCHAIN="$SIGNING_DIR/signing.keychain-db"
    SIGNING_KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
    ORIGINAL_KEYCHAINS=()
    while IFS= read -r keychain; do
        keychain="${keychain#"${keychain%%[![:space:]]*}"}"
        ORIGINAL_KEYCHAINS+=("${keychain//\"/}")
    done < <(security list-keychains -d user)
    cleanup_signing() {
        security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
        security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
        rm -rf "$SIGNING_DIR"
    }
    trap cleanup_signing EXIT

    P12_PATH="${CODESIGN_P12_PATH:-$SIGNING_DIR/identity.p12}"
    if [[ -z "${CODESIGN_P12_PATH:-}" ]]; then
        printf '%s' "$CODESIGN_P12_BASE64" | base64 --decode > "$P12_PATH"
    fi
    security create-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
    security set-keychain-settings -lut 3600 "$SIGNING_KEYCHAIN"
    security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
    security import "$P12_PATH" -k "$SIGNING_KEYCHAIN" -P "$CODESIGN_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
    security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
    # Self-signed identities are not trusted for policy checks, so select the identity by hash.
    CODESIGN_IDENTITY="$(security find-identity -p codesigning "$SIGNING_KEYCHAIN" | awk '/\)/ { print $2; exit }')"
    [[ -n "$CODESIGN_IDENTITY" ]] || { echo "error: no signing identity found in the certificate" >&2; exit 1; }
    SIGNING_ARGS=(--keychain "$SIGNING_KEYCHAIN")
elif [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "warning: ad-hoc signing; Keychain access will be re-requested after every update" >&2
fi

codesign --force --deep --options runtime --timestamp=none ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} --sign "$CODESIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --requirements - "$APP_PATH" 2>&1 | grep '^designated'

ditto "$APP_PATH" "$STAGING_DIR/LLMits.app"
ln -s /Applications "$STAGING_DIR/Applications"

if ! hdiutil create \
    -volname "LLMits" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"; then
    echo "Standard DMG creation was busy; retrying with the HFS image builder…"
    HYBRID_PATH="$DIST_DIR/LLMits-hybrid.dmg"
    rm -f "$DMG_PATH" "$HYBRID_PATH"
    hdiutil makehybrid -hfs -hfs-volume-name "LLMits" -o "$HYBRID_PATH" "$STAGING_DIR"
    hdiutil convert "$HYBRID_PATH" -format UDZO -o "$DMG_PATH"
    rm -f "$HYBRID_PATH"
fi

(cd "$DIST_DIR" && shasum -a 256 "LLMits.dmg" > "LLMits.dmg.sha256")
rm -rf "$STAGING_DIR"

echo "Created $DMG_PATH"
echo "Created $DMG_PATH.sha256"
