#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# nvm installer (runs official install.sh script). Uses lib for safety guard
# and helpers. nvm is special (script-based, sources itself).
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

APP_DIR="$HOME/.local/apps"
export NVM_DIR="$APP_DIR/nvm"
BIN_DIR="$HOME/.local/bin"  # for optional symlink

fb_init

# Check if installed (preserved)
if [[ -f "${NVM_DIR}/nvm.sh" ]]; then
    echo "NVM already at $NVM_DIR. Run 'nvm install node --lts' for latest Node."
    exit 0
fi

mkdir -p "${NVM_DIR}"

LATEST_TAG="$(gh_latest_tag nvm-sh/nvm)"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/nvm-sh/nvm/$LATEST_TAG/install.sh"

echo "Installing nvm from $INSTALL_SCRIPT_URL..."
curl -o- "$INSTALL_SCRIPT_URL" | bash

[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # load in current shell

# Optional symlink
if [[ -f "$NVM_DIR/nvm.sh" ]]; then
    ln -sf "$NVM_DIR/nvm.sh" "${BIN_DIR}/nvm.sh"
    echo "Installed NVM $LATEST_TAG to $NVM_DIR"
    echo "  (symlinked nvm.sh to ${BIN_DIR}/nvm.sh)"
else
    echo "Warning: nvm.sh not found after install." >&2
fi
