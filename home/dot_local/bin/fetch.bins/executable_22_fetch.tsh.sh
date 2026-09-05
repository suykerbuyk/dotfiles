#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# Teleport client tools (tsh, tctl) installer.
#
# Six ways this slot is unlike the ripgrep template. All six are measured, and
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
#
# 6. IT BYPASSES install_bin AND KEEPS BOTH BINARIES IN ONE VERSIONED
#    DIRECTORY: ${APP_DIR}/teleport-<version>/{tsh,tctl}.
#
#    install_bin's fb_check_bin gate is version-BLIND: once ~/.local/bin/tsh
#    resolves to an executable it answers "already valid (skipping)" and
#    returns, which would pin only the FIRST install of a cluster-pinned tool
#    and then never move again.
#
#    This slot used to defeat that gate by PARSING the installed binary's
#    version out of `tsh version`, which made one sed the single point of
#    failure for the entire upgrade path. When the parse returned empty both
#    downstream guards failed OPEN, in opposite directions: the fast path could
#    not match (a ~207 MB re-download on EVERY Phase-5 pass) and the
#    clear-the-links branch could not fire (a silent refusal to upgrade),
#    because "" == "$VERSION" is false and [[ -n "" ]] is false. That is the
#    iter-58 `realpath -m` shape -- empty-string-compares-equal, reading as
#    healthy -- pointed at a different guard.
#
#    So the version lives in the PATH now and the filesystem answers "is this
#    current?", exactly as slot 16 (ghostty) and slot 24 (proxmox-mcp) do.
#
#    A DIRECTORY, NOT TWO VERSIONED FILES, because tsh and tctl come out of ONE
#    tarball and must never drift apart. Two independent versioned paths can be
#    left at two different versions by an interrupted run, which puts the
#    both-or-neither problem straight back into the fast path; one directory
#    either exists whole or does not exist. Same reasoning as podman's
#    podman-<ver>/ userland tree.
#
#    THE STAGING DIRECTORY LIVES UNDER $APP_DIR, NOT $FB_TMP, AND THAT IS
#    LOAD-BEARING. FB_TMP is `mktemp -d` -> /tmp, which is tmpfs on this host
#    while ~/.local/apps is btrfs. A cross-device `mv` is copy-then-unlink, NOT
#    an atomic rename, so moving straight out of FB_TMP leaves a window in
#    which the payload directory exists half-populated and a later fast path
#    could accept it. Staging beside the final path makes the last step a
#    same-filesystem rename(2): atomic, all or nothing.
#
#    WHAT THIS REMOVES IS THE PARSE, NOT THE INVOCATION. The fast path still
#    RUNS the payload (`tsh version`), because that probe is what replaces
#    install_bin's verification gate -- nothing else establishes that the file
#    on disk is a working binary. Measured cost of `tsh version`: 27 ms with no
#    profile, 221 ms against a reachable proxy, and 5.03 s (bounded, rc 0,
#    tsh's own "context deadline exceeded") when a profile names an UNREACHABLE
#    proxy. That last branch needs the cluster to answer the curl below while
#    the PROFILE's proxy does not; it is not a hang, and it is not new.
#
#    THE SYMLINK NAMES ARE LOAD-BEARING. home/private_dot_ssh/private_config
#    carries `ProxyCommand "tsh" proxy ssh ...` in its portable, PATH-resolved
#    form, so ${BIN_DIR}/tsh and ${BIN_DIR}/tctl must keep exactly those names.
#    ONLY the $APP_DIR payload carries a version.

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
        # A user-local copy installed BEFORE the system one appeared still
        # SHADOWS it: the env layer puts ~/.local/bin ahead of /usr/bin, so
        # `tsh` resolves to OURS and the version line printed above describes a
        # binary the caller will not get. Measured 2026-09-05 with the system
        # copy in /bin: this announced v18.10.0 while v18.10.1 actually ran.
        # The deferral prevents CREATING a shadow; it cannot see one that
        # already exists. Slot 23 carries the same note for the same reason.
        #
        # Checked PER BINARY, and via fb_system_bin rather than by assuming
        # $SYSTEM_TSH's directory holds both: this slot installs two binaries
        # while the deferral probes only tsh, so a box with a system tsh and no
        # system tctl must not be told to delete a tctl symlink that nothing
        # would replace.
        for b in tsh tctl; do
            [[ -e "${BIN_DIR}/${b}" ]] || continue
            fb_system_bin "$b" version >/dev/null || continue
            echo "  note: ${BIN_DIR}/${b} still shadows it; delete that symlink to use the system binary."
        done
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

PAYLOAD_DIR="${APP_DIR}/teleport-${VERSION}"

# Retire older versions so ~/.local/apps does not accumulate ~234 MB per
# release. The symlinks point into $keep, so any other teleport-* directory is
# dead weight. Called from BOTH the fast path and the install path: the normal
# upgrade run prunes as a side effect of installing, but a run interrupted
# between the move and the prune would otherwise strand the old payload
# forever, since every later run takes the fast path and never reaches this.
#
# The glob also catches an abandoned staging directory (teleport-<ver>.new.$$)
# left by a crashed run, which is exactly what should happen to it.

