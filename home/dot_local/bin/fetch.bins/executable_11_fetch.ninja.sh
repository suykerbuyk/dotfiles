#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# ninja installer. ninja ships a single statically-linked binary inside a .zip
# (not a tarball), so this mirrors the ripgrep/fzf pattern but unzips instead of
# untars. Uses lib for the GitHub helpers, temp discipline, verification gate,
# and the safety guard. See home/doc/fetch-bins.md.
#
# VERSIONED PAYLOAD, not install_bin (phase 5 of the version-blindness fix).
# install_bin gates on fb_check_bin, which compares no version, so once
# ~/.local/bin/ninja resolved this slot could never upgrade — and it downloaded
# the zip first and discarded it, on every installer run.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="ninja"
fb_init
fb_require_os

# ninja's release asset is a .zip; fb_unzip (see _lib.sh) extracts it with any
# no-root tool (unzip/bsdtar/busybox/python3), so no system 'unzip' is required.

# ninja's release assets are named by platform, not by the usual arch tokens:
#   ninja-linux.zip           (x86_64, statically linked)
#   ninja-linux-aarch64.zip   (arm64)
#   ninja-mac.zip             (universal macOS)
OS="$(fb_os mac)"          # linux | mac  (darwin -> mac)
ARCH="$(uname -m)"
case "${OS}:${ARCH}" in
    linux:x86_64)               ASSET="ninja-linux.zip" ;;
    linux:aarch64|linux:arm64)  ASSET="ninja-linux-aarch64.zip" ;;
    mac:*)                      ASSET="ninja-mac.zip" ;;
    *) echo "Error: unsupported platform '${OS}/${ARCH}' for ninja." >&2; exit 1 ;;
esac

# FB_PIN_NINJA holds a version; PIN_TAG carries it through to the asset lookup
# and is EMPTY otherwise, so the unpinned path keeps reading the one cached
# /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag ninja-build/ninja)"
    VERSION="${TAG_NAME#v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending the transfer. The bare `ninja` glob is the
# legacy unversioned payload this slot is migrating off; -[0-9] rather than a
# bare -*, per fb_prune_versions.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
    exit 0
fi

# The asset names carry no version/arch token, so match the exact name.
ASSET_URL="$(gh_asset_url ninja-build/ninja '. == $arch' "$ASSET" "" "$PIN_TAG")"

ZIP="${FB_TMP}/ninja.zip"
gh_download "$ASSET_URL" "$ZIP"

fb_unzip "$ZIP" "$FB_TMP"   # single 'ninja' binary at the zip root

NINJA_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$NINJA_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
