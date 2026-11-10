#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# fb_verify exemption: installer-invoking (curl | bash): there is no archive of ours to hash. As of the inspected x.ai endpoints grok publishes no checksum or signature, so there is nothing to verify against.
# See "Download integrity" in doc/fetch-bins.md.

# grok installer (xAI grok CLI). Like nvm (slot 02), rust (slot 10) and claude
# (slot 26), grok is a SELF-MANAGING, SELF-UPDATING harness that owns its own
# tree (~/.grok/: downloads/, bin/grok symlink, version.json, auth, sessions,
# skills, marketplace) rather than a single static binary we pin. So it does NOT
# go through install_bin / fb_check_bin / a versioned payload.
#
# INSTALL-IF-ABSENT, NEVER UPDATE — the nvm model. grok is frequently LIVE and
# Phase 5 runs on every installer invocation, so the skip-if-present guard below
# is the point of the slot: on a provisioned box it must be a clean no-op. Never
# run `grok update` here. Upgrades are grok's own job.
#
# Official installer (verified 2026-11-09): `curl -fsSL https://x.ai/cli/
# install.sh | bash`. Env GROK_CHANNEL=stable|alpha|enterprise (default stable);
# an optional positional arg pins a specific X.Y.Z. It installs a bare binary to
# ~/.grok/downloads/grok-<ver>-<os>-<arch> and symlinks ~/.grok/bin/grok.
#
# ~/.grok/bin is NOT on this repo's PATH (the env layer adds ~/.local/bin only),
# so — matching how this box is already wired — we symlink the grok the installer
# produced into ~/.local/bin, keeping ~/.local/bin the single PATH source of
# truth. We do NOT set GROK_BIN_DIR=~/.local/bin: that would split grok's self-
# managed layout (its own `grok update` rewrites ~/.grok/bin/grok).

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="grok"
fb_init
fb_require_os grok

# SKIP-IF-PRESENT, FIRST. Operability (`grok --version`), not bare presence, for
# the same reason as claude's slot: fb_init puts $BIN_DIR on PATH, and a dangling
# symlink there would pass `command -v` while being unrunnable.
if command -v grok >/dev/null 2>&1 && grok --version >/dev/null 2>&1; then
    echo "grok already installed ($(grok --version 2>&1 | head -1)) — self-updates via 'grok update'; skipping."
    exit 0
fi

echo "Installing xAI grok CLI (stable channel) via https://x.ai/cli/install.sh …"
GROK_CHANNEL=stable curl -fsSL https://x.ai/cli/install.sh | bash

# The installer targets ~/.grok/bin, not ~/.local/bin. Reproduce this box's
# wiring so grok lands on PATH like every other tool.
if [[ -x "$HOME/.grok/bin/grok" ]]; then
    ln -sf "$HOME/.grok/bin/grok" "${BIN_DIR}/grok"
fi

# Verify in place before declaring success.
if ! grok --version >/dev/null 2>&1; then
    echo "Error: grok is not runnable after install." >&2
    exit 1
fi
echo "Installed xAI grok CLI: $(grok --version 2>&1 | head -1)"
echo "  (symlinked ~/.grok/bin/grok -> ${BIN_DIR}/grok; self-updates via 'grok update')"
