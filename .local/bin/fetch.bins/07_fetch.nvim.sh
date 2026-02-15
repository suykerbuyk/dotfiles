#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/apps"
BIN_DIR="$HOME/.local/bin"
BIN_NAME="nvim"

IMG_NAME="nvim.appimage" # Or extract to 'nvim'
TEMP_DIR="$(mktemp -d)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

LATEST_URL="https://api.github.com/repos/neovim/neovim/releases/latest"
RELEASE_INFO=$(curl -s "$LATEST_URL")
VERSION=$(echo "$RELEASE_INFO" | jq -r .tag_name | sed 's/v//')

IMG_NAME="${IMG_NAME}-${VERSION}"

# Target AppImage (portable, no extract needed)
ASSET_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name | contains(\"appimage\") and contains(\"$ARCH\")) | .browser_download_url" | head -1)
if [[ -z "$ASSET_URL" ]]; then
    echo "Error: No AppImage for $ARCH" >&2
    exit 1
fi

curl -L -o "${APP_DIR}/${IMG_NAME}" "$ASSET_URL"
chmod +x "${APP_DIR}/${IMG_NAME}"
ln -sf "${APP_DIR}/${IMG_NAME}" "${BIN_DIR}/${BIN_NAME}" # Symlink as 'nvim'

echo "Installed Neovim $VERSION (AppImage) to $BIN_DIR/$BIN_NAME"
