#!/usr/bin/env bash
# 10-ssh-agent.sh — Guarded SSH agent setup for bash and zsh
# Part of revised setup-ssh-agent-systemd (Phase 2)
#
# Integrates patterns from ~/.local/bin/fetch.bins/_lib.sh:
# - Safety guards (idempotent, no side effects if already set)
# - Clear init-style logic with early returns
# - Comments for dry-run / verification style (non-destructive checks)
# - Prefers systemd user socket from ssh-agent.socket unit (%t/openssh_agent)
# - Falls back to keychain (if available) or manual ssh-agent
# - Works in both bash and zsh (POSIX + shell-specific checks)
# - Idempotent: can be sourced multiple times safely
# - Non-breaking: only sets if not already functional

# 1Password agent detection — FIRST and unconditional (per user guidance)
# Only activates on desktops where both the socket and `op` CLI exist.
# Safe on headless/WSL/servers (neither will be present). Overrides any
# prior SSH_AUTH_SOCK to prevent hangs with tsh/teleport.
OP_AGENT_SOCK="${HOME}/.1password/agent.sock"
if [[ -S "$OP_AGENT_SOCK" ]] && command -v op >/dev/null 2>&1; then
    export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
    export TELEPORT_USE_LOCAL_SSH_AGENT=false
    # Optional: ensure 1Password app is running (non-blocking)
    true
    return 0 2>/dev/null || true
fi

# Safety / Init style from _lib.sh (early guard, no-op if already good)
# (1Password check above already returned if applicable)
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    # Existing sock — quick validation (dry-run style check)
    if [[ -S "$SSH_AUTH_SOCK" ]]; then
        # Already have a working agent socket (systemd, keychain, manual)
        # Idempotent: do nothing
        return 0 2>/dev/null || true  # works in both bash/zsh
    fi
    # Sock path exists but not a socket — unset to allow fallback (rare)
    unset SSH_AUTH_SOCK
fi

# Prefer systemd user socket (from the new ssh-agent.socket unit)
# %t resolves to $XDG_RUNTIME_DIR (usually /run/user/$UID)
SYSTEMD_SOCK="${XDG_RUNTIME_DIR:-${TMPDIR:-/run/user/$(id -u)}}/openssh_agent"
if [[ -S "$SYSTEMD_SOCK" ]]; then
    export SSH_AUTH_SOCK="$SYSTEMD_SOCK"
    # Optional: ensure ssh-agent service is started if socket active
    systemctl --user is-active --quiet ssh-agent.socket 2>/dev/null || \
        systemctl --user start ssh-agent.socket 2>/dev/null || true
    return 0 2>/dev/null || true
fi

# Check if systemd socket unit is available (even if not yet activated)
# (skipped if 1Password agent was used above)
if systemctl --user list-unit-files --type=socket 2>/dev/null | grep -q 'ssh-agent\.socket'; then
    # Activate the socket (systemd will handle the agent on first use)
    systemctl --user start ssh-agent.socket 2>/dev/null || true
    if [[ -S "$SYSTEMD_SOCK" ]]; then
        export SSH_AUTH_SOCK="$SYSTEMD_SOCK"
        return 0 2>/dev/null || true
    fi
fi

# Optional: detect and note competing agents (GPG/GCR often conflict on desktops)
for competing in gpg-agent-ssh.socket gcr-ssh-agent.socket; do
    if systemctl --user is-active --quiet "$competing" 2>/dev/null; then
        echo "Note: Competing SSH agent detected ($competing). Consider: systemctl --user mask $competing" >&2
        break
    fi
done

# Fallback 1: keychain (common on many systems, manages ssh-agent)
# (skipped if 1Password or systemd socket already succeeded)
if command -v keychain >/dev/null 2>&1; then
    # keychain --eval style, but guarded and non-interactive
    # Uses --quiet to avoid output spam on every shell
    eval "$(keychain --eval --quiet --agents ssh 2>/dev/null || true)"
    if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
        return 0 2>/dev/null || true
    fi
fi

# Fallback 2: Manual ssh-agent (last resort, start if none running)
if [[ -z "${SSH_AGENT_PID:-}" ]] && ! pgrep -u "$UID" ssh-agent >/dev/null 2>&1; then
    # Start fresh agent, capture output (POSIX compatible)
    if SSH_AGENT_ENV="$(ssh-agent -s 2>/dev/null)"; then
        eval "$SSH_AGENT_ENV" >/dev/null
        # Clean up any temp file if created (ssh-agent -s doesn't usually)
        true
    fi
fi

# Final guard: if we have a sock now, ensure it's exported and valid
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
    export SSH_AUTH_SOCK
    # Optional: add identities if none loaded (non-destructive)
    if ! ssh-add -l >/dev/null 2>&1; then
        # Only attempt add if no keys listed; don't prompt
        ssh-add -q 2>/dev/null || true
    fi
fi

# End of script — always succeeds (non-breaking)
return 0 2>/dev/null || true
