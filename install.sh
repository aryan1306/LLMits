#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="aryan1306/LLMits"
VERSION="latest"
INSTALL_DIR="/Applications"
USE_COLOR=0

if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
    USE_COLOR=1
fi

paint() {
    local color="$1"
    shift
    if [[ "$USE_COLOR" -eq 1 ]]; then
        printf '\033[%sm%s\033[0m' "$color" "$*"
    else
        printf '%s' "$*"
    fi
}

show_banner() {
    paint "38;5;208" '  ██╗     ██╗     ███╗   ███╗██╗████████╗███████╗'
    printf '\n'
    paint "38;5;209" '  ██║     ██║     ████╗ ████║██║╚══██╔══╝██╔════╝'
    printf '\n'
    paint "38;5;210" '  ██║     ██║     ██╔████╔██║██║   ██║   ███████╗'
    printf '\n'
    paint "38;5;211" '  ██║     ██║     ██║╚██╔╝██║██║   ██║   ╚════██║'
    printf '\n'
    paint "38;5;212" '  ███████╗███████╗██║ ╚═╝ ██║██║   ██║   ███████║'
    printf '\n'
    paint "38;5;213" '  ╚══════╝╚══════╝╚═╝     ╚═╝╚═╝   ╚═╝   ╚══════╝'
    printf '\n\n'
    paint "2" '  Your LLM quota, one glance away.'
    printf '\n\n'
}

download() {
    local label="$1"
    local url="$2"
    local destination="$3"
    local error_log="$WORK_DIR/curl-error.log"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local index=0

    : > "$error_log"
    curl --fail --location --silent --show-error "$url" --output "$destination" 2>"$error_log" &
    local curl_pid=$!

    if [[ -t 1 ]]; then
        printf '\033[?25l'
        while kill -0 "$curl_pid" 2>/dev/null; do
            printf '\r  '
            paint "38;5;208" "${frames[$index]}"
            printf ' %s' "$label"
            index=$(( (index + 1) % ${#frames[@]} ))
            sleep 0.08
        done
    else
        printf '  • %s\n' "$label"
    fi

    if wait "$curl_pid"; then
        if [[ -t 1 ]]; then
            printf '\r  '
            paint "32" '✓'
            printf ' %s\033[K\n' "$label"
            printf '\033[?25h'
        fi
    else
        if [[ -t 1 ]]; then
            printf '\r  '
            paint "31" '✗'
            printf ' %s\033[K\n\033[?25h' "$label"
        fi
        sed 's/^/    /' "$error_log" >&2
        return 1
    fi
}

usage() {
    echo "Usage: install.sh [--version VERSION] [--user]"
    echo ""
    echo "  --version VERSION  Install a release such as v1.0.0 (default: latest)"
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

show_banner

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
    if [[ -t 1 ]]; then
        printf '\033[?25h'
    fi
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

paint "1" "  Installing LLMits ($VERSION)"
printf '\n\n'
download "Downloading application" "$DOWNLOAD_BASE/LLMits.dmg" "$DMG_PATH"
download "Downloading checksum" "$DOWNLOAD_BASE/LLMits.dmg.sha256" "$CHECKSUM_PATH"

EXPECTED_SHA="$(awk '{print $1}' "$CHECKSUM_PATH")"
ACTUAL_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
if [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
    echo "error: downloaded DMG failed checksum verification" >&2
    exit 1
fi
printf '  '
paint "32" '✓'
printf ' Verified SHA-256 checksum\n'

mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet
MOUNTED=1
printf '  '
paint "32" '✓'
printf ' Mounted disk image\n'

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

printf '\n  '
paint "1;32" 'LLMits installed successfully!'
printf '\n  Installed into %s\n' "$INSTALL_DIR"
printf '  Open it from Applications to get started.\n'
printf '  On first launch, macOS may ask you to confirm opening an app downloaded from the internet.\n\n'
