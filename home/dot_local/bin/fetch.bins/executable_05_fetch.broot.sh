#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# broot installer (ZIP, musl binary from Canop/broot). Uses lib for safety,
# temp discipline, and install_bin. Simplified asset selection.
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="broot"
fb_init

OS="$(fb_os)"
ARCH="$(uname -m)"  # broot uses full arch in dir (x86_64, aarch64)

TAG_NAME="$(gh_latest_tag Canop/broot)"
VERSION="${TAG_NAME#v}"

# broot publishes the first asset as the correct musl binary for the platform
ASSET_URL="$(gh_asset_url Canop/broot 'true' '')"  # first asset

TARBALL="${FB_TMP}/broot.zip"  # actually a zip
gh_download "$ASSET_URL" "$TARBALL"

fb_unzip "$TARBALL" "$FB_TMP"   # no system 'unzip' needed (see _lib.sh fb_unzip)
BIN_SRC="$FB_TMP/${ARCH}-unknown-${OS}-musl/broot"

install_bin "$BIN_SRC" "$BIN_NAME" --version

echo "Installed broot $VERSION (zip) -> ${BIN_DIR}/${BIN_NAME}"
