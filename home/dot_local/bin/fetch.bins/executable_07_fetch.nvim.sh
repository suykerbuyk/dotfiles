#!/usr/bin/env bash
set -euo pipefail

# Neovim installer (release tarball — no FUSE, works on native Linux and WSL).
# Neovim is a TUI, so no display gating. Uses versioned install for rollback.
# Sourced from _lib.sh. See Context.fetch.bins.refactor.md for design.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="nvim"
fb_init

# Per-tool normalization (nvim keeps x86_64, unlike jq's amd64)
ARCH="$(fb_arch x86_64)"

TAG_NAME="$(gh_latest_tag neovim/neovim)"
VERSION="${TAG_NAME#v}"  # strip leading 'v' if present
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
    exit 0
fi

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

echo "Installed nvim $VERSION -> ${BIN_DIR}/${BIN_NAME}"
echo "  target: ${NVIM_BIN} (versioned tarball)"
echo "  version: $("$NVIM_BIN" --version | head -1)"
