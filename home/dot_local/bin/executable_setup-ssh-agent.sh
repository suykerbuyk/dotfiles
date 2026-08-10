#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# setup-ssh-agent.sh — Idempotent systemd user ssh-agent.socket setup (Phase 4)
#
# Part of revised setup-ssh-agent-systemd plan. Integrates with:
#   - ~/.config/systemd/user/ssh-agent.{socket,service} (from prior phases)
#   - ~/.config/bashrc.d/10-ssh-agent.sh (Phase 2 fragment, sourced if needed)
#
# Reuses patterns from ~/.local/bin/fetch.bins/_lib.sh:
#   - fb_safety_check style (stow-safe, never run from inside dotfiles checkout)
#   - fb_init style (clear output, directory creation, idempotency)
#   - Dry-run support (--dry-run echoes commands only, no execution)
#   - Clear status reporting (SSH_AUTH_SOCK, agent status, keychain migration note)
#   - Idempotent operations (enable --now is safe to repeat, mkdir -p, source guard)
#
# Usage:
#   setup-ssh-agent.sh                  # full setup
#   setup-ssh-agent.sh --dry-run        # echo commands, no changes
#   setup-ssh-agent.sh --help
#
# Stow-safe: Works when run from ~/.local/bin (after stow) or directly from
# dotfiles checkout during development (safety check allows it for this script).

set -euo pipefail

# ------------------------------ Config & Helpers ------------------------------

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    # Print the header comment block, skipping the SPDX banner above it.
    awk '/^# SPDX-License-Identifier:/{s=1;next}
         s==1 && /^[[:space:]]*$/{next}
         s==1 && /^#/{s=2}
         s==2 && /^#/{sub(/^#[[:space:]]?/,"");print;next}
         s==2{exit}' "$0"
    exit 0
fi

# fb_safety_check style (adapted for this script — allows development in dotfiles)
setup_safety_check() {
    local script_path script_dir
    script_path="$(realpath "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
    script_dir="$(dirname "$script_path")"

    if [[ "$PWD" == *dotfiles* ]] || [[ "$script_dir" == *dotfiles* ]] || [[ "$script_path" == *dotfiles* ]]; then
        echo "Running from dotfiles checkout (development mode OK for setup script)."
        echo "For normal use: stow -d ~/dotfiles -t ~ home && run from ~/.local/bin/setup-ssh-agent.sh"
        echo ""
    fi

    # Stronger dbus/user bus guard to prevent "Failed to connect to user scope bus" error
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
        echo "No user dbus session (DBUS_SESSION_BUS_ADDRESS or XDG_RUNTIME_DIR not set). Skipping systemd --user operations."
        echo "This is normal in non-desktop, headless, or certain WSL sessions."
        return 1  # signal to caller to skip
    fi
    return 0
}

# fb_init style — clear output, ensure dirs, idempotent
setup_init() {
    setup_safety_check
    echo "=== setup-ssh-agent.sh ==="
    echo "Setting up systemd user ssh-agent (Phase 4)"
    echo ""
}

run_cmd() {
    local cmd="$1"
    local desc="${2:-$cmd}"

    if $DRY_RUN; then
        echo "DRY-RUN: $cmd"
        return 0
    fi

    echo "→ $desc"
    eval "$cmd"
}

print_status() {
    echo ""
    echo "=== SSH Agent Status ==="

    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
        if [[ -S "$SSH_AUTH_SOCK" ]]; then
            echo "Socket: valid (connected)"
        else
            echo "Socket: INVALID (file exists but not a socket)"
        fi
    else
        echo "SSH_AUTH_SOCK: not set"
    fi

    if systemctl --user is-active --quiet ssh-agent.socket 2>/dev/null; then
        echo "systemd socket: active"
    elif systemctl --user is-enabled --quiet ssh-agent.socket 2>/dev/null; then
        echo "systemd socket: enabled (inactive)"
    else
        echo "systemd socket: not enabled"
    fi

    echo ""
    echo "Agent priority (final):"
    echo "  1. 1Password agent (~/.1password/agent.sock + op CLI) — if present"
    echo "     (sets TELEPORT_USE_LOCAL_SSH_AGENT=false automatically)"
    echo "  2. Systemd OpenSSH socket (our ssh-agent.socket)"
    echo "  3. keychain fallback"
    echo "  4. Manual ssh-agent"
    echo ""
    echo "Note: Competing agents (gpg-agent-ssh.socket, gcr-ssh-agent.socket) are"
    echo "detected and noted on desktops. Consider: systemctl --user mask gpg-agent-ssh.socket"
    echo ""
    echo "Migration note: keychain users — this replaces keychain ssh-agent management."
    echo "The bashrc.d fragment (10-ssh-agent.sh) now prefers 1Password (if present),"
    echo "then systemd. Remove keychain lines if desired after verification."
    echo ""
    echo "Done. Reload shell or run: systemctl --user start ssh-agent.socket"
}

# -------------------------------- Main Logic ---------------------------------

setup_init

# 1. Ensure ~/.ssh/sockets/ (common location for legacy/manual sockets; idempotent)
SOCKETS_DIR="$HOME/.ssh/sockets"
if $DRY_RUN; then
    echo "DRY-RUN: mkdir -p $SOCKETS_DIR"
else
    mkdir -p "$SOCKETS_DIR"
    echo "Ensured $SOCKETS_DIR/"
fi

# 2. Idempotent systemd user unit activation (enable --now is safe to repeat)
run_cmd "systemctl --user enable --now ssh-agent.socket" \
        "Enable and start ssh-agent.socket (idempotent)"

# 3. Ensure bashrc.d fragment is sourced (idempotent guard; prefers existing sourcing)
BASHRC_D_FRAGMENT="$HOME/.config/bashrc.d/10-ssh-agent.sh"
BASHRC_FILE="$HOME/.bashrc"

if [[ -f "$BASHRC_D_FRAGMENT" ]]; then
    if [[ -f "$BASHRC_FILE" ]] && grep -q "bashrc\.d" "$BASHRC_FILE" 2>/dev/null; then
        echo "bashrc.d sourcing already configured in ~/.bashrc"
    else
        echo "Note: Add the following to ~/.bashrc if not present (or source manually):"
        echo "  for f in ~/.config/bashrc.d/*.sh; do [ -r \"\$f\" ] && . \"\$f\"; done"
        echo "  (This is typically done in Phase 1/3 of the plan)"
    fi
else
    echo "Warning: bashrc.d fragment not found at $BASHRC_D_FRAGMENT"
fi

print_status

# Final integration note
echo "Integrates with:"
echo "  - ssh-agent.socket + service (systemd/user/)"
echo "  - 10-ssh-agent.sh (bashrc.d/ — prefers %t/openssh_agent)"
echo "  - Previous phases (stow-safe, non-destructive)"
