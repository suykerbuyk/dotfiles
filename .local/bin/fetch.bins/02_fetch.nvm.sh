#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/apps"
export NVM_DIR="$APP_DIR/nvm"

# Check if installed
if [[ -f "${NVM_DIR}/nvm.sh" ]]; then
    echo "NVM already at $NVM_DIR. Run 'nvm install node --lts' for latest Node."
    exit 0
fi

mkdir -p "${NVM_DIR}"

# Fetch latest tag
LATEST_TAG=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .tag_name)
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/nvm-sh/nvm/$LATEST_TAG/install.sh"

curl -o- "$INSTALL_SCRIPT_URL" | bash
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # Load in current shell

ln -sf "$NVM_DIR/nvm.sh" "${BIN_DIR}/nvm.sh" # Optional symlink for PATH

echo "Installed NVM $LATEST_TAG to $NVM_DIR"
