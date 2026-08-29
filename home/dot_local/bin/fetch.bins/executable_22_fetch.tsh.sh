#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# Teleport client tools (tsh, tctl) installer.
#
# Five ways this slot is unlike the ripgrep template. All five are measured, and
# every one of them will read as a bug to someone arriving from another fetcher.
#
# 1. NO GITHUB, AT ALL. Teleport publishes on cdn.teleport.dev, not as GitHub
#    release assets, so gh_latest_tag / gh_latest_tag_nojq / gh_asset_url are
#    all unused. Only gh_download is called, and that is a plain URL fetcher
#    despite the gh_ prefix. This is the one fetcher in the tree that cannot be
#    GitHub-rate-limited -- the failure mode every other slot guards against.
#
# 2. THE VERSION COMES FROM THE CLUSTER, NOT FROM UPSTREAM LATEST. A client
#    matching its own proxy avoids tsh's version-skew warnings by construction.
#    Being unable to read it is a HARD FAIL with the reason, never a pinned
#    floor: a silently stale client is how skew warnings start. update.teleport.sh
#    already reads this endpoint's sibling (/v1/webapi/ping .server_version) for
#    the same purpose, so the pattern is established in-repo.
#
# 3. fb_arch IS CORRECT HERE -- the exact opposite of slots 17-21. Those five
#    all document fb_arch as a trap, because herdr/fd/bat/delta/xh name assets
#    with raw `uname -m` tokens while fb_arch's sed rewrites aarch64 to arm64.
#    Teleport uses amd64/arm64, which is precisely what fb_arch emits. Both
#    measured 200 on 2026-08-20:
#      https://cdn.teleport.dev/teleport-v18.10.1-linux-amd64-bin.tar.gz
#      https://cdn.teleport.dev/teleport-v18.10.1-linux-arm64-bin.tar.gz
#    Do NOT "correct" this to raw `uname -m`: that 404s on arm64 and the damage
#    is invisible from an x86_64 box.
#
# 4. IT DEFERS TO A SYSTEM-WIDE tsh, and installs nothing when it finds one.
#    Teleport's vendor installer writes /usr/local/bin/tsh; a box provisioned
#    that way needs nothing from us. See the guard below.
#
# 5. IT INSTALLS NO COMPLETIONS, deliberately. tsh is kingpin-based and does
#    emit --completion-script-zsh, but the output is malformed: the #compdef
#    directive carries no command name and the generated function is literally
#    `_`. Installed as-is, zsh either ignores the file or defines a garbage
#    completer, and either way it fails SILENTLY. bat's bat.zsh -> _bat rename
#    is this tree's cautionary tale about completion naming; this is worse than
#    a rename, so the honest move is to ship none until the output is fixed
#    upstream or rewritten here on purpose.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="tsh"
fb_init
fb_require_os

PROXY="${TSH_FETCH_PROXY:-syketech.com}"

# ----------------------------------------------------------------------
# Defer to a system-wide install.
#
# Teleport's own installer (`curl https://goteleport.com/static/install.sh |
# bash`) writes /usr/local/bin/tsh, and some hosts carry a packaged copy. When a
# WORKING tsh already exists outside this tree, a second copy in ~/.local/bin
# would SHADOW it -- the env layer puts ~/.local/bin ahead of /usr/local/bin --
# and we would take over an upgrade treadmill for a tool the box already
# maintains, for a 207 MB download per machine.
#
# The probe is `tsh version`: `tsh --version` is a hard error (see header note
# 5 -- kingpin). It is also network-free, measured exit 0 with no profile and no
# proxy reachable, so this stays cheap and works offline.
#
# fb_system_bin is what makes this safe on run 2..n: ~/.local/bin is on PATH
# (fb_init puts it there), so a bare `command -v tsh` would find OUR OWN symlink
# and skip forever after the first install.
#
# Set TSH_FETCH_FORCE=1 to install a user-local copy regardless.
# ----------------------------------------------------------------------
if [[ "${TSH_FETCH_FORCE:-0}" != "1" ]]; then
    if SYSTEM_TSH="$(fb_system_bin "$BIN_NAME" version)"; then
        echo "tsh: already provided system-wide at ${SYSTEM_TSH} — skipping."
        echo "  $("$SYSTEM_TSH" version 2>&1 | head -1)"
        echo "  Set TSH_FETCH_FORCE=1 to install a user-local copy anyway."
        exit 0
    fi
fi

OS="$(fb_os)"
ARCH="$(fb_arch)"   # amd64 / arm64 — Teleport's own tokens; see header note 3

