#!/usr/bin/env bash
set -euo pipefail

# Bootstrap installer for jq. This runs FIRST and must NOT depend on jq itself.
# Sourced from _lib.sh (uses only the jq-free helpers).
# See Context.fetch.bins.refactor.md for full design and verified facts.
# The stow safety guard (in fb_init) ensures we never run from inside the
# dotfiles checkout.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="jq"
fb_init

# Per-tool normalization (jq wants "macos" not "darwin", amd64 not x86_64)
OS="$(fb_os macos)"
ARCH="$(fb_arch amd64)"
echo "OS=$OS ARCH=$ARCH"

TAG_NAME="$(gh_latest_tag_nojq jqlang/jq)"
BINARY="jq-${OS}-${ARCH}"
DOWNLOAD_URL="https://github.com/jqlang/jq/releases/download/${TAG_NAME}/${BINARY}"
echo "DOWNLOAD_URL=$DOWNLOAD_URL"

# Download directly to a temporary name inside APP_DIR (no archive)
TMP_BIN="${APP_DIR}/${BIN_NAME}.tmp"
gh_download "$DOWNLOAD_URL" "$TMP_BIN"

# install_bin handles chmod, verification, ln -sfn, and confirmation
install_bin "$TMP_BIN" "$BIN_NAME" --version
