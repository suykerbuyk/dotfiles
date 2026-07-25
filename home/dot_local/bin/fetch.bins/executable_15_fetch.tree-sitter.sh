#!/usr/bin/env bash
set -euo pipefail

# tree-sitter CLI installer. Required by nvim-treesitter's main branch (>=
# 0.26.1), which generates/compiles parser grammars with it. Single static
# binary shipped as a bare .gz (no tarball), so this is the plain install_bin
# pattern — same shape as starship, with gunzip instead of tar.
#
# Arch tokens are node-style (x64 / arm64), NOT uname or go tokens, so map
# `uname -m` explicitly. The bare `tree-sitter-linux-<arch>.gz` is preferred
# over the `tree-sitter-cli-*.zip` twin so extraction needs no fb_unzip.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="tree-sitter"
fb_init

case "$(uname -m)" in
    x86_64)  ARCH="x64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Error: unsupported architecture '$(uname -m)' for tree-sitter." >&2; exit 1 ;;
esac

TAG_NAME="$(gh_latest_tag tree-sitter/tree-sitter)"
VERSION="${TAG_NAME#v}"

# Asset: tree-sitter-linux-<arch>.gz (bare gzipped binary, exact name)
ASSET_URL="$(gh_asset_url tree-sitter/tree-sitter \
    '. == ("tree-sitter-linux-" + $arch + ".gz")' "$ARCH")"

GZ="${FB_TMP}/tree-sitter.gz"
gh_download "$ASSET_URL" "$GZ"
gunzip -f "$GZ"  # yields ${FB_TMP}/tree-sitter

install_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" --version

echo "Installed tree-sitter ${VERSION} (parser CLI for nvim-treesitter) -> ${BIN_DIR}/${BIN_NAME}"
