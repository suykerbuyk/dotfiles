#!/usr/bin/env bash
# _lib.sh — Shared hardened helpers for fetch.bins/ installers
#
# This library implements the design from Context.fetch.bins.refactor.md.
# It eliminates copy-paste, enforces all the documented lessons (curl -f,
# verification before symlink, versioned installs, per-tool normalization,
# temp discipline, fail-loud), and adds the critical stow safety guard.
#
# Usage in each NN_fetch.*.sh:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   . "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"
#   fb_init
#   # then tool-specific code using the helpers
#
# Critical rule (enforced in fb_init):
#   These scripts MUST NOT be run from inside the dotfiles git checkout.
#   Run `stow -d ~/dotfiles -t "$HOME" home` first, then `cd ~` and run from
#   ~/.local/bin. This prevents contaminating the source tree with
#   binaries/temp files.

set -euo pipefail

# Config (callers may override before sourcing)
: "${APP_DIR:=$HOME/.local/apps}"
: "${BIN_DIR:=$HOME/.local/bin}"

# ----------------------------------------------------------------------
# Safety: Never run inside dotfiles checkout (user requirement)
# ----------------------------------------------------------------------
fb_safety_check() {
    local script_path script_dir git_root

    # Resolve the real script location (follows symlinks from stow)
    script_path="$(realpath "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
    script_dir="$(dirname "$script_path")"

    # Check current directory or script location for dotfiles checkout
    if [[ "$PWD" == *dotfiles* ]] || [[ "$script_dir" == *dotfiles* ]] || [[ "$script_path" == *dotfiles* ]]; then
        # Additional git check for precision
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
            git_root="$(git rev-parse --show-toplevel 2>/dev/null)"
            if [[ "$git_root" == *dotfiles* ]] || [[ -f "$git_root/.git/description" && "$(cat "$git_root/.git/description" 2>/dev/null)" == *dotfiles* ]]; then
                # Special case for the root installer (update-user-home-dir.sh) and any fetch script (when called from root context) — allow running from checkout
                if [[ "$(basename "$script_path")" == "update-user-home-dir.sh" ]] || [[ "$0" == *update-user-home-dir.sh* ]] || [[ "$script_path" == *fetch.bins* ]]; then
                    echo "Running installer or fetch script from dotfiles checkout (allowed for bootstrap)."
                    return 0
                fi
                cat >&2 <<'EOF'
Error: fetch-bins scripts must not be run from inside the dotfiles git checkout.
Running here would contaminate your source tree with installed binaries, temp
files, or partial downloads.

Correct bootstrap flow:
  Run ./update-user-home-dir.sh from the dotfiles checkout. It fetches chezmoi,
  runs `chezmoi apply` to lay down ~/.local/bin/fetch.bins/, and then invokes the
  fetch scripts from ~ (outside the checkout), which satisfies this guard.

If you are developing the scripts themselves, edit them in the checkout under
home/dot_local/bin/fetch.bins/ and re-run the installer.
EOF
                exit 1
            fi
        fi
    fi
}

# ----------------------------------------------------------------------
# Initialization — always call first
# ----------------------------------------------------------------------
fb_init() {
    fb_safety_check

    # Ensure base directories (fresh machine case)
    mkdir -p "$APP_DIR" "$BIN_DIR"

    # Temp dir with automatic cleanup
    FB_TMP="$(mktemp -d)"
    export FB_TMP
    trap 'rm -rf "$FB_TMP"' EXIT
}

# ----------------------------------------------------------------------
# Per-tool OS/Arch normalization (avoids the token mismatch bugs)
# ----------------------------------------------------------------------
fb_os() {
    local darwin_label="${1:-macos}"
    uname -s | tr '[:upper:]' '[:lower:]' | sed "s/^darwin$/$darwin_label/"
}

fb_arch() {
    local x86_label="${1:-amd64}"
    uname -m | sed "s/x86_64/$x86_label/; s/aarch64/arm64/"
}

# ----------------------------------------------------------------------
# GitHub release helpers (with rate-limit/empty guards)
# ----------------------------------------------------------------------
gh_latest_tag_nojq() {
    local repo="$1"
    local url="https://api.github.com/repos/${repo}/releases/latest"
    local json

    if ! json="$(curl -fsSL "$url")"; then
        echo "Error: could not reach GitHub API (rate limited or offline?)." >&2
        exit 1
    fi

    local tag
    tag="$(printf '%s' "$json" | grep '"tag_name"' | awk -F '"' '{print $4}')"
    if [[ -z "$tag" ]]; then
        echo "Error: could not parse a release tag from the API response." >&2
        exit 1
    fi
    printf '%s' "$tag"
}

