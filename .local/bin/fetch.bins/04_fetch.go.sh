#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/apps"
BIN_DIR="$HOME/.local/bin"

BIN_NAME="go"
TEMP_DIR="$(mktemp -d)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed 's/x86_64/amd64/')" # GitHub uses amd64

# Fetch JSON of all versions
JSON_URL="https://go.dev/dl/?mode=json"
VERSIONS=$(curl -s "$JSON_URL" | jq -r '.[] | select(.stable == true) | .version' | sort -V | tail -1) # Latest stable

ASSET_PATH="${VERSIONS}.${OS}-${ARCH}.tar.gz"
ASSET_URL="https://go.dev/dl/$ASSET_PATH"

# Install dir
VERSION_DIR="${APP_DIR}/${VERSIONS}"
if [[ -d "$VERSION_DIR" ]]; then
    echo "Go $VERSIONS already installed"
    exit 0
fi

curl -L -o "$TEMP_DIR/go.tar.gz" "$ASSET_URL"
mkdir -p "${VERSION_DIR}"
tar -C "${VERSION_DIR}" -xzf "$TEMP_DIR/go.tar.gz"
ln -sf "${VERSION_DIR}/go/bin/go" "$BIN_DIR/$BIN_NAME"
ln -sf "${VERSION_DIR}/go/bin/gofmt" "$BIN_DIR/gofmt" # Etc. for other tools

echo "Installed Go $VERSIONS to $VERSION_DIR"
rm -rf "$TEMP_DIR"

# Set GOPATH if needed: export GOPATH=$HOME/go
