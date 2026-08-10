#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# herdr installer (terminal multiplexer/runtime for AI coding agents, Rust,
# Apache-2.0). The release ships a BARE, UNCOMPRESSED binary per os/arch —
# no tarball, no zip, no .gz — so this is the shortest fetcher here: download
# straight into $FB_TMP and hand it to install_bin. There is no extraction
# step to get wrong. (jq is the only other bare-binary release, but it builds
# its URL by interpolation because the jq bootstrap cannot call jq to parse
# the asset list.)
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

ARCH="$(uname -m)"  # x86_64 | aarch64 — matches herdr's asset names as-is

TAG_NAME="$(gh_latest_tag herdrdev/herdr)"
VERSION="${TAG_NAME#v}"

# Asset: herdr-linux-<arch> (bare binary, exact name)
ASSET_URL="$(gh_asset_url herdrdev/herdr \
    '. == ("herdr-linux-" + $arch)' "$ARCH")"

gh_download "$ASSET_URL" "${FB_TMP}/${BIN_NAME}"

install_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" --version

echo "Installed herdr ${VERSION} (bare static binary) -> ${BIN_DIR}/${BIN_NAME}"
