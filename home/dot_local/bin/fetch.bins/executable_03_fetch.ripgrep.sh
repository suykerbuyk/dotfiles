#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# ripgrep (rg) installer. Uses lib for GitHub helpers, temp discipline,
# verification, and safety. Matches the musl binary naming.
#
# VERSIONED PAYLOAD, not install_bin (phase 5 of the version-blindness fix).
# install_bin gates on fb_check_bin, which compares no version: once
# ~/.local/bin/rg resolved to something executable it answered "already valid
# (skipping)" and returned, so this slot could never upgrade — and it downloaded
# the new tarball first, then discarded it, on every single installer run.
#
# THIS SLOT WAS THE CLEAREST LIVE INSTANCE. Measured 2026-09-05: ~/.local/bin/rg
# resolved into ~/.local/apps/ripgrep-15.1.0-x86_64-unknown-linux-musl/, a
# payload shape this fetcher has not produced for two generations, while upstream
# was at 15.2.0. The symlink was *valid*, so the gate passed it, and line 35 then
# printed "Installed ripgrep 15.2.0" immediately after install_bin had printed
# "rg: already valid (skipping)". A run that upgraded nothing claimed it had.
# install_versioned_bin owns that message now, and it prints what is on disk.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="rg"
fb_init
fb_require_os

OS="$(fb_os)"
ARCH="$(uname -m)"  # ripgrep uses full arch in dir name (x86_64, aarch64)

# FB_PIN_RG holds a version; PIN_TAG carries it through to the asset lookup and
# is EMPTY otherwise, so the unpinned path keeps reading the one cached
# /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag BurntSushi/ripgrep)"
    VERSION="${TAG_NAME#v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download. That ordering is the fix: the version is
# already in hand, so there is no reason to spend the transfer to learn what the
# filesystem can answer.
#
# Three globs. `rg-[0-9]*` is the current scheme; the bare `rg` is the legacy
# unversioned payload every phase-5 slot is migrating off; `ripgrep-[0-9]*` is
# the abandoned third scheme, and without it the 98 MB directory above is
# reclaimed by nothing. -[0-9] rather than a bare -*, per fb_prune_versions.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME" 'ripgrep-[0-9]*'
    exit 0
fi

# Asset is ripgrep-${VERSION}-${ARCH}-unknown-${OS}-musl.tar.gz
ASSET_URL="$(gh_asset_url BurntSushi/ripgrep 'contains("musl") and contains($arch)' "$ARCH" "" "$PIN_TAG")"

TARBALL="${FB_TMP}/rg.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"
BIN_PATH="${FB_TMP}/ripgrep-${VERSION}-${ARCH}-unknown-${OS}-musl"

# The payload this run supersedes, captured BEFORE the relink. On the one-time
# migration run it resolves to the BINARY inside the legacy directory rather than
# to the directory itself, so that directory is swept in this pass instead of the
# next one. That is safe here and only here: it is a single unlinked file under a
# running short-lived CLI, not a runtime tree something lazily loads from.
RG_PREV="$(fb_prev_payload "$BIN_NAME")"

install_versioned_bin "${BIN_PATH}/${BIN_NAME}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$RG_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME" 'ripgrep-[0-9]*'
