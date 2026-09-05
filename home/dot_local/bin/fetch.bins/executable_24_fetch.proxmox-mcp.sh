#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# proxmox-mcp installer (MCP server for Proxmox VE, Go, gordcurrie/proxmox-mcp).
# The release ships BARE, UNCOMPRESSED binaries named proxmox-mcp_<os>_<arch> —
# no tarball, no zip, no checksums file. Upstream publishes no signature or
# .sha256, so TLS plus "it runs" is the whole integrity story here, same as
# every other bare-binary slot.
#
# THE PROBE IS --help, AND THAT IS LOAD-BEARING (measured 2026-09-04 against
# v0.11.1):
#
#   --version / -version   rc 2, "flag provided but not defined: -version"
#   --help / -h            rc 0, usage on stderr, returns instantly
#   no args, no env        rc 1, "required environment variable ... is not set"
#   no args, full env      SERVES MCP ON STDIO and runs until stdin EOF
#
# This binary has NO version flag of any kind. It is a Go `flag` program
# exposing only -addr and -transport (stdio by default). So:
#
#   - --version cannot be the verification argv. It exits non-zero, and a
#     non-zero probe is how a verification gate concludes "not a working
#     binary" — it would reject a perfectly good binary every time.
#   - The payload is NEVER invoked bare. With PROXMOX_API_URL, PROXMOX_TOKEN_ID
#     and PROXMOX_TOKEN_SECRET all set — which is exactly a host that has a lab
#     — a bare run starts serving MCP and blocks until stdin closes. Nothing in
#     the fetch.bins library bounds an invocation with timeout(1), and stdin is
#     inherited unchanged, so under a TTY that is an unbounded hang in the
#     middle of Phase 5. --help is the only argv that both exits 0 and cannot
#     start the server.
#
# WHY A VERSIONED PAYLOAD PATH, not install_bin: install_bin's fb_check_bin gate
# is version-BLIND — once ~/.local/bin/proxmox-mcp resolves to an executable it
# answers "already valid (skipping)" and returns, so the tool would never
# upgrade and every Phase 5 run would re-download 9.5 MB only to discard it.
# Slot 22 defeats that by parsing the installed binary's version; this binary
# cannot report one. Slot 16's answer works without asking the binary anything:
# put the upstream version in the PATH, and let the filesystem answer "is this
# current?". That is the shape used here.
#
# ARCH TOKENS: upstream uses amd64/arm64, which is exactly what fb_arch emits
# (Linux x86_64 -> amd64, Linux aarch64 -> arm64, darwin arm64 -> arm64). Do NOT
# "fix" this to a raw `uname -m` the way slots 17-21 do — those tools name their
# assets with x86_64/aarch64, this one does not, and the swap would 404 on
# arm64. See home/doc/fetch-bins.md.
#
# The selector is an EXACT match binding BOTH $os and $arch: the release also
# carries proxmox-mcp_darwin_amd64 and a windows .exe, which a contains($arch)
# filter would happily select on a linux box.
#
# CREDENTIALS ARE NOT THIS FETCHER'S JOB. PROXMOX_API_URL, PROXMOX_TOKEN_ID and
# PROXMOX_TOKEN_SECRET are host-local and are never committed here; they belong
# in the unmanaged ~/.config/shell/env.d/ drop-in. This slot installs a binary
# and writes no MCP client stanza — see home/doc/fetch-bins.md for why.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="proxmox-mcp"
fb_init
fb_require_os

REPO="gordcurrie/proxmox-mcp"
OS="$(df_os)"        # linux | darwin — matches the asset names as-is
ARCH="$(fb_arch)"    # amd64 | arm64  — likewise

# Retire older versions so ~/.local/apps does not accumulate ~9.5 MB per
# release. The symlink points at $keep, so anything else is dead weight. Called
# from BOTH the fast path and the install path: the normal upgrade run prunes as
# a side effect of installing, but a run interrupted between download and prune
# would otherwise strand the old payload forever, since every later run takes
# the fast path and never reaches this.
prune_old_versions() {
    local keep="$1" old
    for old in "${APP_DIR}/${BIN_NAME}"-*; do
        [[ -e "$old" && "$old" != "$keep" ]] || continue
        rm -f "$old"
        echo "  pruned old version: $(basename "$old")"
    done
}

TAG_NAME="$(gh_latest_tag "$REPO")"
VERSION="${TAG_NAME#v}"
PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"

# Fast path: this exact version is already installed and runnable. Re-assert the
# symlink (cheap, and self-heals a hand-deleted link), prune, and exit WITHOUT
# re-downloading. Not an optimization — Phase 5 runs every fetcher on EVERY
# invocation of the installer.
if [[ -x "$PAYLOAD" ]] && "$PAYLOAD" --help >/dev/null 2>&1; then
    echo "proxmox-mcp $VERSION already installed; symlink ensured."
    ln -sfn "$PAYLOAD" "${BIN_DIR}/${BIN_NAME}"
    prune_old_versions "$PAYLOAD"
    exit 0
fi

# Asset: proxmox-mcp_<os>_<arch> (bare binary, exact name).
ASSET_URL="$(gh_asset_url "$REPO" \
    '. == ("proxmox-mcp_" + $os + "_" + $arch)' "$ARCH" "$OS")"

echo "→ Downloading proxmox-mcp $VERSION (${OS}/${ARCH}, ~9.5 MB)..."
TMP_BIN="${FB_TMP}/${BIN_NAME}"
gh_download "$ASSET_URL" "$TMP_BIN"
chmod +x "$TMP_BIN"

# Verification gate BEFORE anything is placed on PATH (install_bin's contract,
# reproduced here because we bypass it for the versioned destination).
if ! "$TMP_BIN" --help >/dev/null 2>&1; then
    echo "Error: the downloaded proxmox-mcp is not runnable (verification failed)." >&2
    exit 1
fi

# Place the verified binary at its versioned path, then link.
mkdir -p "$APP_DIR"
mv -f "$TMP_BIN" "$PAYLOAD"
chmod +x "$PAYLOAD"
ln -sfn "$PAYLOAD" "${BIN_DIR}/${BIN_NAME}"

prune_old_versions "$PAYLOAD"

echo "Installed proxmox-mcp ${VERSION} (${OS}/${ARCH}) -> ${BIN_DIR}/${BIN_NAME}"
echo "  note: needs PROXMOX_API_URL, PROXMOX_TOKEN_ID and PROXMOX_TOKEN_SECRET;"
echo "        set them host-locally in ~/.config/shell/env.d/, never in this repo."
