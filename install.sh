#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="aryan1306/LLMits"
VERSION="latest"
INSTALL_DIR="/Applications"

usage() {
    echo "Usage: install.sh [--version VERSION] [--user]"
    echo ""
    echo "  --version VERSION  Install a release such as v0.1.0 (default: latest)"
    echo "  --user             Install into ~/Applications without administrator access"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || { echo "error: --version requires a value" >&2; exit 1; }
            VERSION="$2"
            shift 2
            ;;
        --user)
            INSTALL_DIR="$HOME/Applications"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: LLMits requires macOS" >&2
    exit 1
fi

if [[ "$VERSION" == "latest" ]]; then
    DOWNLOAD_BASE="https://github.com/$REPOSITORY/releases/latest/download"
else
    [[ "$VERSION" == v* ]] || VERSION="v$VERSION"
    DOWNLOAD_BASE="https://github.com/$REPOSITORY/releases/download/$VERSION"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llmits-install.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mount"
DMG_PATH="$WORK_DIR/LLMits.dmg"
CHECKSUM_PATH="$WORK_DIR/LLMits.dmg.sha256"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Downloading LLMits ($VERSION)…"
curl --fail --location --silent --show-error "$DOWNLOAD_BASE/LLMits.dmg" --output "$DMG_PATH"
curl --fail --location --silent --show-error "$DOWNLOAD_BASE/LLMits.dmg.sha256" --output "$CHECKSUM_PATH"

EXPECTED_SHA="$(awk '{print $1}' "$CHECKSUM_PATH")"
ACTUAL_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
if [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
    echo "error: downloaded DMG failed checksum verification" >&2
    exit 1
fi

mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet
MOUNTED=1

if [[ "$INSTALL_DIR" == "$HOME/Applications" ]]; then
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/LLMits.app"
    ditto "$MOUNT_DIR/LLMits.app" "$INSTALL_DIR/LLMits.app"
elif [[ -w "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR/LLMits.app"
    ditto "$MOUNT_DIR/LLMits.app" "$INSTALL_DIR/LLMits.app"
else
    echo "Administrator access is required to install into $INSTALL_DIR."
    sudo rm -rf "$INSTALL_DIR/LLMits.app"
    sudo ditto "$MOUNT_DIR/LLMits.app" "$INSTALL_DIR/LLMits.app"
fi

echo "Installed LLMits into $INSTALL_DIR"
echo "Open it from Applications. On first launch, macOS may ask you to confirm opening an app downloaded from the internet."
