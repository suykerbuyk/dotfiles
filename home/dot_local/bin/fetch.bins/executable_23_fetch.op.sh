#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# 1Password CLI (op v2) installer.
#
# Follows the tsh (slot 22) and herdr patterns closely. Key differences from
# the ripgrep-style fetchers:
#
# - Uses AgileBits CDN directly (predictable URL, no GitHub API).
# - Ships as a simple .zip containing a single static binary (no tarball,
#   no nested dirs).
# - Pinned to v2.39.0 (the version you already downloaded). Easy to bump.
# - Uses fb_unzip (already battle-tested by broot, ninja, etc.).
# - No special post-install (no setgid, no groupadd) — those belong in
#   documentation or a separate desktop integration step.
#
# Set OP_FETCH_VERSION=2.x.y to override the pinned version.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="op"
fb_init

VERSION="${OP_FETCH_VERSION:-2.39.0}"
OS="$(fb_os)"
ARCH="$(fb_arch)"

if [[ "$OS" != "linux" ]]; then
    echo "Error: this fetcher currently supports only linux (got '$OS')." >&2
    echo "       macOS/Windows users should use the official 1Password installer." >&2
    exit 1
fi

if [[ "$ARCH" != "amd64" ]]; then
    echo "Error: this fetcher is currently amd64-only (got '$ARCH')." >&2
    echo "       arm64 support can be added later using op_linux_arm64_*.zip." >&2
    exit 1
fi

ASSET_URL="https://cache.agilebits.com/dist/1P/op2/pkg/v${VERSION}/op_linux_amd64_v${VERSION}.zip"

ZIP="${FB_TMP}/op.zip"
curl -fL -o "$ZIP" "$ASSET_URL"

# Extract directly to $FB_TMP — the zip contains only the 'op' binary
fb_unzip "$ZIP" "$FB_TMP"

install_bin "${FB_TMP}/op" "$BIN_NAME" --version

echo "Installed op ${VERSION} -> ${BIN_DIR}/${BIN_NAME}"
echo "Run 'op-login' (added to shell rc) to authenticate with your 1Password account."
