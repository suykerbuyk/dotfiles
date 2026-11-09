#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# codex installer (OpenAI Codex CLI). Single static musl binary in a .tar.gz,
# so this is the plain versioned-payload pattern — same shape as slot 13
# starship. Three deviations from that template, all measured (2026-11-09):
#
# 1. THE TAG IS `rust-v<version>`, NOT `v<version>`. openai/codex publishes
#    many products from one repo (codex, codex-app-server, codex-exec, bwrap,
#    argument-comment-lint …) and tags the CLI release `rust-v0.167.0`. So the
#    strip is `${TAG_NAME#rust-v}` and the pinned path rebuilds `rust-v${VERSION}`
#    — NOT the `v${VERSION}` / `${TAG_NAME#v}` idiom the other slots share.
#
# 2. EXACT-NAME asset match, not `startswith`/`contains`. The release is full of
#    sibling binaries (codex-app-server-<triple>.tar.gz, codex-exec-…, bwrap-…)
#    and of `.zst` + `.sigstore` twins beside every tarball. `. == ("codex-" +
#    $arch + ".tar.gz")` selects ONLY ours, exactly as starship's `==` does.
#
# 3. THE INNER BINARY CARRIES THE TRIPLE. `tar tzf codex-x86_64-unknown-linux-
#    musl.tar.gz` holds one file named `codex-x86_64-unknown-linux-musl`, not
#    `codex`. We hand that path to install_versioned_bin as `codex`, which owns
#    the copy into ~/.local/apps and the ~/.local/bin/codex symlink.
#
# VERSIONED PAYLOAD, not install_bin (the version-blindness fix): install_bin
# gates on fb_check_bin, which compares no version, so once ~/.local/bin/codex
# resolved this slot could never upgrade — and it would download the 117 MB
# tarball first and discard it, on every installer run.
#
# Arch tokens are full Rust target triples, so this uses fb_rust_triple (NOT
# fb_arch, NOT raw uname -m) — same as starship. The musl build is preferred:
# it is fully static, and it is the build upstream publishes for both linux
# arches, so one selector covers x86_64 and aarch64.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="codex"
fb_init
fb_require_os

# codex names assets by full Rust target triple, so ask for one rather than
# gluing `uname -m` to a hardcoded suffix.
TRIPLE="$(fb_rust_triple musl)"

# FB_PIN_CODEX holds a bare version (0.167.0); PIN_TAG carries the tag through to
# the asset lookup and is EMPTY otherwise, so the unpinned path keeps reading the
# one cached /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
#
# DEVIATION 1: the tag prefix is `rust-v`, not `v`.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="rust-v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag openai/codex)"
    VERSION="${TAG_NAME#rust-v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending 117 MB. The bare `codex` glob is the legacy
# unversioned payload this slot would migrate off; -[0-9] rather than a bare -*,
# per fb_prune_versions.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*"
    exit 0
fi

# DEVIATION 2: exact equality, not startswith — the release carries
# codex-app-server-<triple>.tar.gz, codex-exec-<triple>.tar.gz, bwrap-…,
# argument-comment-lint-…, plus a .zst and a .sigstore beside every tarball.
ASSET_URL="$(gh_asset_url openai/codex \
    '. == ("codex-" + $arch + ".tar.gz")' "$TRIPLE" "" "$PIN_TAG")"

TARBALL="${FB_TMP}/codex.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"
tar -xzf "$TARBALL" -C "$FB_TMP"

# DEVIATION 3: the extracted file is codex-<triple>; install it AS `codex`.
CODEX_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${FB_TMP}/codex-${TRIPLE}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$CODEX_PREV" "${BIN_NAME}-[0-9]*"
