#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# Neovim installer (release tarball — no FUSE, works on native Linux and WSL).
# Neovim is a TUI, so no display gating. Uses versioned install for rollback.
# Sourced from _lib.sh. See Context.fetch.bins.refactor.md for design.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="nvim"
fb_init
fb_require_os

# Per-tool normalization (nvim keeps x86_64, unlike jq's amd64)
ARCH="$(fb_arch x86_64)"

# FB_PIN_NVIM short-circuits the release lookup (and its API call). The `||` is
# load-bearing under `set -e`: fb_pin returns 1 when unset, and a bare assignment
# would abort on that status instead of falling through.
if VERSION="$(fb_pin nvim)"; then
    TAG_NAME="v${VERSION}"
else
    TAG_NAME="$(gh_latest_tag neovim/neovim)"
    VERSION="${TAG_NAME#v}"  # strip leading 'v' if present
fi
if [[ -z "$VERSION" ]]; then
    echo "Error: could not parse version from tag." >&2
    exit 1
fi

# Deterministic tarball selection (endswith + arch; no .zsync or .deb)
ASSET_URL="$(gh_asset_url neovim/neovim 'endswith(".tar.gz") and contains($arch)' "$ARCH")"

TARBALL="${FB_TMP}/nvim.tar.gz"
INSTALL_DIR="${APP_DIR}/nvim-${VERSION}"
NVIM_BIN="${INSTALL_DIR}/bin/nvim"

# nvim is NOT run through install_bin: install_bin copies the binary to
# APP_DIR/nvim, detaching it from its runtime tree ($INSTALL_DIR/share/nvim/
# runtime). VIMRUNTIME then falls back to the compile-time /usr/local paths
# and startup fails with E484 and missing vim.* Lua modules. Like the Go
# fetcher (GOROOT), we verify in place and symlink directly into the tree.
link_nvim() {
    # A prior install_bin-based version left a detached binary copy at
    # APP_DIR/nvim; remove it so nothing on any machine resolves there.
    if [[ -f "${APP_DIR}/${BIN_NAME}" && ! -d "${APP_DIR}/${BIN_NAME}" ]]; then
        rm -f "${APP_DIR}/${BIN_NAME}"
    fi
    ln -sfn "$NVIM_BIN" "${BIN_DIR}/${BIN_NAME}"
}

# Fast path: this exact version is already extracted and runnable. Re-assert
# the symlink (self-healing — also repairs a legacy link at a detached copy).
if [[ -x "$NVIM_BIN" ]] && "$NVIM_BIN" --version >/dev/null 2>&1; then
    echo "nvim $VERSION already installed; symlink ensured -> $NVIM_BIN"
    link_nvim
    # Cold path: nothing was superseded this run, so collect the delete the
    # install path deferred.
    #
    # TWO globs, and the second is the whole point: this slot used to name its
    # payload `nvim.appimage-<ver>`, and `nvim-*` does not match that. Two such
    # trees are resident on this host right now, stranded by the rename. A helper
    # deriving one glob from BIN_NAME would reclaim neither.
    fb_prune_versions "$INSTALL_DIR" "" 'nvim-*' 'nvim.appimage-*'
    exit 0
fi
# The payload the PATH symlink currently resolves to — captured BEFORE relinking,
# because that is the tree this run is about to supersede. fb_prune_versions
# spares it for exactly one run: deleting a live VIMRUNTIME tree in the same invocation
# that replaced it is `rm -rf` on files a running process may still lazily load,
# and POSIX keeps already-open files alive so nothing fails at the moment of
# deletion — it fails later, intermittently, and not under test.
NVIM_PREV_DIR=""
_prev_bin="$(readlink -f "${BIN_DIR}/nvim" 2>/dev/null || true)"
# The -x test is NOT redundant with the case match. GNU `readlink -f` resolves a
# path whose final component does not exist and prints it anyway, so on a machine
# with no prior install this yielded "$HOME/.local/bin/nvim", matched the pattern,
# and left PREV_DIR = "$HOME/.local" — a variable whose name claims "the previous
# payload" while holding the parent of BIN_DIR. Harmless as a SPARE, since a
# spare is only ever compared and never deleted, but false, and one refactor away
# from being passed somewhere that does delete. BSD readlink differs again on a
# missing path, so the guard is what makes both platforms agree.
if [[ -n "$_prev_bin" && -x "$_prev_bin" ]]; then
    case "$_prev_bin" in
        */bin/nvim) NVIM_PREV_DIR="${_prev_bin%/bin/nvim}" ;;
    esac
fi
unset _prev_bin


gh_download "$ASSET_URL" "$TARBALL"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1

# Verify in place (runtime resolves inside $INSTALL_DIR) before linking.
if ! "$NVIM_BIN" --version >/dev/null 2>&1; then
    echo "Error: extracted nvim is not runnable at $NVIM_BIN" >&2
    exit 1
fi
link_nvim
fb_prune_versions "$INSTALL_DIR" "$NVIM_PREV_DIR" 'nvim-*' 'nvim.appimage-*'

echo "Installed nvim $VERSION -> ${BIN_DIR}/${BIN_NAME}"
echo "  target: ${NVIM_BIN} (versioned tarball)"
echo "  version: $("$NVIM_BIN" --version | head -1)"
