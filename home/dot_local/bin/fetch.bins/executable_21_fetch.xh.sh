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
fb_require_os

OS="$(fb_os)"
ARCH="$(uname -m)"  # x86_64 | aarch64 — matches xh's asset names as-is

# Generate from the INSTALLED binary, not the extracted tarball -- slot 20's
# rule (see 20_fetch.delta.sh). The extracted tree under $SRC_DIR is whatever
# upstream currently ships, which on a fast-path run is NOT what is on PATH;
# installing the tarball's completion files there would describe flags the
# installed binary does not implement. Generating from the binary on PATH keeps
# the two halves in agreement whichever version is actually installed.
#
# A FUNCTION, called from BOTH paths, because the fast path below exits before
# reaching the install. Completions are a per-machine build artifact that nothing
# else reproduces, so a fast-path run that skipped them would stop self-healing a
# hand-deleted completion file — the same reason slot 16 re-installs its terminfo
# and desktop entry on its fast path.
#
# Guarded, unlike slot 20's: `xh --generate <KIND>` is documented; the KIND is
# complete-zsh / complete-bash, NOT a bare shell name. A failed or empty
# generation drops the file so fb_install_completions warns and leaves the
# PREVIOUSLY installed completions -- which match the binary on PATH -- in place.
# The -s test matters because `cmd > file` creates the file even when cmd fails,
# and a truncated file is still -r.
refresh_completions() {
    "${BIN_DIR}/${BIN_NAME}" --generate complete-zsh  > "${FB_TMP}/_xh"     2>/dev/null || true
    [[ -s "${FB_TMP}/_xh" ]]     || rm -f "${FB_TMP}/_xh"
    "${BIN_DIR}/${BIN_NAME}" --generate complete-bash > "${FB_TMP}/xh.bash" 2>/dev/null || true
    [[ -s "${FB_TMP}/xh.bash" ]] || rm -f "${FB_TMP}/xh.bash"
    fb_install_completions "$BIN_NAME" \
        "${FB_TMP}/_xh" \
        "${FB_TMP}/xh.bash"
}

# FB_PIN_XH holds a version; PIN_TAG carries it through to the asset lookup and
# is EMPTY otherwise, so the unpinned path keeps reading the one cached
# /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag ducaale/xh)"
    VERSION="${TAG_NAME#v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending the transfer. The bare `xh` glob is the legacy
# unversioned payload this slot is migrating off; -[0-9] rather than a bare -*,
# per fb_prune_versions.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*" "$BIN_NAME"
    refresh_completions
    exit 0
fi

# Asset: xh-${TAG_NAME}-${ARCH}-unknown-${OS}-musl.tar.gz
ASSET_URL="$(gh_asset_url ducaale/xh \
    'endswith(".tar.gz") and contains("linux-musl") and contains($arch)' "$ARCH" "" "$PIN_TAG")"

TARBALL="${FB_TMP}/xh.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"
SRC_DIR="${FB_TMP}/${BIN_NAME}-${TAG_NAME}-${ARCH}-unknown-${OS}-musl"

XH_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${SRC_DIR}/${BIN_NAME}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$XH_PREV" "${BIN_NAME}-[0-9]*" "$BIN_NAME"

refresh_completions
