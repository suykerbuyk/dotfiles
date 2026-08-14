#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# bat installer (a `cat` clone with syntax highlighting and git integration;
# Rust, MIT OR Apache-2.0, sharkdp/bat). Same shape as fd (slot 18) — a plain
# single-binary release tarball on the ripgrep (slot 03) pattern.
#
# Arch tokens are RAW `uname -m` (x86_64 / aarch64), so fb_arch is unusable
# here: its sed hardcodes `s/aarch64/arm64/` regardless of the label it is
# given, and can therefore NEVER emit `aarch64`. Routing through it would 404 on
# every arm64 box while passing forever on x86_64. Uses `uname -m` directly.
#
# The endswith(".tar.gz") anchor matters more for bat than for any sibling:
# bat's .deb names contain BOTH tokens this filter looks for —
# `bat-musl_0.26.1_musl-linux-amd64.deb` carries the literal string
# "musl-linux-amd64", so `contains("linux-musl")` misses it but a sloppier
# variant would not. The extension anchor is what actually guarantees
# install_bin never receives a .deb.
#
# TAG vs VERSION: the tarball's inner directory carries the tag VERBATIM
# (bat-v0.26.1-x86_64-unknown-linux-musl), so it needs ${TAG_NAME} with the "v",
# not the ${VERSION} ripgrep uses. delta (slot 20) is the opposite case. See the
# fuller note in 18_fetch.fd.sh.
#
# COMPLETIONS: bat is the reason fb_install_completions renames unconditionally.
# Its zsh completion ships as `autocomplete/bat.zsh`, NOT `_bat`. zsh's $fpath
# autoloading keys on the leading-underscore convention, so installed under its
# shipped name the file would simply never load — silently, with no error and
# nothing to grep for. The helper installs it as `_bat`.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="bat"
fb_init

OS="$(fb_os)"
ARCH="$(uname -m)"  # x86_64 | aarch64 — matches bat's asset names as-is

TAG_NAME="$(gh_latest_tag sharkdp/bat)"
VERSION="${TAG_NAME#v}"

# Asset: bat-${TAG_NAME}-${ARCH}-unknown-${OS}-musl.tar.gz
ASSET_URL="$(gh_asset_url sharkdp/bat \
    'endswith(".tar.gz") and contains("linux-musl") and contains($arch)' "$ARCH")"

TARBALL="${FB_TMP}/bat.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"
SRC_DIR="${FB_TMP}/${BIN_NAME}-${TAG_NAME}-${ARCH}-unknown-${OS}-musl"

install_bin "${SRC_DIR}/${BIN_NAME}" "$BIN_NAME" --version

# bat.zsh -> _bat is the load-bearing rename; the helper owns it.
fb_install_completions "$BIN_NAME" \
    "${SRC_DIR}/autocomplete/bat.zsh" \
    "${SRC_DIR}/autocomplete/bat.bash"

echo "Installed bat ${VERSION} (musl tarball) -> ${BIN_DIR}/${BIN_NAME}"
