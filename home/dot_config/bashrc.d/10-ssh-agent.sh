#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

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
#
# ${UID} rather than $(id -u): this file is sourced by every INTERACTIVE shell and
# both bash and zsh set UID as a builtin variable, so the command substitution was
# a fork per shell for a value the shell already had. It fired on exactly the
# machines with no XDG_RUNTIME_DIR to short-circuit it first — headless boxes and
# FreeBSD, where there is no systemd socket to find at the end of it.
SYSTEMD_SOCK="${XDG_RUNTIME_DIR:-${TMPDIR:-/run/user/${UID:-$(id -u)}}}/openssh_agent"
if [[ -S "$SYSTEMD_SOCK" ]]; then
    export SSH_AUTH_SOCK="$SYSTEMD_SOCK"
    # Optional: ensure ssh-agent service is started if socket active
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user is-active --quiet ssh-agent.socket 2>/dev/null || \
            systemctl --user start ssh-agent.socket 2>/dev/null || true
    fi
    return 0 2>/dev/null || true
fi

# Everything to the end of this block is systemd-specific. `command -v` is a
# BUILTIN, so probing once costs nothing — while without the guard a systemd-less
# box (FreeBSD, musl containers, WSL1) paid THREE failed forks per interactive
# shell, one for list-unit-files and two for the competing-agent loop, to discover
# each time that systemd is still not installed.
if command -v systemctl >/dev/null 2>&1; then
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
fi

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

# Fallback 2: a plain ssh-agent on a PREDICTABLE socket path.
#
# The old guard was `! pgrep -u "$UID" ssh-agent` — "start one only if none is
# already running". That is not a question this script can act on. Knowing an
# agent PROCESS exists says nothing about where its socket is, and by this line we
# have already established we have no usable SSH_AUTH_SOCK. Measured on FreeBSD,
# where a detached agent from an earlier session made pgrep succeed, the branch
# was skipped, and the interactive shell was left with NO agent at all. The same
# hole exists on any Linux box without the systemd unit; systemd only hides it by
# returning further up.
#
# `ssh-agent -s` was the other half of the problem: it lets the agent pick a
# random /tmp path, so the socket is reachable only by the one shell that ran it
# and every sibling shell spawns its own keyless agent.
#
# Pin the socket instead — exactly what the systemd unit provides on Linux: ONE
# predictable path per user, so the second shell REUSES the first shell's agent.
# Socket location: $XDG_RUNTIME_DIR when the session provides one (Linux desktop),
# otherwise ~/.ssh, which this repo already manages at 0700.
#
# 🔴 NOT /tmp. A PREDICTABLE name in a world-writable directory is a path another
# local user can pre-create, and the stale-socket branch below would then rm -f
# it — a symlink-attack shape. The predictability that makes reuse work is exactly
# what makes the directory choice load-bearing. ~/.ssh is private by construction.
DF_AGENT_DIR="${XDG_RUNTIME_DIR:-$HOME/.ssh}"
DF_AGENT_SOCK="$DF_AGENT_DIR/ssh-agent-${UID:-$(id -u)}.sock"
if [[ ! -d "$DF_AGENT_DIR" ]]; then
    : # no private directory to put a socket in; leave the agent unset rather
      # than inventing one somewhere world-writable
elif [[ -S "$DF_AGENT_SOCK" ]]; then
    # ssh-add exits 2 for "cannot connect" and 1 for "connected, no identities".
    # Testing for non-2 rather than for success is what stops a live-but-empty
    # agent being discarded and respawned on every shell.
    SSH_AUTH_SOCK="$DF_AGENT_SOCK" ssh-add -l >/dev/null 2>&1
    _agent_rc=$?
    if [[ $_agent_rc -ne 2 ]]; then
        export SSH_AUTH_SOCK="$DF_AGENT_SOCK"
    else
        # Stale socket left by a dead agent. It is ours by name and we have just
        # proved nothing answers on it; ssh-agent -a needs the path free.
        rm -f "$DF_AGENT_SOCK"
    fi
    unset _agent_rc
fi
if [[ -z "${SSH_AUTH_SOCK:-}" ]] && [[ -d "$DF_AGENT_DIR" ]] && command -v ssh-agent >/dev/null 2>&1; then
    ssh-agent -a "$DF_AGENT_SOCK" >/dev/null 2>&1 && export SSH_AUTH_SOCK="$DF_AGENT_SOCK"
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
