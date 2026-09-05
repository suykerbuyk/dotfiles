#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# fd installer (fast, user-friendly `find` replacement; Rust, MIT OR Apache-2.0,
# sharkdp/fd). Plain single-binary release tarball — the ripgrep (slot 03)
# pattern — plus the completion install that slots 18-21 share.
#
# Arch tokens are RAW `uname -m` (x86_64 / aarch64), so fb_arch is unusable
# here: its sed hardcodes `s/aarch64/arm64/` regardless of the label it is
# given, and can therefore NEVER emit `aarch64`. Routing through it would 404 on
# every arm64 box while passing forever on x86_64 — the failure is invisible
# from an amd64 machine. Same trap as herdr and starship, handled the same way:
# `uname -m` directly.
#
# The asset filter is anchored with endswith(".tar.gz") on purpose. fd also
# publishes .deb files whose names contain "musl" (fd-musl_10.4.2_amd64.deb).
# Their arch tokens are Debian-style (amd64/arm64), so a raw `uname -m` value
# excludes them today — but that is luck, not a guard, and handing install_bin
# a .deb is not a failure mode worth leaving open. "linux-musl" is likewise
# deliberate over a bare "musl": the latter also matches the armv7
# `musleabihf` builds.
#
# TAG vs VERSION — read this before "simplifying" it. The directory inside the
# tarball carries the tag VERBATIM:
#     fd-v10.4.2-x86_64-unknown-linux-musl/fd
# so it interpolates ${TAG_NAME}, WITH the leading "v". ripgrep's idiom of
# stripping to ${VERSION} is wrong for fd. delta (slot 20) is the mirror image —
# its upstream tag has no "v" at all, so it needs ${VERSION}. The asymmetry
# between the two is real and per-project; it is not a bug to be tidied away.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="fd"
fb_init
fb_require_os

OS="$(fb_os)"
ARCH="$(uname -m)"  # x86_64 | aarch64 — matches fd's asset names as-is

TAG_NAME="$(gh_latest_tag sharkdp/fd)"
VERSION="${TAG_NAME#v}"

# Asset: fd-${TAG_NAME}-${ARCH}-unknown-${OS}-musl.tar.gz
ASSET_URL="$(gh_asset_url sharkdp/fd \
    'endswith(".tar.gz") and contains("linux-musl") and contains($arch)' "$ARCH")"

TARBALL="${FB_TMP}/fd.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"
SRC_DIR="${FB_TMP}/${BIN_NAME}-${TAG_NAME}-${ARCH}-unknown-${OS}-musl"

install_bin "${SRC_DIR}/${BIN_NAME}" "$BIN_NAME" --version

# Generate from the INSTALLED binary, not the extracted tarball -- slot 20's
# rule (see 20_fetch.delta.sh). install_bin's fb_check_bin gate is version-blind,
# so on any run where it printed "already valid (skipping)" the tree under
# $SRC_DIR is a NEWER fd than the one on PATH; installing the tarball's
# completion files there would describe flags the installed binary does not
# implement. Generating from the binary on PATH keeps the two halves in
# agreement whichever version is actually installed.
#
# Guarded, unlike slot 20's: --gen-completions is a HIDDEN flag,
# absent from `fd --help`, so it is the likeliest of the three to disappear. A failed or empty
# generation drops the file so fb_install_completions warns and leaves the
# PREVIOUSLY installed completions -- which match the binary on PATH -- in
# place. The -s test matters because `cmd > file` creates the file even when cmd
# fails, and a truncated file is still -r.
"${BIN_DIR}/${BIN_NAME}" --gen-completions zsh  > "${FB_TMP}/_fd"     2>/dev/null || true
[[ -s "${FB_TMP}/_fd" ]]     || rm -f "${FB_TMP}/_fd"
"${BIN_DIR}/${BIN_NAME}" --gen-completions bash > "${FB_TMP}/fd.bash" 2>/dev/null || true
[[ -s "${FB_TMP}/fd.bash" ]] || rm -f "${FB_TMP}/fd.bash"
fb_install_completions "$BIN_NAME" \
    "${FB_TMP}/_fd" \
    "${FB_TMP}/fd.bash"

echo "Installed fd ${VERSION} (musl tarball) -> ${BIN_DIR}/${BIN_NAME}"
