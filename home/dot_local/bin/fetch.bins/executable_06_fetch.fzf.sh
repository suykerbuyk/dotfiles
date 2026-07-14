#!/usr/bin/env bash
set -euo pipefail

# fzf installer (CLI/TUI). Uses lib for GitHub helpers, temp discipline,
# verification, and safety guard. Simplified to ~10 lines.
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="fzf"
fb_init

OS="$(fb_os)"
ARCH="$(fb_arch amd64)"  # fzf uses amd64/arm (armv7l->arm)
ARCH_FOR_FZF="${ARCH/armv7l/arm}"  # extra normalization

TAG_NAME="$(gh_latest_tag junegunn/fzf)"
VERSION="${TAG_NAME#v}"  # no 'v' prefix

# Asset pattern: fzf-${VERSION}-linux_${arch}.tar.gz
ASSET_URL="$(gh_asset_url junegunn/fzf 'contains("linux") and contains($arch)' "$ARCH_FOR_FZF")"

TARBALL="${FB_TMP}/fzf.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"

# Hand install_bin the extracted binary in FB_TMP; it copies into APP_DIR itself.
# Pre-moving it to ${APP_DIR}/${BIN_NAME} makes src and install_bin's dest the
# same path, and its `cp` fails ("are the same file") before the symlink is made.
install_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" --version

echo "Installed fzf $VERSION (tarball) -> ${BIN_DIR}/${BIN_NAME}"
