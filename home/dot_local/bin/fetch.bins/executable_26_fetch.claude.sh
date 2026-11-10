#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# fb_verify exemption: installer-invoking (curl | bash): there is no archive of ours to hash. As of the inspected 2.1.311 release Anthropic publishes a GPG-signed manifest.json that the official installer does not check; verifying it was declined by the operator.
# See "Download integrity" in doc/fetch-bins.md.

# claude installer (Anthropic Claude Code). Like nvm (slot 02) and rust (slot
# 10), claude is a SELF-MANAGING, SELF-UPDATING harness that owns its own tree
# (~/.local/share/claude/versions/<v>, with ~/.local/bin/claude symlinked at the
# active version by claude itself) rather than a single static binary we pin. So
# it does NOT go through install_bin / fb_check_bin / a versioned payload.
#
# INSTALL-IF-ABSENT, NEVER UPDATE — the nvm model, not the rust one. rust's slot
# runs `rustup update stable` on every pass; that is exactly wrong here, because
# claude is frequently LIVE (this fetcher can run while a claude process is
# using the very symlink it would rewrite), and Phase 5 runs on every installer
# invocation. The skip-if-present guard below is therefore the whole point of
# the slot: on a provisioned box it must be a clean no-op. Upgrades are claude's
# own job (`claude update`).
#
# Official installer (verified 2026-11-09): `curl -fsSL https://claude.ai/
# install.sh | bash` (the URL 302s to the dist host). It takes an optional
# `[stable|latest|VERSION]` arg and delegates to the native `claude install`
# path, landing ~/.local/bin/claude -> ~/.local/share/claude/versions/<v>. We
# pass `stable` — the conservative channel for a harness — and let claude self-
# update from there.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="claude"
fb_init
fb_require_os claude

# SKIP-IF-PRESENT, FIRST. Operability (`claude --version`), not bare presence:
# fb_init prepends $BIN_DIR to PATH, and a dangling/half-installed symlink there
# would pass `command -v` while being unrunnable. The && chain keeps it to the
# install branch only when claude is genuinely absent or broken.
if command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; then
    echo "claude already installed ($(claude --version 2>&1 | head -1)) — self-updates via 'claude update'; skipping."
    exit 0
fi

echo "Installing Claude Code (stable channel) via https://claude.ai/install.sh …"
curl -fsSL https://claude.ai/install.sh | bash -s stable

# Verify in place before declaring success. claude's installer puts the symlink
# in ~/.local/bin, already on PATH for this run via fb_init.
if ! claude --version >/dev/null 2>&1; then
    echo "Error: claude is not runnable after install." >&2
    exit 1
fi
echo "Installed Claude Code: $(claude --version 2>&1 | head -1)"
echo "  (self-updates via 'claude update'; this slot will skip on the next pass)"
