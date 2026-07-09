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

if [[ -d "$VERSION_DIR" ]]; then
    echo "Go $VERSION already installed"
    exit 0
fi

TARBALL="${FB_TMP}/go.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"  # reuses helper (works for any URL)

mkdir -p "$VERSION_DIR"
tar -C "$VERSION_DIR" -xzf "$TARBALL" --strip-components=1

install_bin "${VERSION_DIR}/go/bin/go" "$BIN_NAME" version
install_bin "${VERSION_DIR}/go/bin/gofmt" "gofmt" version

echo "Installed Go $VERSION (official tarball) to $VERSION_DIR"