# MIGRATION, and it must run on every pass, not only on an install.
#
# Before the versioned layout this slot installed through install_bin, which
# placed the payloads at the BARE paths ${APP_DIR}/tsh and ${APP_DIR}/tctl.
# Those names match no teleport-* glob, so fb_prune_versions cannot see them
# and they would sit there forever: 234 MB measured (tsh 127.6 MB, tctl
# 105.8 MB). Every machine that ran this fetcher before the change has a pair.
#
# It runs on the FAST path too, deliberately: a box already holding the right
# version never reaches the install path again, and would keep both copies.
#
# `-f` and a regular-file test, never -rf: these are files, and a directory at
# either name is not ours to delete.
remove_legacy_unversioned() {
    local f
    for f in "${APP_DIR}/tsh" "${APP_DIR}/tctl"; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        rm -f "$f"
        echo "  removed legacy unversioned payload: $(basename "$f") (pre-versioned layout)"
    done
}

# Fast path: this exact version is already installed and both binaries run.
# Re-assert the symlinks (cheap, and self-heals a hand-deleted link), prune,
# drop any legacy payload, and exit WITHOUT re-downloading. Not an optimization
# — the installer runs every fetcher on EVERY Phase-5 pass and the asset is
# ~207 MB, so deciding this after gh_download would re-pull a fifth of a
# gigabyte each run.
#
# BOTH binaries are probed: a present tsh with a missing or broken tctl must
# fall through to the install below, not exit here.
if [[ -x "${PAYLOAD_DIR}/tsh" && -x "${PAYLOAD_DIR}/tctl" ]] \
   && "${PAYLOAD_DIR}/tsh"  version >/dev/null 2>&1 \
   && "${PAYLOAD_DIR}/tctl" version >/dev/null 2>&1; then
    echo "tsh/tctl ${VERSION} already installed and matching ${PROXY} — nothing to do."
    ln -sfn "${PAYLOAD_DIR}/tsh"  "${BIN_DIR}/tsh"
    ln -sfn "${PAYLOAD_DIR}/tctl" "${BIN_DIR}/tctl"
    fb_prune_versions "$PAYLOAD_DIR" "" 'teleport-*'
    remove_legacy_unversioned
    exit 0
fi

TSH_PREV_DIR="$(fb_prev_payload tsh /tsh)"

ASSET_URL="https://cdn.teleport.dev/teleport-v${VERSION}-${OS}-${ARCH}-bin.tar.gz"

TARBALL="${FB_TMP}/teleport.tar.gz"
echo "→ Downloading Teleport client tools ${VERSION} (${OS}/${ARCH}, ~207 MB)..."
gh_download "$ASSET_URL" "$TARBALL"

# Stage INSIDE $APP_DIR so the final move is a same-filesystem rename(2). See
# header note 6: FB_TMP is on tmpfs and $APP_DIR is not, so a move out of
# FB_TMP would be copy-then-unlink and could leave a half-populated payload.
# This slot's staging rule, now shared: fb_stage_payload places the staging dir
# beside the payload inside $APP_DIR, and fb_publish_payload refuses any stage
# that is not, so slots 16 and 24 cannot drift back to moving out of FB_TMP.
STAGE="$(fb_stage_payload "$PAYLOAD_DIR")"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"; rm -rf "$FB_TMP"' EXIT

# Extract ONLY the two client binaries, straight into the staging directory.
# The tarball is ~207 MB and carries the server (teleport, tbot,
# fdpass-teleport), a root system installer, and the whole examples/ tree;
# unpacking all of that to keep two files is pure waste. Naming both members
# explicitly also means a future tarball that DROPS one fails here, loudly and
# by name, rather than at the verification gate below.
#
# NEVER run the bundled teleport/install script: it is a root, system-wide
# installer, and this tree is rootless-by-contract (see slot 12, podman).
tar -xzf "$TARBALL" -C "$STAGE" --strip-components=1 teleport/tsh teleport/tctl
chmod +x "${STAGE}/tsh" "${STAGE}/tctl"

# Verification gate BEFORE anything is placed on PATH. This is install_bin's
# contract, reproduced here because the versioned destination bypasses it.
#
# `version` is a SUBCOMMAND, not a flag: `tsh --version` is a hard error, so a
# probe written with the flag form would reject a perfectly good binary.
for t in tsh tctl; do
    if ! "${STAGE}/${t}" version >/dev/null 2>&1; then
        echo "Error: the downloaded ${t} is not runnable (verification failed)." >&2
        exit 1
    fi
done

# Atomic publish. The rm-then-mv, and the reason for it, now live in
# fb_publish_payload: `mv dir existing-dir` moves the source INTO the target
# rather than replacing it, and the only way to reach here with the target
# present is a payload that already failed the fast path's probes.
fb_publish_payload "$STAGE" "$PAYLOAD_DIR"
trap 'rm -rf "$FB_TMP"' EXIT

ln -sfn "${PAYLOAD_DIR}/tsh"  "${BIN_DIR}/tsh"
ln -sfn "${PAYLOAD_DIR}/tctl" "${BIN_DIR}/tctl"

fb_prune_versions "$PAYLOAD_DIR" "$TSH_PREV_DIR" 'teleport-*'
remove_legacy_unversioned

echo "Installed Teleport client tools v${VERSION} (pinned to ${PROXY}) -> ${BIN_DIR}/{tsh,tctl}"
echo "  version: $("${BIN_DIR}/tsh" version 2>&1 | head -1)"
