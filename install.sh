#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="aryan1306/LLMits"
VERSION="latest"
INSTALL_DIR="/Applications"
USE_COLOR=0
CDN_BASE_URL="${LLMITS_CDN_BASE_URL:-https://llmits.aryansinghal.in}"

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

human_bytes() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes >= 1048576) printf "%.1f MB", bytes / 1048576
        else if (bytes >= 1024) printf "%.0f KB", bytes / 1024
        else printf "%d B", bytes
    }'
}

fetch_file() {
    local destination="$1"
    local show_progress="$2"
    shift 2
    local partial="$destination.part"
    local error_log="$destination.curl-error.log"
    local url
    local curl_options=(
        --fail
        --location
        --show-error
        --connect-timeout 10
        --retry 3
        --retry-delay 1
        --retry-all-errors
    )

    : > "$error_log"
    for url in "$@"; do
        [[ -n "$url" ]] || continue
        if [[ "$show_progress" -eq 1 && -t 1 ]]; then
            if curl "${curl_options[@]}" --progress-bar --output "$partial" "$url"; then
                mv "$partial" "$destination"
                return 0
            fi
        elif curl "${curl_options[@]}" --silent --output "$partial" "$url" 2>"$error_log"; then
            mv "$partial" "$destination"
            return 0
        fi
    done

    return 1
}

download_release() {
    local application_url="$GITHUB_DOWNLOAD_BASE/LLMits.dmg"
    local checksum_url="$GITHUB_DOWNLOAD_BASE/LLMits.dmg.sha256"
    local cdn_application_url=""
    local cdn_checksum_url=""
    local started_at=$SECONDS

    if [[ -n "$CDN_BASE_URL" ]]; then
        local cdn_release_path="$RELEASE_PATH"
        if [[ "$VERSION" == "latest" ]]; then
            local mirrored_version
            mirrored_version=$(curl --fail --location --silent \
                --connect-timeout 3 --max-time 5 \
                "$CDN_BASE_URL/latest/version.txt" 2>/dev/null || true)
            if [[ "$mirrored_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                cdn_release_path="releases/$mirrored_version"
            else
                cdn_release_path=""
            fi
        fi
        if [[ -n "$cdn_release_path" ]]; then
            cdn_application_url="$CDN_BASE_URL/$cdn_release_path/LLMits.dmg"
            cdn_checksum_url="$CDN_BASE_URL/$cdn_release_path/LLMits.dmg.sha256"
        fi
    fi

    fetch_file "$CHECKSUM_PATH" 0 "$cdn_checksum_url" "$checksum_url" &
    local checksum_pid=$!

    if [[ -t 1 ]]; then
        printf '  Downloading application\n  '
    else
        printf '  • Downloading application and checksum\n'
    fi

    local failed=0
    fetch_file "$DMG_PATH" 1 "$cdn_application_url" "$application_url" || failed=1
    wait "$checksum_pid" || failed=1

    if [[ "$failed" -eq 0 ]]; then
        if [[ -t 1 ]]; then
            printf '  '
            paint "32" '✓'
            printf ' Downloaded %s in %ss\n' \
                "$(human_bytes "$(stat -f '%z' "$DMG_PATH")")" "$(( SECONDS - started_at ))"
        fi
        return 0
    fi

    if [[ -t 1 ]]; then
        printf '  '
        paint "31" '✗'
        printf ' Download failed\n'
    fi
    for error_log in "$DMG_PATH.curl-error.log" "$CHECKSUM_PATH.curl-error.log"; do
        [[ -s "$error_log" ]] && sed 's/^/    /' "$error_log" >&2
    done
    return 1
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
    RELEASE_PATH="latest"
    GITHUB_DOWNLOAD_BASE="https://github.com/$REPOSITORY/releases/latest/download"
else
    [[ "$VERSION" == v* ]] || VERSION="v$VERSION"
    RELEASE_PATH="releases/$VERSION"
    GITHUB_DOWNLOAD_BASE="https://github.com/$REPOSITORY/releases/download/$VERSION"
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
download_release

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