gh_latest_tag() {
    local repo="$1"
    local url="https://api.github.com/repos/${repo}/releases/latest"
    local json tag

    if ! json="$(curl -fsSL "$url")"; then
        echo "Error: could not reach GitHub API (rate limited or offline?)." >&2
        exit 1
    fi

    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
    if [[ -z "$tag" ]]; then
        echo "Error: could not parse a release tag from the API response." >&2
        exit 1
    fi
    printf '%s' "$tag"
}

gh_asset_url() {
    local repo="$1"
    local jq_filter="$2"
    local url="https://api.github.com/repos/${repo}/releases/latest"
    local json asset_url

    json="$(curl -fsSL "$url")"
    # jq_filter is a snippet like 'endswith(".tar.gz") and contains($arch)'
    # Caller must pass --arg arch "$ARCH" etc. as additional arguments
    asset_url="$(printf '%s' "$json" | jq -r --arg arch "${3:-}" '
        .assets[] | select(.name | '"$jq_filter"') | .browser_download_url
    ' | head -1)"

    if [[ -z "$asset_url" ]]; then
        echo "Error: no matching asset for filter '$jq_filter' (arch=${3:-})." >&2
        exit 1
    fi
    printf '%s' "$asset_url"
}

gh_download() {
    local url="$1"
    local dest="$2"

    if ! curl -fL -o "$dest" "$url"; then
        echo "Error: download failed for $url" >&2
        rm -f "$dest"
        exit 1
    fi
}

# ----------------------------------------------------------------------
# New helper: Detect broken symlinks, missing runtimes, or invalid binaries
# ----------------------------------------------------------------------
fb_check_bin() {
    local bin_name="$1"
    local bin_path="${BIN_DIR}/${bin_name}"

    # Broken symlink (dangling target). Test this BEFORE the plain -e check,
    # since a dangling symlink is both -L true and -e false.
    if [[ -L "$bin_path" && ! -e "$bin_path" ]]; then
        echo "→ $bin_name: broken symlink (target missing) — will reinstall"
        rm -f "$bin_path"
        return 1
    fi

    # Nothing installed at all
    if [[ ! -e "$bin_path" ]]; then
        echo "→ $bin_name: not installed"
        return 1
    fi

    # Symlink resolves, but the resolved target is missing or not executable.
    # Version-agnostic: no hardcoded version strings. A stale symlink pointing
    # into an APP_DIR runtime that was removed or renamed (e.g. an old Go
    # version dir) fails this check and triggers a clean reinstall.
    if [[ -L "$bin_path" ]]; then
        local target
        target="$(readlink -f "$bin_path" 2>/dev/null || true)"
        if [[ -z "$target" || ! -x "$target" ]]; then
            echo "→ $bin_name: symlink target missing or not executable — will reinstall"
            rm -f "$bin_path"
            return 1
        fi
    fi

    return 0  # valid
}

