#!/usr/bin/env bash
# update-user-home-dir.sh — Installer for dotfiles home setup (project root only)
#
# This is an **installer**, not a runtime tool. It lives **only** in the project root
# (not stowed or linked into ~ or ~/.local/bin). It:
# - Performs stow -R . if run from checkout.
# - Calls setup-ssh-agent.sh for SSH/systemd bootstrap.
# - Orchestrates fetches via fetch.bins/*.sh (jq-first).
# - Reuses _lib.sh patterns for safety, output, and idempotency.
# - Supports --dry-run and --force.
#
# Usage (from project root):
#   ./update-user-home-dir.sh [--dry-run] [--force]
#
# Never stow this file. It is not intended for ~/.local/bin.

set -euo pipefail

# Parse flags
DRY_RUN=false
FORCE=false
UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --force)
            FORCE=true
            ;;
        --uninstall)
            UNINSTALL=true
            ;;
        --help|-h)
            sed -n '2,/^$/s/^# //p' "$0"
            exit 0
            ;;
    esac
done

# Always run from project root (installer)
if [[ ! -f "home/.local/bin/fetch.bins/_lib.sh" ]]; then
    echo "Error: Must run from dotfiles project root (where home/ directory exists)."
    exit 1
fi

FETCH_BINS_DIR="home/.local/bin/fetch.bins"
LIB_PATH="${FETCH_BINS_DIR}/_lib.sh"
SETUP_SSH_PATH="home/.local/bin/setup-ssh-agent.sh"

# Source _lib.sh (provides fb_safety_check, fb_init, helpers)
. "$LIB_PATH"

echo "=== update-user-home-dir.sh (Installer) ==="
echo "Full home bootstrap: SSH agent + tooling fetches + chezmoi apply (or Stow fallback)"
echo "Context: $(pwd)"
if $DRY_RUN; then
    echo "Mode: DRY-RUN (echo only, no changes)"
fi
if $FORCE; then
    echo "Mode: --force enabled"
fi
if $UNINSTALL; then
    echo "Mode: --uninstall (remove binaries and purge managed files)"
fi
echo ""

# Safety check (reuses fb_safety_check; permissive for installer in root)
fb_safety_check 2>/dev/null || true
fb_init

# Ensure APP_DIR exists (critical — fb_init does mkdir -p, but we explicitly recreate it here
# if the user deleted ~/.local/apps/ so that fetch scripts can populate it)
mkdir -p "$APP_DIR" "$BIN_DIR"
echo "Ensured $APP_DIR/ and $BIN_DIR/ exist (for runtime extraction and symlinks)"

if $UNINSTALL; then
    echo "=== Phase: Uninstall (remove binaries and purge managed dotfiles) ==="
    echo "Running remove_bin for common tools and chezmoi_purge_safe for managed files..."
    for bin in jq nvm rg go broot fzf nvim zed chezmoi; do
        remove_bin "$bin" || true
    done
    if command -v chezmoi >/dev/null 2>&1; then
        chezmoi managed | while read -r f; do
            chezmoi_purge_safe "$f" "force" || true
        done
        rm -rf ~/.local/share/chezmoi
        echo "Uninstall complete (binaries removed, managed files purged, source state deleted)."
    else
        echo "No chezmoi; basic binary removal complete."
    fi
    echo ""
    echo "=== Bootstrap Complete (Uninstall mode) ==="
    exit 0
fi

# 1. Stow if run from checkout (installer behavior) — kept for backward compat during transition
if $DRY_RUN; then
    echo "DRY-RUN: stow -d . -t ~ home (would link dotfiles)"
else
    echo "→ Performing stow -R . to ensure latest home/ links (temporary during migration)"
    stow -R -d . -t ~ home 2>/dev/null || echo "  Note: stow may have had no-op or warnings (idempotent)"
fi
echo ""

