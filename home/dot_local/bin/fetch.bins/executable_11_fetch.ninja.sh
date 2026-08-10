#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# ninja installer. ninja ships a single statically-linked binary inside a .zip
# (not a tarball), so this mirrors the ripgrep/fzf pattern but unzips instead of
# untars. Uses lib for the GitHub helpers, temp discipline, verification gate,
# and the safety guard. See home/doc/fetch-bins.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="ninja"
fb_init

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

TAG_NAME="$(gh_latest_tag ninja-build/ninja)"
VERSION="${TAG_NAME#v}"

# The asset names carry no version/arch token, so match the exact name.
ASSET_URL="$(gh_asset_url ninja-build/ninja '. == $arch' "$ASSET")"

ZIP="${FB_TMP}/ninja.zip"
gh_download "$ASSET_URL" "$ZIP"

fb_unzip "$ZIP" "$FB_TMP"   # single 'ninja' binary at the zip root

install_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" --version

echo "Installed ninja $VERSION (release zip) -> ${BIN_DIR}/${BIN_NAME}"
