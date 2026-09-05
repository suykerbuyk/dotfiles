#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# starship installer (cross-shell prompt). Single static binary in a .tar.gz,
# so this is the plain versioned-payload pattern — same shape as fzf.
#
# VERSIONED PAYLOAD, not install_bin (phase 5 of the version-blindness fix).
# install_bin gates on fb_check_bin, which compares no version, so once
# ~/.local/bin/starship resolved this slot could never upgrade — and it
# downloaded the 12 MB tarball first and discarded it, on every installer run.
#
# Arch tokens are Rust target triples (x86_64 / aarch64), NOT the amd64/arm64
# tokens fb_arch normalizes to, so this uses `uname -m` directly. The musl build
# is preferred: it is fully static and is the only linux build published for
# aarch64, so one selector covers both architectures.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="starship"
fb_init
fb_require_os

# starship names assets by full Rust target triple, so ask for one rather than
# gluing `uname -m` to a hardcoded "-unknown-linux-musl": on FreeBSD that arch
# token is amd64 and the OS half is wrong twice over.
TRIPLE="$(fb_rust_triple musl)"

# FB_PIN_STARSHIP holds a version; PIN_TAG carries it through to the asset lookup
# and is EMPTY otherwise, so the unpinned path keeps reading the one cached
# /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag starship/starship)"
    VERSION="${TAG_NAME#v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending the transfer. The bare `starship` glob is the
# legacy unversioned payload this slot is migrating off; -[0-9] rather than a
# bare -*, per fb_prune_versions.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
    exit 0
fi

# Asset: starship-<triple>.tar.gz. Exact equality, not startswith: the release
# also carries a .tar.gz.sha256 beside every tarball.
ASSET_URL="$(gh_asset_url starship/starship \
    '. == ("starship-" + $arch + ".tar.gz")' "$TRIPLE" "" "$PIN_TAG")"

TARBALL="${FB_TMP}/starship.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

# The tarball holds a bare `starship` at the top level (no wrapper dir).
tar -xzf "$TARBALL" -C "$FB_TMP"

STARSHIP_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$STARSHIP_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
