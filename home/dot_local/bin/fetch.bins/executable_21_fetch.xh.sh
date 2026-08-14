#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# xh installer (friendly, fast HTTP client — an httpie-compatible CLI; Rust,
# MIT, ducaale/xh). Plain single-binary release tarball on the ripgrep (slot 03)
# pattern, same as fd/bat.
#
# Arch tokens are RAW `uname -m` (x86_64 / aarch64), so fb_arch is unusable
# here: its sed hardcodes `s/aarch64/arm64/` regardless of the label it is
# given, and can therefore NEVER emit `aarch64`. Routing through it would 404 on
# every arm64 box while passing forever on x86_64. Uses `uname -m` directly.
#
# xh publishes musl for BOTH x86_64 and aarch64 and ships no linux-gnu build at
# all, so one musl selector covers every arch this repo targets — it needs none
# of delta's (slot 20) gnu fallback. The endswith(".tar.gz") anchor is kept for
# the same reason as its siblings: xh ships no .deb today, but the anchor is
# what makes that a guarantee rather than an observation. "linux-musl" over a
# bare "musl" also excludes the armv7 `musleabihf` build.
#
# TAG vs VERSION: the tarball's inner directory carries the tag VERBATIM
# (xh-v0.26.2-x86_64-unknown-linux-musl), so it needs ${TAG_NAME} WITH the "v".
# delta is the mirror image. See the fuller note in 18_fetch.fd.sh.
#
# Completions live under completions/ here, not autocomplete/ as in fd and bat.
# The zsh file is already named _xh, so the helper's rename is a no-op for xh.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="xh"
fb_init

OS="$(fb_os)"
ARCH="$(uname -m)"  # x86_64 | aarch64 — matches xh's asset names as-is

TAG_NAME="$(gh_latest_tag ducaale/xh)"
VERSION="${TAG_NAME#v}"

# Asset: xh-${TAG_NAME}-${ARCH}-unknown-${OS}-musl.tar.gz
ASSET_URL="$(gh_asset_url ducaale/xh \
    'endswith(".tar.gz") and contains("linux-musl") and contains($arch)' "$ARCH")"

TARBALL="${FB_TMP}/xh.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"
SRC_DIR="${FB_TMP}/${BIN_NAME}-${TAG_NAME}-${ARCH}-unknown-${OS}-musl"

install_bin "${SRC_DIR}/${BIN_NAME}" "$BIN_NAME" --version

fb_install_completions "$BIN_NAME" \
    "${SRC_DIR}/completions/_xh" \
    "${SRC_DIR}/completions/xh.bash"

echo "Installed xh ${VERSION} (musl tarball) -> ${BIN_DIR}/${BIN_NAME}"