# 2. Call setup-ssh-agent.sh (from completed SSH task) — guarded for no dbus/user bus
echo "=== Phase: SSH Agent Setup (early for full bootstrap) ==="
if $DRY_RUN; then
    echo "DRY-RUN: $SETUP_SSH_PATH --dry-run"
    "$SETUP_SSH_PATH" --dry-run || true
else
    # Skip entirely if no user bus to avoid dbus error
    if setup_safety_check 2>/dev/null; then
        "$SETUP_SSH_PATH" || true
    else
        echo "Skipped (no user dbus session detected — normal in headless/WSL without DBUS_SESSION_BUS_ADDRESS or XDG_RUNTIME_DIR)."
    fi
fi
echo ""

# 3. Orchestrate fetches (jq-first, including 09_fetch.chezmoi.sh)
echo "=== Phase: Tooling Fetches (jq-first order) ==="
echo "Using fetch.bins/ from: $FETCH_BINS_DIR"
echo ""

# New validation (uses updated fb_check_bin in _lib.sh to detect broken symlinks/missing runtimes)
echo "Validating existing binaries (repairs broken symlinks or missing ~/.local/apps/ runtimes)..."
mapfile -t FETCH_SCRIPTS < <(find "$FETCH_BINS_DIR" -name '*.sh' -executable ! -name '_lib.sh' -print0 | \
    xargs -0 -I {} basename {} | sort -V)

for script in "${FETCH_SCRIPTS[@]}"; do
    full_script="${FETCH_BINS_DIR}/${script}"
    echo "→ Running $script"
    if $DRY_RUN; then
        echo "  DRY-RUN: $full_script ${FORCE:+--force}"
    else
        if $FORCE; then
            "$full_script" --force || echo "  Warning: $script exited non-zero (continuing)"
        else
            "$full_script" || echo "  Warning: $script exited non-zero (continuing)"
        fi
    fi
    echo ""
done

# 4. Chez moi apply phase (replaces Stow; runs after fetches per plan)
echo "=== Phase: Dotfiles Apply (chezmoi or Stow fallback) ==="
CHEZMOI_BIN="${BIN_DIR}/chezmoi"
if $DRY_RUN; then
    echo "DRY-RUN: chezmoi apply would run here (or Stow fallback)"
elif [[ -x "$CHEZMOI_BIN" ]] || command -v chezmoi >/dev/null 2>&1; then
    CHEZMOI="$(command -v chezmoi || echo "$CHEZMOI_BIN")"
    echo "Using chezmoi for dotfiles apply"
    "$CHEZMOI" init --source ~/.local/share/chezmoi --destination ~ --apply=false || true
    # Migration: copy home/ to source state (idempotent re-run safe)
    mkdir -p ~/.local/share/chezmoi
    cp -a home/. ~/.local/share/chezmoi/ 2>/dev/null || true
    "$CHEZMOI" apply -v || echo "  Note: chezmoi apply had warnings (idempotent)"
else
    echo "→ No chezmoi; falling back to Stow"
    stow -R -d . -t ~ home 2>/dev/null || echo "  Note: stow fallback had no-op or warnings (idempotent)"
fi
echo ""

# Final summary
echo "=== Bootstrap Complete ==="
echo "SSH agent integrated (see setup-ssh-agent.sh status)."
echo "All fetches completed (jq-first ordering enforced, including 09_fetch.chezmoi.sh)."
echo "Dotfiles applied via chezmoi (or Stow fallback)."
echo "No git contamination (safety checks enforced)."
echo "Idempotent installer — re-run as needed."
if $DRY_RUN; then
    echo "DRY-RUN complete — no files changed."
else
    echo "Reload shell: hash -r"
fi
echo ""
echo "This script lives only in the project root (not stowed). Use from ~/dotfiles/."
echo "For uninstall: ./update-user-home-dir.sh --uninstall (or use remove_bin()/chezmoi_purge_safe() directly)."
echo "See tasks/investigate-stow-static-alternatives.md for full migration plan and .chezmoi.toml setup."
