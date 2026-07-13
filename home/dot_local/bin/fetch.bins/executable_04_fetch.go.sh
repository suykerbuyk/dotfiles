#!/usr/bin/env bash
set -euo pipefail

# Go installer (uses official go.dev JSON, not GitHub). Uses lib for safety,
# temp discipline, and install_bin. Preserves version check.
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="go"
fb_init

OS="$(fb_os linux)"  # go uses "linux", not "linux" change but consistent
ARCH="$(fb_arch amd64)"

JSON_URL="https://go.dev/dl/?mode=json"
VERSION="$(curl -fsSL "$JSON_URL" | jq -r '.[] | select(.stable == true) | .version' | sort -V | tail -1)"

if [[ -z "$VERSION" ]]; then
    echo "Error: could not determine latest stable Go version." >&2
    exit 1
fi

ASSET_URL="https://go.dev/dl/${VERSION}.${OS}-${ARCH}.tar.gz"
VERSION_DIR="${APP_DIR}/${VERSION}"

# Enhanced check for obsolete/broken versions (1.25.7 or incorrect /go/bin/go path in 1.26.5)
if [[ -L "${BIN_DIR}/go" ]]; then
    CURRENT_TARGET="$(readlink -f "${BIN_DIR}/go" 2>/dev/null || readlink "${BIN_DIR}/go")"
    if [[ "$CURRENT_TARGET" == *go1.25* ]] || [[ "$CURRENT_TARGET" == *go1.26.5/go/bin/go* ]]; then
        echo "Go symlink points to obsolete/broken target ($CURRENT_TARGET) — forcing reinstall of $VERSION"
        rm -f "${BIN_DIR}/go" "${BIN_DIR}/gofmt"
    fi
fi

if [[ -d "$VERSION_DIR" ]]; then
    echo "Go $VERSION already installed"
    # Ensure correct symlink (must be VERSION/bin/go, not VERSION/go/bin/go)
    ln -sfn "${VERSION_DIR}/bin/go" "${BIN_DIR}/go"
    ln -sfn "${VERSION_DIR}/bin/gofmt" "${BIN_DIR}/gofmt"
    echo "  Symlink repaired to correct path: ${VERSION_DIR}/bin/go"
    exit 0
fi

TARBALL="${FB_TMP}/go.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"  # reuses helper (works for any URL)

mkdir -p "$VERSION_DIR"
tar -C "$VERSION_DIR" -xzf "$TARBALL" --strip-components=1

install_bin "${VERSION_DIR}/go/bin/go" "$BIN_NAME" version
install_bin "${VERSION_DIR}/go/bin/gofmt" "gofmt" version

echo "Installed Go $VERSION (official tarball) to $VERSION_DIR"