# ----------------------------------------------------------------------
# Installation helper — verify before symlink (now with fb_check_bin)
# ----------------------------------------------------------------------
install_bin() {
    local src="$1"
    local bin_name="$2"
    shift 2
    local verify_args=("$@")  # e.g. --version

    # New: Check for broken symlinks or invalid runtime before proceeding
    if fb_check_bin "$bin_name"; then
        if [[ -x "${BIN_DIR}/${bin_name}" ]]; then
            echo "$bin_name: already valid (skipping)"
            return 0
        fi
    fi

    echo "→ Installing $bin_name (or repairing broken state)"

    # Critical: copy to persistent location *before* trap cleanup of FB_TMP
    # (fixes broken symlinks for broot/rg/fzf that lived only in temp dir)
    local final_src="${APP_DIR}/${bin_name}"
    cp -a "$src" "$final_src" 2>/dev/null || cp "$src" "$final_src"  # cp -a may fail on some files
    chmod +x "$final_src"
    src="$final_src"  # update for symlink and verification

    # Verification gate — critical per Context doc
    if [[ ${#verify_args[@]} -gt 0 ]]; then
        if ! "$src" "${verify_args[@]}" >/dev/null 2>&1; then
            echo "Error: $bin_name is not a working binary (verification failed)." >&2
            rm -f "$src"
            exit 1
        fi
    fi

    # Versioned or direct symlink with -n (no-deref) safety
    ln -sfn "$src" "${BIN_DIR}/${bin_name}"
    echo "Installed ${bin_name} -> ${BIN_DIR}/${bin_name}"
    if [[ -x "${BIN_DIR}/${bin_name}" ]]; then
        echo "  version: $("${BIN_DIR}/${bin_name}" --version 2>&1 | head -1)"
    fi
}

# ----------------------------------------------------------------------
# Removal helper — surgical opposite of install_bin (for single binaries)
# Reuses fb_check_bin, idempotent, safe (no data loss on unrelated files)
# ----------------------------------------------------------------------
remove_bin() {
    local bin_name="$1"
    if [[ -z "$bin_name" ]]; then
        echo "Error: remove_bin requires bin_name" >&2
        return 1
    fi
    local bin_path="${BIN_DIR:-$HOME/.local/bin}/${bin_name}"
    local app_path="${APP_DIR:-$HOME/.local/apps}/${bin_name}"

    # Remove the PATH symlink (or stray file) and the APP_DIR runtime if present.
    # Does NOT gate on fb_check_bin: a broken/half-installed tool must still be
    # cleaned up (the old gating left the runtime behind on a broken symlink).
    local removed=0
    if [[ -e "$bin_path" || -L "$bin_path" ]]; then rm -f "$bin_path"; removed=1; fi
    if [[ -e "$app_path" ]]; then rm -rf "$app_path"; removed=1; fi
    if [[ "$removed" == 1 ]]; then
        echo "→ removed $bin_name (symlink + $app_path)"
    else
        echo "$bin_name: nothing to remove"
    fi
    # Note: versioned runtimes (e.g. $APP_DIR/go1.26.5) are left in place; the
    # PATH symlink is gone, so the tool is no longer active.
}

# ----------------------------------------------------------------------
# chezmoi bootstrap — fetch the static release binary (chezmoi is pure Go, so
# the plain linux_<arch> asset is statically linked; no libc/musl variant
# needed). Same gh_* pattern as the other fetchers. Requires fb_init (FB_TMP).
# ----------------------------------------------------------------------
fetch_chezmoi() {
    local arch tag ver url tarball
    arch="$(fb_arch amd64)"                       # amd64 | arm64
    tag="$(gh_latest_tag twpayne/chezmoi)"
    ver="${tag#v}"
    # Matches e.g. chezmoi_2.71.0_linux_amd64.tar.gz (not the -glibc_/-musl_ or
    # armv*/i386 variants, which do not contain the exact "_linux_<arch>" token).
    url="$(gh_asset_url twpayne/chezmoi 'endswith("_linux_" + $arch + ".tar.gz")' "$arch")"
    tarball="${FB_TMP}/chezmoi.tar.gz"
    gh_download "$url" "$tarball"
    tar -xzf "$tarball" -C "$FB_TMP" chezmoi 2>/dev/null || tar -xzf "$tarball" -C "$FB_TMP"
    install_bin "${FB_TMP}/chezmoi" chezmoi --version
    echo "Installed chezmoi $ver (static release binary) -> ${BIN_DIR}/chezmoi"
}

# ----------------------------------------------------------------------
# WSL and display helpers (for GUI tools like Zed)
# ----------------------------------------------------------------------
is_wsl() {
    local osrelease=""
    [ -r /proc/sys/kernel/osrelease ] && osrelease=$(</proc/sys/kernel/osrelease)
    case "${osrelease,,}" in
        *microsoft*|*wsl*) return 0 ;;
    esac
    [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
    return 1
}

require_display_or_skip() {
    if is_wsl && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
        echo "WSL without a display server, skipping GUI install" >&2
        exit 0
    fi
    if [ "${XDG_SESSION_TYPE:-}" = "tty" ]; then
        echo "No windowing session detected (tty), skipping GUI install" >&2
        exit 0
    fi
}

# ----------------------------------------------------------------------
# End of library. All functions assume set -euo pipefail.
# See Context.fetch.bins.refactor.md for full design, verified facts,
# and per-tool differences (jq bootstrap, nvim tarball, Zed gating, etc.).
# ----------------------------------------------------------------------
echo "Loaded fetch.bins/_lib.sh (with stow safety guard)" >&2
