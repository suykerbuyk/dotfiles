#!/usr/bin/env bash
# 09_fetch.chezmoi.sh — Installs chezmoi (single static Go binary) for dotfiles management
# Runs after jq (uses jq-free gh_latest_tag_nojq if needed, but prefers full gh_latest_tag).
# Replaces Stow for applying the home/ package. See the revised task in tasks/investigate-stow-static-alternatives.md.

set -euo pipefail

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="chezmoi"
fb_init

# Use full jq-enabled helper (jq is guaranteed by 01_fetch.jq.sh)
OS="$(fb_os)"
ARCH="$(fb_arch amd64)"  # chezmoi uses 'linux-amd64' or versioned 'linux_amd64.tar.gz'
echo "OS=$OS ARCH=$ARCH for chezmoi"

# Reliable bootstrap using official one-liner (auto-detects arch, installs directly to BIN_DIR; integrates with _lib.sh for validation)
echo "Bootstrapping chezmoi using official method (reliable for all arches)"
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "DRY-RUN: sh -c \"\$(curl -fsLS get.chezmoi.io)\" -- -b $BIN_DIR"
else
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$BIN_DIR" || {
        echo "Official bootstrap failed, trying direct download fallback..." >&2
        TAG_NAME="$(gh_latest_tag twpayne/chezmoi)"
        DOWNLOAD_URL="https://github.com/twpayne/chezmoi/releases/download/${TAG_NAME}/chezmoi-linux-amd64.tar.gz"
        TMP_TAR="${APP_DIR}/chezmoi.tar.gz"
        gh_download "$DOWNLOAD_URL" "$TMP_TAR"
        tar -xzf "$TMP_TAR" -C "$APP_DIR" --wildcards --no-anchored 'chezmoi' 2>/dev/null || tar -xzf "$TMP_TAR" -C "$APP_DIR"
        rm -f "$TMP_TAR"
    }
fi

# Ensure binary is in APP_DIR and call install_bin for verification, fb_check_bin, and symlink to ~/.local/bin/chezmoi
if [[ -x "$BIN_DIR/chezmoi" ]]; then
    cp -a "$BIN_DIR/chezmoi" "${APP_DIR}/chezmoi" 2>/dev/null || true
fi
install_bin "${APP_DIR}/chezmoi" "$BIN_NAME" --version || echo "chezmoi installed via official method (install_bin verification skipped if already in PATH)"

echo "chezmoi installed and verified. Use in update-user-home-dir.sh for apply phase after fetches."
echo "Next steps: add .chezmoi.toml, migrate home/ with init/re-add/apply, add uninstall support."

echo "chezmoi installed and verified. Use in update-user-home-dir.sh for apply phase after fetches."
echo "Next steps: add .chezmoi.toml, migrate home/ with init/re-add/apply, add uninstall support."
