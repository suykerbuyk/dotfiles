#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# herdr installer (terminal multiplexer/runtime for AI coding agents, Rust,
# Apache-2.0). The release ships a BARE, UNCOMPRESSED binary per os/arch —
# no tarball, no zip, no .gz — so this is the shortest fetcher here: download
# straight into $FB_TMP and hand it over. There is no extraction step to get
# wrong. (jq is the only other bare-binary release, but it builds its URL by
# interpolation because the jq bootstrap cannot call jq to parse the asset list.)
#
# VERSIONED PAYLOAD, not install_bin (phase 5 of the version-blindness fix).
# install_bin gates on fb_check_bin, which compares no version, so once
# ~/.local/bin/herdr resolved this slot could never upgrade — and it downloaded
# the 21 MB binary first and discarded it, on every installer run.
#
# Arch tokens are RAW `uname -m` (x86_64 / aarch64), so fb_arch is unusable:
# its sed hardcodes `s/aarch64/arm64/` regardless of the label passed in, and
# can therefore never emit `aarch64`. Same situation as starship, handled the
# same way — `uname -m` directly.
#
# The selector is an EXACT match, not `contains`: the release also carries
# herdr-macos-x86_64, which a contains("x86_64") filter would happily select
# on a linux box.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="herdr"
fb_init
fb_require_os

ARCH="$(uname -m)"  # x86_64 | aarch64 — matches herdr's asset names as-is

# FB_PIN_HERDR holds a version; PIN_TAG carries it through to the asset lookup
# and is EMPTY otherwise, so the unpinned path keeps reading the one cached
# /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag herdrdev/herdr)"
    VERSION="${TAG_NAME#v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending 21 MB. The bare `herdr` glob is the legacy
# unversioned payload this slot is migrating off; -[0-9] rather than a bare -*,
# per fb_prune_versions.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
    exit 0
fi

# Asset: herdr-linux-<arch> (bare binary, exact name)
ASSET_URL="$(gh_asset_url herdrdev/herdr \
    '. == ("herdr-linux-" + $arch)' "$ARCH" "" "$PIN_TAG")"

gh_download "$ASSET_URL" "${FB_TMP}/${BIN_NAME}"

HERDR_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$HERDR_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
