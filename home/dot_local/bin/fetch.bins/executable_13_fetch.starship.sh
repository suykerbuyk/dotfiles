#!/usr/bin/env bash
set -euo pipefail

# starship installer (cross-shell prompt). Single static binary in a .tar.gz,
# so this is the plain install_bin pattern — same shape as fzf.
#
# Arch tokens are Rust target triples (x86_64 / aarch64), NOT the amd64/arm64
# tokens fb_arch normalizes to, so this uses `uname -m` directly. The musl build
# is preferred: it is fully static and is the only linux build published for
# aarch64, so one selector covers both architectures.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="starship"
fb_init

ARCH="$(uname -m)"  # x86_64 | aarch64 — matches starship's asset names as-is

TAG_NAME="$(gh_latest_tag starship/starship)"
VERSION="${TAG_NAME#v}"

# Asset: starship-<arch>-unknown-linux-musl.tar.gz
ASSET_URL="$(gh_asset_url starship/starship \
    'startswith("starship-" + $arch + "-unknown-linux-musl") and endswith(".tar.gz")' "$ARCH")"

TARBALL="${FB_TMP}/starship.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

# The tarball holds a bare `starship` at the top level (no wrapper dir).
tar -xzf "$TARBALL" -C "$FB_TMP"

install_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" --version

echo "Installed starship $VERSION (tarball) -> ${BIN_DIR}/${BIN_NAME}"
