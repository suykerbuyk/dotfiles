#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/apps"
BIN_DIR="$HOME/.local/bin"
BIN_NAME="rg"
TEMP_DIR="$(mktemp -d)"
echo "TEMP_DIR=$TEMP_DIR"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
CHECKSUM_URL="https://github.com/BurntSushi/ripgrep/releases/latest/download/SHA256"

mkdir -p "${APP_DIR}"
# Fetch latest release JSON
LATEST_URL="https://api.github.com/repos/BurntSushi/ripgrep/releases/latest"
RELEASE_INFO=$(curl -s "$LATEST_URL")

# Extract tag name (version)
VERSION=$(echo "$RELEASE_INFO" | jq -r .tag_name | sed 's/v//') # e.g., 13.0.0

# Find asset URL (adapt pattern for your platform)
ASSET_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name | contains(\"$OS\") and contains(\"$ARCH\")) | .browser_download_url" | head -1)
if [[ -z "$ASSET_URL" ]]; then
    echo "Error: No matching asset for $OS/$ARCH" >&2
    exit 1
fi

# Download and extract
curl -L -o "$TEMP_DIR/ripgrep.tar.gz" "$ASSET_URL"
tar -xzf "$TEMP_DIR/ripgrep.tar.gz" -C "$APP_DIR"
BIN_PATH="${APP_DIR}/ripgrep-${VERSION}-${ARCH}-unknown-${OS}-musl"

# Symlink (idempotent)
ln -sf "${BIN_PATH}/$BIN_NAME" "${BIN_DIR}/$BIN_NAME"

echo "Installed ripgrep $VERSION to ${APP_DIR}/$BIN_NAME"
rm -rf "$TEMP_DIR"