# The URL shape below is the linux tarball. macOS ships a signed .pkg under a
# different name, so guess nothing: fail with the reason rather than 404 on a
# URL this fetcher was never built to produce.
if [[ "$OS" != "linux" ]]; then
    echo "Error: this fetcher builds linux tarball URLs only (got OS '$OS')." >&2
    echo "       On macOS, install the signed .pkg from goteleport.com; this" >&2
    echo "       fetcher then defers to it." >&2
    exit 1
fi

# Cluster-pinned version. jq is slot 01, so fetcher ordering guarantees it here.
FIND_URL="https://${PROXY}/v1/webapi/find"
VERSION="$(curl -fsSL --max-time 15 "$FIND_URL" 2>/dev/null \
    | jq -r '.auto_update.tools_version // empty' 2>/dev/null || true)"

if [[ -z "$VERSION" ]]; then
    echo "Error: could not read the client-tools version from ${FIND_URL}." >&2
    echo "       The cluster is this fetcher's only version source, so there is" >&2
    echo "       nothing safe to install — a hardcoded fallback would quietly" >&2
    echo "       stage a skewed client, which is the thing pinning exists to" >&2
    echo "       prevent. Restore connectivity and re-run, or install tsh" >&2
    echo "       system-wide (this fetcher then defers to it)." >&2
    exit 1
fi

# install_bin's fb_check_bin gate is version-BLIND: once ~/.local/bin/tsh
# resolves to an executable it reports "already valid" and returns. For a
# cluster-pinned tool that would pin only the FIRST install and then never move
# again, leaving a header that claims pinning above code that stopped doing it.
# So compare versions here and clear the links when they differ.
#
# This is an UPGRADE path, never a gate: a mismatch is never a refusal. Skew is
# a tidiness goal, not a correctness one — v18.10.4 clients and an 18.10.1 proxy
# interoperated cleanly when measured on 2026-08-20, including headless SSH.
installed_version() {
    local p="${BIN_DIR}/$1"
    [[ -x "$p" ]] || return 1
    "$p" version 2>/dev/null | sed -n '1s/^Teleport v\([^ ]*\).*/\1/p'
}

CURRENT_TSH="$(installed_version tsh   || true)"
CURRENT_TCTL="$(installed_version tctl || true)"

# Fast path, and it is load-bearing: the installer runs every fetcher on every
# Phase-5 pass, and the asset is ~207 MB. Deciding this AFTER gh_download would
# re-pull a fifth of a gigabyte on each run only for install_bin to answer
# "already valid (skipping)". This is the same reason slot 16 keeps a versioned
# ghostty AppImage. Both tools are checked: a present tsh with a missing tctl
# must still reach the install below, not exit here.
if [[ "$CURRENT_TSH" == "$VERSION" && "$CURRENT_TCTL" == "$VERSION" ]]; then
    echo "tsh/tctl ${VERSION} already installed and matching ${PROXY} — nothing to do."
    exit 0
fi

if [[ -n "${CURRENT_TSH}${CURRENT_TCTL}" ]]; then
    echo "→ installed tsh=${CURRENT_TSH:-none} tctl=${CURRENT_TCTL:-none}, cluster wants ${VERSION} — replacing."
    # Clear BOTH links and BOTH payloads: install_bin's fb_check_bin gate is
    # version-blind, so a surviving same-named binary would be reported "already
    # valid" and the upgrade would silently no-op.
    rm -f "${BIN_DIR}/tsh" "${BIN_DIR}/tctl" \
          "${APP_DIR}/tsh"  "${APP_DIR}/tctl"
fi

ASSET_URL="https://cdn.teleport.dev/teleport-v${VERSION}-${OS}-${ARCH}-bin.tar.gz"

TARBALL="${FB_TMP}/teleport.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

# Extract ONLY the two client binaries. The tarball is ~207 MB and carries the
# server (teleport, tbot, fdpass-teleport), a root system installer, and the
# whole examples/ tree; unpacking all of that to keep two files is pure waste.
# Naming both members explicitly also means a future tarball that DROPS one
# fails here, loudly and by name, instead of at install_bin's verify gate.
#
# NEVER run the bundled teleport/install script: it is a root, system-wide
# installer, and this tree is rootless-by-contract (see slot 12, podman).
tar -xzf "$TARBALL" -C "$FB_TMP" teleport/tsh teleport/tctl
SRC_DIR="${FB_TMP}/teleport"

# `version` is a SUBCOMMAND, not a flag. install_bin uses this argv both for its
# verification gate and for the version line it prints, so passing --version
# here would fail the install outright.
#
# tctl comes along because update.teleport.sh calls it and it is client-side
# admin tooling. The server binaries deliberately stay in the tarball.
install_bin "${SRC_DIR}/tsh"  tsh  version
install_bin "${SRC_DIR}/tctl" tctl version

echo "Installed Teleport client tools v${VERSION} (pinned to ${PROXY}) -> ${BIN_DIR}/{tsh,tctl}"
