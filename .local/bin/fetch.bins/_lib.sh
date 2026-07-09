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
#   Run `cd ~/dotfiles && stow -R .` first, then `cd ~` and run from ~/.local/bin.
#   This prevents contaminating the source tree with binaries/temp files.

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
                cat >&2 <<'EOF'
Error: fetch-bins scripts must not be run from inside the dotfiles git checkout.
Running here would contaminate your source tree with installed binaries, temp
files, or partial downloads.

Correct bootstrap flow:
  1. cd ~/dotfiles && stow -R .     # create ~/.local/bin symlinks
  2. cd ~ (or any directory outside the checkout)
  3. Run ~/.local/bin/fetch.all.bins.sh

If you are developing the scripts themselves, edit in ~/.local/bin/fetch.bins/
then re-stow.
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
# Installation helper — verify before symlink
# ----------------------------------------------------------------------
install_bin() {
    local src="$1"
    local bin_name="$2"
    shift 2
    local verify_args=("$@")  # e.g. --version

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
