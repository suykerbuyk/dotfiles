#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"

APP_DIR="$HOME/.local/apps"
BIN_DIR="$HOME/.local/bin"
BIN_NAME="jq"
TEMP_DIR="$(mktemp -d)"

[ ! -d "${APP_DIR}" ] && mkdir -p "${APP_DIR}"
[ ! -d "${BIN_DIR}" ] && mkdir -p "${BIN_DIR}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed 's/x86_64/amd64/ ; s/aarch64/arm64/')" # Normalize arch for jq naming

LATEST_URL="https://api.github.com/repos/jqlang/jq/releases/latest"
RELEASE_INFO=$(curl -s "$LATEST_URL")
VERSION=$(echo "$RELEASE_INFO" | jq -r .tag_name | sed 's/jq-//') # e.g., 1.7.1

# Find asset URL (jq assets are plain binaries: jq-{os}-{arch})
ASSET_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name | contains(\"$OS\") and contains(\"$ARCH\")) | .browser_download_url" | head -1)
if [[ -z "$ASSET_URL" ]]; then
    echo "Error: No matching asset for $OS/$ARCH" >&2
    exit 1
fi

# Download directly (no archive)
curl -L -o "${APP_DIR}/$BIN_NAME" "$ASSET_URL"
chmod +x "${APP_DIR}/$BIN_NAME"
ln -sf "${APP_DIR}/$BIN_NAME" "${BIN_DIR}/$BIN_NAME"

echo "Installed jq $VERSION to $INSTALL_DIR/$BIN_NAME"
rm -rf "$TEMP_DIR"
