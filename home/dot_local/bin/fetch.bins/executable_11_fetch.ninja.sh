#!/usr/bin/env bash
set -euo pipefail

# ninja installer. ninja ships a single statically-linked binary inside a .zip
# (not a tarball), so this mirrors the ripgrep/fzf pattern but unzips instead of
# untars. Uses lib for the GitHub helpers, temp discipline, verification gate,
# and the safety guard. See home/doc/fetch-bins.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="ninja"
fb_init

# ninja needs 'unzip' (its release asset is a .zip, unlike the tarball tools).
# Fail loud with a fixable message rather than silently skipping.
if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: 'unzip' is required to install ninja (its release is a .zip)." >&2
    echo "       Install it (e.g. 'sudo apt install unzip' or 'sudo pacman -S unzip') and re-run." >&2
    exit 1
fi

# ninja's release assets are named by platform, not by the usual arch tokens:
#   ninja-linux.zip           (x86_64, statically linked)
#   ninja-linux-aarch64.zip   (arm64)
#   ninja-mac.zip             (universal macOS)
OS="$(fb_os mac)"          # linux | mac  (darwin -> mac)
ARCH="$(uname -m)"
case "${OS}:${ARCH}" in
    linux:x86_64)               ASSET="ninja-linux.zip" ;;
    linux:aarch64|linux:arm64)  ASSET="ninja-linux-aarch64.zip" ;;
    mac:*)                      ASSET="ninja-mac.zip" ;;
    *) echo "Error: unsupported platform '${OS}/${ARCH}' for ninja." >&2; exit 1 ;;
esac

TAG_NAME="$(gh_latest_tag ninja-build/ninja)"
VERSION="${TAG_NAME#v}"

# The asset names carry no version/arch token, so match the exact name.
ASSET_URL="$(gh_asset_url ninja-build/ninja '. == $arch' "$ASSET")"

ZIP="${FB_TMP}/ninja.zip"
gh_download "$ASSET_URL" "$ZIP"

unzip -oq "$ZIP" -d "$FB_TMP"   # single 'ninja' binary at the zip root

install_bin "${FB_TMP}/${BIN_NAME}" "$BIN_NAME" --version

echo "Installed ninja $VERSION (release zip) -> ${BIN_DIR}/${BIN_NAME}"
