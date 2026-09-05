#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# broot installer (ZIP, musl binary from Canop/broot). Uses lib for safety and
# temp discipline.
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
#
# VERSIONED PAYLOAD, not install_bin (phase 5 of the version-blindness fix).
# broot is where fb_check_bin's OTHER hole showed up: ~/.local/bin/broot was a
# 13 MB plain FILE with no payload behind it, put there by an older fetcher
# generation. It is -e and not -L, so neither symlink branch fired, the gate fell
# through to "valid", and broot was pinned forever with nothing to upgrade FROM.
# Phase 1 taught fb_check_bin to reject a plain file; the versioned payload here
# is what stops the state recurring, and fb_versioned_current's ln -sfn replaces
# such a file without a download when the right payload is already present.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="broot"
fb_init
fb_require_os

OS="$(fb_os)"
ARCH="$(uname -m)"  # broot uses full arch in dir (x86_64, aarch64)

# FB_PIN_BROOT holds a version; PIN_TAG carries it through to the asset lookup
# and is EMPTY otherwise, so the unpinned path keeps reading the one cached
# /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag Canop/broot)"
    VERSION="${TAG_NAME#v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending the transfer. The bare `broot` glob is the
# legacy unversioned payload (and, on a machine that never got past the plain
# file, nothing matches it and the prune is a no-op).
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
    exit 0
fi

# broot publishes the first asset as the correct musl binary for the platform
ASSET_URL="$(gh_asset_url Canop/broot 'true' '' "" "$PIN_TAG")"  # first asset

TARBALL="${FB_TMP}/broot.zip"  # actually a zip
gh_download "$ASSET_URL" "$TARBALL"

fb_unzip "$TARBALL" "$FB_TMP"   # no system 'unzip' needed (see _lib.sh fb_unzip)
BIN_SRC="$FB_TMP/${ARCH}-unknown-${OS}-musl/broot"

BROOT_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "$BIN_SRC" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$BROOT_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
