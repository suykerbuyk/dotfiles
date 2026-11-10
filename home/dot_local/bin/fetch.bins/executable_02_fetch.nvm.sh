#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# fb_verify exemption: nvm is cloned/installed by its own installer; there is no release artifact of ours to hash.
# See "Download integrity" in doc/fetch-bins.md.

# nvm installer (runs official install.sh script). Uses lib for safety guard
# and helpers. nvm is special (script-based, sources itself).
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

APP_DIR="$HOME/.local/apps"
export NVM_DIR="$APP_DIR/nvm"
BIN_DIR="$HOME/.local/bin"  # for optional symlink

fb_init
fb_require_os nvm

# Install nvm if absent. Unlike the old early-exit, this falls through to the
# node-install + symlink block below, so re-running the fetcher keeps node
# current instead of stopping the moment nvm itself is present.
if [[ -f "${NVM_DIR}/nvm.sh" ]]; then
    echo "nvm already at $NVM_DIR."
else
    mkdir -p "${NVM_DIR}"

    LATEST_TAG="$(gh_latest_tag nvm-sh/nvm)"
    INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/nvm-sh/nvm/$LATEST_TAG/install.sh"

    echo "Installing nvm from $INSTALL_SCRIPT_URL..."
    curl -o- "$INSTALL_SCRIPT_URL" | bash
    echo "Installed NVM $LATEST_TAG to $NVM_DIR"
fi

# Load nvm into THIS shell so its `nvm` function is callable below.
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# nvm.sh symlink (unchanged behaviour).
if [[ -f "$NVM_DIR/nvm.sh" ]]; then
    ln -sfn "$NVM_DIR/nvm.sh" "${BIN_DIR}/nvm.sh"
    echo "  (symlinked nvm.sh to ${BIN_DIR}/nvm.sh)"
else
    echo "Warning: nvm.sh not found after install." >&2
    exit 1
fi

# Install the default node and expose it on ~/.local/bin (mechanism (a)).
# ~/.local/bin is already on both the systemd/GUI PATH and the shell PATH, so a
# symlink there is all GUI/headless nvim needs to find node — no PATH edit. node
# resolves its lib dir via realpath(argv0) through a symlink, and npm/npx
# (#!/usr/bin/env node) find node via the sibling symlink.
#
# One valid token is used for BOTH install and alias. node tracks the latest LTS
# by default ('lts/*') — the least-maintenance choice, matching the repo's
# unpinned-tracks-latest norm; FB_PIN_NODE overrides with any nvm-valid version
# (e.g. an exact FB_PIN_NODE=22.11.0 or a major FB_PIN_NODE=22). 'lts/*' is used
# rather than '--lts' because '--lts' is NOT a valid alias target — it would
# leave `nvm which default` empty and the symlinks below would never be created.
NODE_WANT="$(fb_pin node || echo 'lts/*')"
echo "Installing node (${NODE_WANT}) via nvm and setting it as the default..."
nvm install "$NODE_WANT"
nvm alias default "$NODE_WANT" || true

NODE_BIN_DIR="$(dirname "$(nvm which default 2>/dev/null)")"
if [[ -n "$NODE_BIN_DIR" && -x "$NODE_BIN_DIR/node" ]]; then
    for _b in node npm npx; do
        [[ -e "$NODE_BIN_DIR/$_b" ]] && ln -sfn "$NODE_BIN_DIR/$_b" "${BIN_DIR}/$_b"
    done
    echo "Linked node/npm/npx from ${NODE_BIN_DIR} -> ${BIN_DIR}"
    echo "  node: $("${BIN_DIR}/node" --version 2>&1)"
else
    echo "Warning: could not resolve default node bin dir; node not linked." >&2
    exit 1
fi
