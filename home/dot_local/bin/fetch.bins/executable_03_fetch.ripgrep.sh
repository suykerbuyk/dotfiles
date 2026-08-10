#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# ripgrep (rg) installer. Uses lib for GitHub helpers, temp discipline,
# verification, and safety. Matches the musl binary naming.
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="rg"
fb_init

OS="$(fb_os)"
ARCH="$(uname -m)"  # ripgrep uses full arch in dir name (x86_64, aarch64)

TAG_NAME="$(gh_latest_tag BurntSushi/ripgrep)"
VERSION="${TAG_NAME#v}"

# Asset is ripgrep-${VERSION}-${ARCH}-unknown-${OS}-musl.tar.gz
ASSET_URL="$(gh_asset_url BurntSushi/ripgrep 'contains("musl") and contains($arch)' "$ARCH")"

TARBALL="${FB_TMP}/rg.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"
BIN_PATH="${FB_TMP}/ripgrep-${VERSION}-${ARCH}-unknown-${OS}-musl"

install_bin "${BIN_PATH}/$BIN_NAME" "$BIN_NAME" --version

echo "Installed ripgrep $VERSION (musl tarball) -> ${BIN_DIR}/${BIN_NAME}"
