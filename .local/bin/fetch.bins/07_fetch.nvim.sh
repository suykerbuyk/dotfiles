#!/usr/bin/env bash
set -euo pipefail

# Neovim installer (release tarball — no FUSE, works on native Linux and WSL).
# Neovim is a TUI, so no display gating. Uses versioned install for rollback.
# Sourced from _lib.sh. See Context.fetch.bins.refactor.md for design.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="nvim"
fb_init

# Per-tool normalization (nvim keeps x86_64, unlike jq's amd64)
ARCH="$(fb_arch x86_64)"

TAG_NAME="$(gh_latest_tag neovim/neovim)"
VERSION="${TAG_NAME#v}"  # strip leading 'v' if present
if [[ -z "$VERSION" ]]; then
    echo "Error: could not parse version from tag." >&2
    exit 1
fi

# Deterministic tarball selection (endswith + arch; no .zsync or .deb)
ASSET_URL="$(gh_asset_url neovim/neovim 'endswith(".tar.gz") and contains($arch)' "$ARCH")"

TARBALL="${FB_TMP}/nvim.tar.gz"
INSTALL_DIR="${APP_DIR}/nvim-${VERSION}"

gh_download "$ASSET_URL" "$TARBALL"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1

# install_bin does chmod (if needed), verification, and ln -sfn
install_bin "${INSTALL_DIR}/bin/nvim" "$BIN_NAME" --version

echo "  target: ${INSTALL_DIR}/bin/nvim (versioned tarball)"
