#!/usr/bin/env bash
# update-user-home-dir.sh — dotfiles bootstrap installer (chezmoi-based).
#
# Lives at the project root ONLY (never applied into ~). Run it from the
# dotfiles checkout. It replaces the old GNU Stow flow with chezmoi.
#
# Because the chezmoi source encodes script names (executable_, dot_, ...), the
# fetch scripts are NOT runnable in-place from the checkout. So the order is:
#   1. Fetch the chezmoi binary (static Go release).
#   2. chezmoi apply  -> lays down all dotfiles AND ~/.local/bin tooling
#      (with decoded names) into $HOME.
#   3. Run the remaining tool fetchers from ~/.local/bin/fetch.bins (jq-first).
#   4. Set up the systemd user ssh-agent (only when a session bus is present).
#
# Usage:
#   ./update-user-home-dir.sh [--dry-run] [--force] [--uninstall]
#     --dry-run    show what would happen; make no changes
#     --force      re-fetch the chezmoi binary even if present
#     --uninstall  remove applied dotfiles + fetched tools (dry-run unless --force)
set -euo pipefail

DRY_RUN=false; FORCE=false; UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=true ;;
        --force)     FORCE=true ;;
        --uninstall) UNINSTALL=true ;;
        --help|-h)   awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; exit 0 ;;
        *)           echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# Must run from the dotfiles checkout root (where the chezmoi source home/ lives).
LIB="home/dot_local/bin/fetch.bins/executable__lib.sh"
if [[ ! -f "$LIB" ]]; then
    echo "Error: run from the dotfiles project root (chezmoi source home/ not found)." >&2
    exit 1
fi
SRC="$PWD/home"

# shellcheck source=/dev/null
. "$LIB"        # provides fb_init, fb_*, gh_*, install_bin, fetch_chezmoi, remove_bin
fb_init

CHEZMOI="${BIN_DIR}/chezmoi"
chezmoi_cmd() { "$CHEZMOI" --source "$SRC" --destination "$HOME" --no-tty "$@"; }

echo "=== dotfiles installer (chezmoi) ==="
echo "source:      $SRC"
echo "destination: $HOME"
$DRY_RUN && echo "mode: DRY-RUN (no changes)"
$FORCE   && echo "mode: --force"
echo

