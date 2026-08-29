#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# broot installer (ZIP, musl binary from Canop/broot). Uses lib for safety,
# temp discipline, and install_bin. Simplified asset selection.
# See Context.fetch.bins.refactor.md.
#
# This fetcher installs the BINARY ONLY, and deliberately never runs
# `broot --install`. The `br` shell function is provided by the rc layer, which
# eval's `broot --print-shell-function "$DOTFILES_SHELL"` (see
# home/dot_config/shell/common.sh). `broot --install` would append a source line
# to ~/.bashrc AND ~/.zshrc — chezmoi-managed stubs, so the next `chezmoi apply`
# destroys it — and it only ever generates a bash launcher regardless.
#
# Relatedly: home/dot_config/broot/launcher/installed-v4 is tracked ON PURPOSE.
# It is broot's "install already done" marker, and shipping it suppresses the
# interactive `Can I install it now? [Y/n]` prompt broot raises on its first TUI
# launch — a prompt that defaults to YES and whose only effect would be to patch
# those same managed rc stubs. Do not "clean up" that file.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="broot"
fb_init
fb_require_os

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
