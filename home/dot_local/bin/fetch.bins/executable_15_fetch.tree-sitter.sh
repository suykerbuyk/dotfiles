#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# tree-sitter CLI installer. Required by nvim-treesitter's main branch (>=
# 0.26.1), which generates/compiles parser grammars with it. Single static
# binary shipped as a bare .gz (no tarball), so this is the plain
# versioned-payload pattern — same shape as starship, with gunzip instead of tar.
#
# VERSIONED PAYLOAD, not install_bin (phase 5 of the version-blindness fix).
# install_bin gates on fb_check_bin, which compares no version, so once
# ~/.local/bin/tree-sitter resolved this slot could never upgrade — and it
# downloaded the 26 MB payload first and discarded it, on every installer run.
# That is the largest single re-download in the tree, and this tool is the one
# nvim-treesitter's main branch compiles every parser grammar with.
#
# Arch tokens are node-style (x64 / arm64), NOT uname or go tokens, so map
# `uname -m` explicitly. The bare `tree-sitter-linux-<arch>.gz` is preferred
# over the `tree-sitter-cli-*.zip` twin so extraction needs no fb_unzip.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="tree-sitter"
fb_init
fb_require_os

case "$(uname -m)" in
    x86_64)  ARCH="x64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Error: unsupported architecture '$(uname -m)' for tree-sitter." >&2; exit 1 ;;
esac

# FB_PIN_TREE_SITTER holds a version (fb_pin normalizes the hyphen); PIN_TAG
# carries it through to the asset lookup and is EMPTY otherwise, so the unpinned
# path keeps reading the one cached /releases/latest document instead of opening
# a second entry at /releases/tags/<tag> for the tag it just read from it. The
# `||` after fb_pin is load-bearing under set -e: it returns 1 when unset.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag tree-sitter/tree-sitter)"
    VERSION="${TAG_NAME#v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending 26 MB. The bare `tree-sitter` glob is the legacy
# unversioned payload this slot is migrating off; -[0-9] rather than a bare -*,
# per fb_prune_versions.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
    exit 0
fi

# Asset: tree-sitter-linux-<arch>.gz (bare gzipped binary, exact name)
ASSET_URL="$(gh_asset_url tree-sitter/tree-sitter \
    '. == ("tree-sitter-linux-" + $arch + ".gz")' "$ARCH" "" "$PIN_TAG")"

GZ="${FB_TMP}/tree-sitter.gz"
gh_download "$ASSET_URL" "$GZ"
gunzip -f "$GZ"  # yields ${FB_TMP}/tree-sitter

TS_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$TS_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
