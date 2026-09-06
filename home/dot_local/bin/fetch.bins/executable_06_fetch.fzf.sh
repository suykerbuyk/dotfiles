#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# fzf installer (CLI/TUI). Uses lib for GitHub helpers, temp discipline,
# verification, and safety guard.
#
# VERSIONED PAYLOAD, not install_bin (phase 5 of the version-blindness fix).
# install_bin gates on fb_check_bin, which compares no version, so once
# ~/.local/bin/fzf resolved this slot could never upgrade — and it downloaded the
# 4.8 MB tarball first and discarded it, on every installer run.
#
# ^R BELONGS TO fzf, and that is a ruling (iter 44): the rebind at the end of
# dotfiles_tool_init is load-bearing, not cleanup. Nothing in this fetcher may
# install a keybinding of its own.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="fzf"
fb_init
fb_require_os

OS="$(fb_os)"
ARCH="$(fb_arch amd64)"  # fzf uses amd64/arm (armv7l->arm)
ARCH_FOR_FZF="${ARCH/armv7l/arm}"  # extra normalization

# FB_PIN_FZF holds a version; PIN_TAG carries it through to the asset lookup and
# is EMPTY otherwise, so the unpinned path keeps reading the one cached
# /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
#
# fzf's tags carry no 'v' prefix, so the pinned tag is the version verbatim.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="$VERSION"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag junegunn/fzf)"
    VERSION="${TAG_NAME#v}"  # no 'v' prefix
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
    exit 0
fi

# Asset pattern: fzf-${VERSION}-${os}_${arch}.tar.gz
#
# $os IS RESOLVED, not hardcoded, and that is a fix (2026-09-05). This filter
# read contains("linux") while OS="$(fb_os)" sat two lines above it, computed and
# never compared to anything — the same dead-value shape as slot 23's
# OP_FETCH_VERSION. fb_supported_os declares fzf `linux darwin freebsd`, so on
# FreeBSD the slot downloaded fzf-<ver>-linux_amd64.tar.gz, installed a Linux
# ELF, and the verification probe rejected it. Upstream ships
# fzf-<ver>-freebsd_amd64.tar.gz; nothing was ever selecting it. Measured on
# FreeBSD 15.1 (vault01), where it is the only FreeBSD-declared GitHub slot that
# hardcoded an OS token — 04, 09 and 13 all resolve theirs.
#
# endswith(".tar.gz") is the fd/bat/xh anchor, for the same reason: upstream also
# publishes fzf_<ver>_<arch>.deb. No .deb carries an OS token today, so the os
# clause alone excludes them — but that is luck, not a guard.
ASSET_URL="$(gh_asset_url junegunn/fzf \
    'endswith(".tar.gz") and contains($os) and contains($arch)' "$ARCH_FOR_FZF" "$OS" "$PIN_TAG")"

TARBALL="${FB_TMP}/fzf.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"

# Hand install_versioned_bin the extracted binary in FB_TMP; it copies to the
# versioned payload itself. Pre-moving it to the payload path makes src and the
# destination the same file, which the helper refuses outright — install_bin's
# old failure mode here was worse: `cp` died, and under set -e so did the script,
# leaving the runtime installed and nothing on PATH. That silently broke fzf.
FZF_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$FZF_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
