#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/apps"
BIN_DIR="$HOME/.local/bin"
BIN_NAME="fzf"
TEMP_DIR="$(mktemp -d)"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed 's/x86_64/amd64/ ; s/aarch64/arm64/ ; s/armv7l/arm/')" # Normalize for fzf naming

LATEST_URL="https://api.github.com/repos/junegunn/fzf/releases/latest"
RELEASE_INFO=$(curl -s "$LATEST_URL")
VERSION=$(echo "$RELEASE_INFO" | jq -r .tag_name) # e.g., 0.67.0 (no 'v' prefix)

mkdir -p ${APP_DIR}
mkdir -p ${BIN_DIR}

# Find asset URL (pattern: fzf-{version}-linux_{arch}.tar.gz)
ASSET_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name | contains(\"$OS\") and contains(\"$ARCH\")) | .browser_download_url" | head -1)
if [[ -z "$ASSET_URL" ]]; then
    echo "Error: No matching asset for $OS/$ARCH" >&2
    exit 1
fi

# Download and extract
curl -L -o "$TEMP_DIR/fzf.tar.gz" "$ASSET_URL"
tar -xzf "$TEMP_DIR/fzf.tar.gz" -C "$TEMP_DIR"
mv "$TEMP_DIR/fzf" "${APP_DIR}/$BIN_NAME"
chmod +x "${APP_DIR}/$BIN_NAME"
ln -sf "${APP_DIR}/$BIN_NAME" "${BIN_DIR}/$BIN_NAME"

echo "Installed fzf $VERSION to $BIN_DIR/$BIN_NAME"
rm -rf "$TEMP_DIR"
