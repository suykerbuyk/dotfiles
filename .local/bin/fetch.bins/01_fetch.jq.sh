#!/usr/bin/env bash
set -euo pipefail
echo "Running"
INSTALL_DIR="$HOME/.local/bin"

APP_DIR="$HOME/.local/apps"
BIN_DIR="$HOME/.local/bin"
BIN_NAME="jq"

[ ! -d "${APP_DIR}" ] && mkdir -p "${APP_DIR}"
[ ! -d "${BIN_DIR}" ] && mkdir -p "${BIN_DIR}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed 's/x86_64/amd64/ ; s/aarch64/arm64/')" # Normalize arch for jq naming

echo "OS=$OS ARCH=$ARCH"

LATEST_URL="https://api.github.com/repos/jqlang/jq/releases/latest"
TAG_NAME="$(curl -sL https://api.github.com/repos/jqlang/jq/releases/latest | grep tag_name | awk -F '"' '{print $4}')"
#BINARY="jq-linux-amd64"
BINARY="jq-${OS}-${ARCH}"
#echo $BINARY
DOWN_LOAD_URL="https://github.com/jqlang/jq/releases/download/${TAG_NAME}/${BINARY}"
echo "DOWN_LOAD_URL=$DOWN_LOAD_URL"
# Download directly (no archive)
curl -L -o "${APP_DIR}/$BIN_NAME" "${DOWN_LOAD_URL}"
chmod +x "${APP_DIR}/$BIN_NAME" || echo "Failed to chmod"
ln -sf "${APP_DIR}/$BIN_NAME" "${BIN_DIR}/$BIN_NAME" || echo "Failed to ln"

echo "Installed $TAG_NAME to $INSTALL_DIR/$BIN_NAME"