# ---------------------------------------------------------------------------
# Uninstall — dry-run unless --force. Never touches the repo source.
# ---------------------------------------------------------------------------
if $UNINSTALL; then
    echo "=== Uninstall ==="
    $FORCE || echo "(preview only — re-run with --force to actually remove)"
    if [[ -x "$CHEZMOI" ]]; then
        echo "-- managed dotfiles in $HOME --"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if $FORCE; then rm -f "$f" && echo "  removed $f"; else echo "  would remove $f"; fi
        done < <(chezmoi_cmd managed --include=files --path-style=absolute 2>/dev/null || true)
    else
        echo "(chezmoi not installed — skipping managed-file removal)"
    fi
    echo "-- fetched tools --"
    # Plain single-binary tools: remove_bin clears the ~/.local/bin symlink and
    # the ~/.local/apps/<name> runtime. Versioned runtime dirs (go<ver>/,
    # nvim-<ver>/, protoc-<ver>/) are intentionally left; the active symlink is
    # gone, so the tool is no longer on PATH. Keep this list in lockstep with the
    # fetch.bins/ scripts (every 0N_fetch.<tool>.sh must map to an entry here, a
    # special case below, or the rust block).
    for b in jq rg go gofmt broot fzf nvim ninja protoc chezmoi; do
        if $FORCE; then remove_bin "$b"; else echo "  would remove_bin $b"; fi
    done
    # nvm does not fit remove_bin: its PATH artifact is ~/.local/bin/nvm.sh (not
    # "nvm"), and NVM_DIR is ~/.local/apps/nvm. Remove both explicitly.
    if $FORCE; then
        rm -f "$HOME/.local/bin/nvm.sh"; rm -rf "$HOME/.local/apps/nvm"
        echo "  removed nvm (~/.local/bin/nvm.sh + ~/.local/apps/nvm)"
    else
        echo "  would remove nvm (~/.local/bin/nvm.sh + ~/.local/apps/nvm)"
    fi
    # zed installs an app bundle (~/.local/apps/zed.app, not "zed") plus a desktop
    # entry. remove_bin clears the ~/.local/bin/zed symlink; the bundle and the
    # .desktop file need explicit removal.
    if $FORCE; then
        remove_bin zed
        rm -rf "$HOME/.local/apps/zed.app"
        rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/zed.desktop"
        echo "  removed zed (zed.app bundle + desktop entry)"
    else
        echo "  would remove zed (~/.local/apps/zed.app + desktop entry)"
    fi
    # Rust is not a remove_bin tool: rustup owns ~/.cargo and ~/.rustup, so let
    # it tear itself down cleanly (removes toolchains, cargo, and the homes).
    RUSTUP_BIN="$HOME/.cargo/bin/rustup"
    if [[ -x "$RUSTUP_BIN" ]]; then
        if $FORCE; then "$RUSTUP_BIN" self uninstall -y && echo "  removed rust (rustup self uninstall)"; else echo "  would run: rustup self uninstall -y"; fi
    fi
    if $FORCE; then
        rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi" "${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi"
        echo "  removed chezmoi state/config (source repo left intact)"
    fi
    echo "=== Uninstall complete ==="
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Bootstrap the chezmoi binary
# ---------------------------------------------------------------------------
echo "=== Phase 1: chezmoi binary ==="
if ! $FORCE && fb_check_bin chezmoi && [[ -x "$CHEZMOI" ]]; then
    echo "chezmoi present: $("$CHEZMOI" --version | head -1)"
elif $DRY_RUN; then
    echo "DRY-RUN: fetch_chezmoi (static release binary)"
else
    $FORCE && remove_bin chezmoi
    fetch_chezmoi
fi
echo

# ---------------------------------------------------------------------------
# 2. Apply dotfiles + tooling into ~   (--force => never blocks on prompts)
# ---------------------------------------------------------------------------
echo "=== Phase 2: chezmoi apply ==="
if $DRY_RUN; then
    if [[ -x "$CHEZMOI" ]]; then
        chezmoi_cmd apply --dry-run --force || true
    else
        echo "DRY-RUN: chezmoi apply --force (chezmoi not yet installed)"
    fi
else
    chezmoi_cmd apply --force
    echo "Applied dotfiles from $SRC into $HOME"
fi
echo

# ---------------------------------------------------------------------------
# 3. Fetch remaining tools, from ~ (jq-first). chezmoi already done in Phase 1.
# ---------------------------------------------------------------------------
echo "=== Phase 3: tool fetchers (jq-first) ==="
FBD="$HOME/.local/bin/fetch.bins"
if $DRY_RUN && [[ ! -d "$FBD" ]]; then
    echo "DRY-RUN: would run $SRC fetchers from $FBD after apply"
elif [[ -d "$FBD" ]]; then
    mapfile -t scripts < <(find "$FBD" -maxdepth 1 -name '*.sh' ! -name '_lib.sh' -perm -u+x -printf '%f\n' | sort -V)
    for s in "${scripts[@]}"; do
        [[ "$s" == 09_fetch.chezmoi.sh ]] && continue   # already bootstrapped in Phase 1
        echo "→ $s"
        if $DRY_RUN; then
            echo "  DRY-RUN: $FBD/$s"
        else
            "$FBD/$s" || echo "  warning: $s exited non-zero (continuing)"
        fi
    done
else
    echo "warning: $FBD not found — did Phase 2 apply succeed?" >&2
fi
echo

# ---------------------------------------------------------------------------
# 4. systemd user ssh-agent — only when a user session bus exists.
#    (This is the C2 fix: the dbus guard is inline here, not an undefined
#    function, so the SSH phase actually runs on a normal desktop session.)
# ---------------------------------------------------------------------------
echo "=== Phase 4: ssh-agent (systemd user) ==="
SSH_SETUP="$HOME/.local/bin/setup-ssh-agent.sh"
if [[ -n "${XDG_RUNTIME_DIR:-}" || -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    if [[ -x "$SSH_SETUP" ]]; then
        if $DRY_RUN; then "$SSH_SETUP" --dry-run || true
        else "$SSH_SETUP" || echo "  warning: ssh-agent setup exited non-zero"; fi
    else
        echo "  $SSH_SETUP not found (skipped)"
    fi
else
    echo "  skipped: no user session bus (XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS unset — headless/WSL)"
fi
echo

echo "=== Bootstrap complete ==="
if $DRY_RUN; then
    echo "(dry-run — nothing changed)"
else
    echo "Reload your shell:  exec \$SHELL -l   (or: hash -r)"
fi
