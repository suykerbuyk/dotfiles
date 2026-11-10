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

# --- code-mode companion ------------------------------------------------------
# codex's "code mode" launches a helper named `codex-code-mode-host` from the
# directory of its OWN resolved binary: it reads /proc/self/exe (so it follows
# the ~/.local/bin/codex -> ~/.local/apps/codex-<ver> symlink to the real file)
# and looks for a SIBLING `codex-code-mode-host` in ~/.local/apps. So the
# companion is an APP_DIR payload, NOT a ~/.local/bin tool — it never goes on
# PATH. It ships as its own release asset at the SAME tag, inner binary
# codex-code-mode-host-<triple> (carries the triple, like codex-<triple>).
#
# Placement: versioned payload codex-code-mode-host-<ver> + a stable sibling
# symlink codex-code-mode-host -> it. This matches the repo's versioned-payload
# norm (prune/teardown by codex-code-mode-host-[0-9]*), and codex execs the
# sibling, so the symlink is followed by execve (verified empirically on this
# host — see the slot task report). The symlink target is RELATIVE so it resolves
# regardless of $HOME.
CMH_NAME="codex-code-mode-host"
CMH_FINAL="${APP_DIR}/${CMH_NAME}-${VERSION}"
CMH_LINK="${APP_DIR}/${CMH_NAME}"

# Runs --version (or --help) as a liveness probe; either is enough to prove the
# binary executes.
_cmh_probe() { "$1" --version >/dev/null 2>&1 || "$1" --help >/dev/null 2>&1; }

# Install the companion. Called on BOTH the fast path (codex already current) and
# the install path, because a host that already had codex but never had the
# companion must still get it — the fast-path `exit 0` is before here otherwise.
# Only the DOWNLOAD is skipped when the exact versioned payload is already there.
install_code_mode_host() {
    if [[ -x "$CMH_FINAL" ]] && _cmh_probe "$CMH_FINAL"; then
        ln -sfn "${CMH_NAME}-${VERSION}" "$CMH_LINK"
        echo "${CMH_NAME} ${VERSION} already installed; sibling symlink ensured."
        return 0
    fi

    local url tb stage
    # Exact-name match, same reasoning as the main asset: the release is full of
    # sibling tarballs and .zst/.sigstore twins.
    url="$(gh_asset_url openai/codex \
        '. == ("codex-code-mode-host-" + $arch + ".tar.gz")' "$TRIPLE" "" "$PIN_TAG")"
    tb="${FB_TMP}/${CMH_NAME}.tar.gz"
    gh_download "$url" "$tb"
    # Integrity before the companion tarball is extracted.
    fb_verify_gh_digest "$tb" openai/codex "$url" "$PIN_TAG"
    tar -xzf "$tb" -C "$FB_TMP"

    # Stage beside the destination (same filesystem -> atomic publish), verify
    # the staged binary runs, then publish and link the sibling.
    stage="$(fb_stage_payload "$CMH_FINAL")"
    cp "${FB_TMP}/${CMH_NAME}-${TRIPLE}" "$stage"
    chmod +x "$stage"
    if ! _cmh_probe "$stage"; then
        echo "Error: ${CMH_NAME} failed its liveness probe (neither --version nor --help ran)." >&2
        rm -f "$stage"
        exit 1
    fi
    fb_publish_payload "$stage" "$CMH_FINAL"
    ln -sfn "${CMH_NAME}-${VERSION}" "$CMH_LINK"
    echo "Installed ${CMH_NAME} ${VERSION} -> ${CMH_FINAL}"
    echo "  (sibling symlink ${CMH_LINK} -> ${CMH_NAME}-${VERSION})"
    fb_prune_versions "$CMH_FINAL" "" "${CMH_NAME}-[0-9]*"
}

# Fast path, BEFORE the download: the version is already in hand, so there is
# nothing to learn from spending 117 MB. The bare `codex` glob is the legacy
# unversioned payload this slot would migrate off; -[0-9] rather than a bare -*,
# per fb_prune_versions. The companion is still provisioned here — codex being
# current does not mean its code-mode host is installed.
if fb_versioned_current "$BIN_NAME" "$VERSION" --version; then
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*"
    install_code_mode_host
    exit 0
fi

# DEVIATION 2: exact equality, not startswith — the release carries
# codex-app-server-<triple>.tar.gz, codex-exec-<triple>.tar.gz, bwrap-…,
# argument-comment-lint-…, plus a .zst and a .sigstore beside every tarball.
ASSET_URL="$(gh_asset_url openai/codex \
    '. == ("codex-" + $arch + ".tar.gz")' "$TRIPLE" "" "$PIN_TAG")"

TARBALL="${FB_TMP}/codex.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"
# Integrity before the main tarball is extracted. The companion is verified separately
# inside install_code_mode_host; the .sigstore bundles are a follow-on.
fb_verify_gh_digest "$TARBALL" openai/codex "$ASSET_URL" "$PIN_TAG"
tar -xzf "$TARBALL" -C "$FB_TMP"

# DEVIATION 3: the extracted file is codex-<triple>; install it AS `codex`.
CODEX_PREV="$(fb_prev_payload "$BIN_NAME")"
install_versioned_bin "${FB_TMP}/codex-${TRIPLE}" "$BIN_NAME" "$VERSION" --version
fb_prune_versions "$PAYLOAD" "$CODEX_PREV" "${BIN_NAME}-[0-9]*"

# The code-mode companion, at the same version/tag as the codex we just installed.
install_code_mode_host
