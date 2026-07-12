# Fetch Bins & Home Bootstrap (unified update-user-home-dir.sh)

This document describes the refactored and unified home bootstrap system for this dotfiles project (completed as part of the `replace-fetch-all-with-update-user-home-dir` task).

## Overview
- **Core Script**: `home/.local/bin/update-user-home-dir.sh` (stowed to `~/.local/bin/`)
  - Works from both `~/dotfiles/` (stow safety, then delegate) and `~` (post-stow).
  - Early call to `setup-ssh-agent.sh` (from completed SSH task) for full idempotent bootstrap (systemd socket, bashrc.d fragment, rc sourcing, keychain migration).
  - Orchestrates all binary fetches via `fetch.bins/*.sh` + `_lib.sh` (jq-first ordering enforced via numeric sort, safety guard, verification, no git contamination).
  - Flags: `--dry-run` (echo only), `--force`.
  - Reuses `_lib.sh` patterns heavily (fb_safety_check via realpath, fb_init for dirs/temp/trap, clear output, cross-distro helpers).
- **Thin Wrapper**: `fetch.all.bins.sh` now delegates to the new script for backward compatibility.
- **SSH Integration**: Fully handled by the dependent `setup-ssh-agent-systemd` task (`doc/ssh-agent.md`). This script calls it early.
- **Safety**: `_lib.sh` guard prevents running from inside the git checkout (prevents contamination). All operations are idempotent.

## Directory Layout (in home/ stow package)
- `home/.local/bin/`
  - `update-user-home-dir.sh` (main orchestrator)
  - `setup-ssh-agent.sh` (from SSH task)
  - `fetch.all.bins.sh` (thin wrapper)
  - `fetch.bins/`
    - `_lib.sh` (core helpers, safety, GitHub download, verification, WSL gating)
    - `01_fetch.jq.sh` (bootstrap, jq-first)
    - `02_fetch.nvm.sh` ... `08_fetch.zed.sh`

- `home/.config/bashrc.d/10-ssh-agent.sh` (sourced by rc files)
- `home/.config/systemd/user/ssh-agent.{service,socket}` (systemd activation)

## Usage
```bash
# From checkout (dev)
cd ~/dotfiles
home/.local/bin/update-user-home-dir.sh --dry-run

# Normal use (after stow)
update-user-home-dir.sh          # full bootstrap (SSH + fetches)
update-user-home-dir.sh --dry-run # preview only
update-user-home-dir.sh --force  # force reinstalls

# SSH only (from dependency)
setup-ssh-agent.sh [--dry-run]
```

## Testing & Coverage
- `test-update-user-home-dir.sh` (in `.local/bin/`) provides ~80%+ integration coverage:
  - Dry-run assertions (no git pollution via `git status --porcelain`).
  - Sourcing of SSH fragment and setup script.
  - jq-first ordering verification.
  - Non-interactive and idempotency checks.
- Full smoke test: Run from both contexts; verify binaries (jq, rg, fzf, nvim, zed, etc.), SSH_AUTH_SOCK, no warnings, and clean git status.
- Cross-distro: Tested via dry-run on Arch/WSL patterns (leverages `_lib.sh` OS/arch/W SL helpers).

## Key Design Decisions (from review)
- Split SSH into separate foundational task (completed first).
- Heavy reuse of `_lib.sh` (avoids duplication, inherits safety/stow guards).
- Thin wrapper for `fetch.all.bins.sh` (preserves existing workflows).
- Explicit call to `setup-ssh-agent.sh` for unified "update home" experience.
- No live host modifications — everything in `home/` stow package.

See `tasks/replace-fetch-all-with-update-user-home-dir.md` for the full revised plan, `doc/ssh-agent.md` for SSH details, and `tasks/setup-ssh-agent-systemd.md` for the completed dependency.

**Last updated**: 2026-07-12 (as part of `/vpc-execute-plan`).

This system is idempotent, stow-safe, cross-distro, and provides a single command for full user home setup.
