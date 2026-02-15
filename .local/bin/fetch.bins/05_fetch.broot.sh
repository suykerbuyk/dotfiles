#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/apps"
BIN_DIR="$HOME/.local/bin"
BIN_NAME="broot"

TEMP_DIR="$(mktemp -d)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
#ARCH="$(uname -m | sed 's/x86_64/amd64/')" # GitHub uses amd64
ARCH="$(uname -m)"

LATEST_URL="https://api.github.com/repos/Canop/broot/releases/latest" # Note: Owner is Canop
RELEASE_INFO=$(curl -s "$LATEST_URL")
VERSION=$(echo "$RELEASE_INFO" | jq -r .tag_name | sed 's/v//')

#ASSET_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name | contains(\"$OS\") and contains(\"$ARCH\")) | .browser_download_url" | head -1)
ASSET_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[].browser_download_url" | head -1)
if [[ -z "$ASSET_URL" ]]; then
    echo "Error: No matching asset" >&2
    exit 1
fi

curl -L -o "$TEMP_DIR/broot.zip" "$ASSET_URL"
unzip -q "$TEMP_DIR/broot.zip" -d "$TEMP_DIR"
cp "$TEMP_DIR/${ARCH}-unknown-${OS}-musl/broot" "$BIN_DIR/$BIN_NAME" # Assuming binary is named 'broot'
chmod +x "$BIN_DIR/$BIN_NAME"

echo "Installed broot $VERSION to $BIN_DIR/$BIN_NAME"
rm -rf "$TEMP_DIR"
