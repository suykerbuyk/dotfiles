#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

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

    # Put freshly-fetched binaries on PATH for the rest of THIS run. The env
    # layer that normally adds ~/.local/bin is only laid down by `chezmoi apply`
    # and is never sourced into the running installer process — so without this a
    # tool fetched earlier (jq, above all) is invisible to a bare `jq` call in a
    # later fetcher, and the whole jq-first ordering buys nothing. Idempotent:
    # skip when BIN_DIR is already present so re-sourcing never stacks duplicates.
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) PATH="$BIN_DIR:$PATH"; export PATH ;;
    esac

    # Temp dir with automatic cleanup
    FB_TMP="$(mktemp -d)"
    export FB_TMP
    trap 'rm -rf "$FB_TMP"' EXIT
}

# ----------------------------------------------------------------------
# Per-slot platform support
# ----------------------------------------------------------------------
# ONE table, because "does this tool run here" is a property of what UPSTREAM
# ships, not of anything a fetcher computes. Before this existed each slot
# discovered its own unavailability in its own way and reported it in its own
# words: slot 03 said "no matching asset", slot 11 said "unsupported platform",
# slot 15 and 16 both said "unsupported architecture" for what was really an OS
# problem, and slots 05 and 12 said nothing at all until they had downloaded
# tens of megabytes and tried to run a Linux binary. Fifteen ways to say "not
# here" is fifteen things to read before you know nothing is wrong.
#
# Every entry below was VERIFIED against the upstream release list on
# 2026-08-29, not inferred from the tool being Rust or Go:
#
#   freebsd YES  nvm (shell script), go, fzf, chezmoi, age, starship
#                (starship-x86_64-unknown-freebsd.tar.gz), rust
#                (static.rust-lang.org/rustup/dist/x86_64-unknown-freebsd → 200)
#   freebsd NO   jq, rg, broot, nvim, zed, ninja, podman, tree-sitter, ghostty,
#                herdr, fd, bat, delta, xh, tsh, op, proxmox-mcp
#
# proxmox-mcp was verified against its release API on 2026-09-04, not inferred
# from the tool being Go: upstream ships linux/darwin amd64+arm64 and a windows
# .exe, and no FreeBSD asset at all.
#
# There is deliberately NO default arm. An undeclared tool is a hard error, not
# a guess: a permissive default reproduces exactly the 404-on-FreeBSD behavior
# this table exists to end, and a restrictive one would silently stop
# installing a tool on a platform that supports it. The harness asserts every
# slot is declared, so adding slot 24 without a decision fails the suite rather
# than shipping a wrong answer.
fb_supported_os() {
    case "$1" in
    # Upstream ships a FreeBSD build, or the tool is a portable script.
    nvm|go|gofmt|fzf|chezmoi|age|age-keygen|starship|rust|rustc|cargo|rustup)
        echo "linux darwin freebsd" ;;
    # No FreeBSD build upstream. jq is listed here rather than as an error
    # because slot 01 already defers to a system jq, which is how FreeBSD gets
    # one (pkg install jq) — the fetch is what is unavailable, not the tool.
    jq|rg|broot|nvim|zed|ninja|podman|tree-sitter|ghostty|herdr|fd|bat|delta|xh|tsh|tctl|op|proxmox-mcp)
        echo "linux darwin" ;;
    *)
        echo "" ;;
    esac
}

# fb_require_os [tool] — skip this slot cleanly when the tool has no build for
# the running OS. Defaults to $BIN_NAME, which every slot sets immediately
# before fb_init.
#
# Exits 0, deliberately. The installer's Phase 5 loop reports a non-zero
# fetcher as `warning: ... exited non-zero (continuing)`, which is the right
# noise for a BREAKAGE and the wrong noise for a tool that was never going to
# be there. A skip is not a degraded success; it is the correct outcome, and it
# should read like one.
#
# Call it from a fetcher SCRIPT, never from one of the fetch_* helper functions
# below: those are invoked from update-user-home-dir.sh, where `exit 0` would
# end the installer instead of the slot.
fb_require_os() {
    local tool="${1:-${BIN_NAME:-}}" cur list
    if [[ -z "$tool" ]]; then
        echo "Error: fb_require_os needs a tool name (BIN_NAME unset)." >&2
        exit 1
    fi
    cur="$(df_os)"
    list="$(fb_supported_os "$tool")"
    if [[ -z "$list" ]]; then
        echo "Error: no platform declaration for '$tool' in fb_supported_os()." >&2
        echo "       Add one to _lib.sh; there is no default on purpose." >&2
        exit 1
    fi
    case " $list " in
        *" $cur "*) return 0 ;;
    esac
    echo "${tool}: no upstream build for ${cur} (upstream ships: ${list}) — skipping."
    exit 0
}

# ----------------------------------------------------------------------
# Per-tool OS/Arch normalization (avoids the token mismatch bugs)
# ----------------------------------------------------------------------
# df_os — the OS name, lowercased: linux, freebsd, darwin, ...
#
# Memoized in DF_OS so `uname` is forked at most ONCE per shell, and only when
# something actually asks. The laziness is not a micro-optimization: this
# helper is duplicated into the bottom of the env layer, which is sourced by
# every `zsh -c`, and the standing rule there is that a fork is a tax on every
# shell in every loop. Defining a function costs nothing; deriving eagerly
# would bill everyone for an answer most shells never need.
#
# DF_OS is deliberately NOT exported, for the same reason DOTFILES_ENV_LOADED
# is not: a child shell re-derives its own answer rather than trusting an
# inherited flag.
#
# The case arms cover the platforms this repo targets without a second fork;
# the tr fallback keeps an unlisted OS correct rather than empty.
df_os_init() {
    [ -z "${DF_OS:-}" ] || return 0
    case $(uname -s) in
    Linux) DF_OS=linux ;;
    FreeBSD) DF_OS=freebsd ;;
    Darwin) DF_OS=darwin ;;
    *) DF_OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
    esac
}

df_os() { df_os_init; printf '%s\n' "${DF_OS}"; }

# df_is_linux / df_is_freebsd — silent predicates, exit status only.
#
# Prefer these to an inline `[ "$(uname -s)" = Linux ]`: that idiom forks on
# every call, and this repo had spelled the same question three different ways
# in three files before they were consolidated here.
df_is_linux() { df_os_init; [ "${DF_OS}" = linux ]; }
df_is_freebsd() { df_os_init; [ "${DF_OS}" = freebsd ]; }

# fb_os [darwin_label] — the tool-facing name, with Darwin renamed to whatever
# the upstream project calls it (jq says "macos", age says "darwin"). Signature
# and output are unchanged; it now derives from df_os so there is ONE place
# that asks the kernel, and costs zero forks after the first call rather than
# three on every call.
fb_os() {
    local darwin_label="${1:-macos}"
    df_os_init
    case "${DF_OS}" in
    darwin) printf '%s\n' "${darwin_label}" ;;
    *) printf '%s\n' "${DF_OS}" ;;
    esac
}

# fb_rust_triple [linux_libc] — the Rust target triple for this host.
#
# Two independent normalizations, and BOTH bite on FreeBSD:
#   arch — FreeBSD's `uname -m` reports amd64 where Linux reports x86_64. That
#          single token is why slot 10 failed with "unsupported arch 'amd64'";
#          it was never an unsupported architecture, just an unmapped name.
#   os   — linux takes a libc suffix (starship ships musl, rustup ships gnu),
#          darwin is apple-darwin, freebsd is a bare -unknown-freebsd.
#
# SCOPE: this returns a triple; it does not promise upstream BUILT it. The
# platform table is OS-granular, so one known OS-by-arch gap survives it —
# starship ships x86_64-unknown-freebsd but no aarch64 variant, so arm64
# FreeBSD would 404 here. That sits with the existing "slots untested on
# arm64" thread rather than being modelled as a second table dimension.
fb_rust_triple() {
    local libc="${1:-gnu}" arch
    case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) arch="$(uname -m)" ;;
    esac
    df_os_init
    case "${DF_OS}" in
    linux) printf '%s-unknown-linux-%s\n' "$arch" "$libc" ;;
    darwin) printf '%s-apple-darwin\n' "$arch" ;;
    freebsd) printf '%s-unknown-freebsd\n' "$arch" ;;
    *) printf '%s-unknown-%s\n' "$arch" "${DF_OS}" ;;
    esac
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

    # GitHub returns this JSON minified on one line, so a bare `grep '"tag_name"'`
    # matches the WHOLE document (grep is line-based) and awk -F'"' '{print $4}'
    # grabs the 4th quoted field of the entire blob -- the "url" field's value,
    # not the tag. grep -o isolates the "tag_name":"..." pair first so the awk
    # split is relative to it, not the whole line, regardless of JSON layout.
    local tag
    tag="$(printf '%s' "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | awk -F '"' '{print $4}')"
    if [[ -z "$tag" ]]; then
        echo "Error: could not parse a release tag from the API response." >&2
        exit 1
    fi
    printf '%s' "$tag"
}

# ----------------------------------------------------------------------
# Version pinning — FB_PIN_<TOOL>
# ----------------------------------------------------------------------
# ONE way to say "hold this tool at this version". Before this there was exactly
# one per-slot spelling, OP_FETCH_VERSION, and it was DEAD CODE: slot 23
# computed it and never compared it to anything, so bumping it changed nothing
# on a box that already had op.
#
# This is the mechanism behind the standing ruling: an UNPINNED tool tracks
# upstream and keeps exactly one payload on disk; a PINNED tool holds the named
# version. Pinning is therefore the only supported way to stop a tool moving,
# which is precisely what makes prune-to-one safe to adopt — without it there is
# no way to say "stay here", and "we do not need old versions" and "this one
# must not move" cannot both be true.
#
# The tool name is normalized because env var names cannot carry '-', and three
# slots would otherwise be unpinnable:
#   tree-sitter -> FB_PIN_TREE_SITTER   proxmox-mcp -> FB_PIN_PROXMOX_MCP
#   age-keygen  -> FB_PIN_AGE_KEYGEN
# Pure bash, no `tr`: GNU and BSD tr disagree about character-class handling,
# and this runs on both.
#
# The pin value is whatever the SLOT calls a version, because that is the string
# it will interpolate into a path and a URL. Slot 04 is the one that surprises:
# go.dev reports "go1.26.5", prefix included, so FB_PIN_GO=go1.26.5 — not 1.26.5.
#
# Prints the version and returns 0 when set; prints nothing and returns 1 when
# unset, so a caller may branch on the status or on the output.
fb_pin() {
    local tool="$1" var
    var="FB_PIN_${tool^^}"
    var="${var//-/_}"
    var="${var//./_}"
    [[ -n "${!var:-}" ]] || return 1
    printf '%s' "${!var}"
}

# ----------------------------------------------------------------------
# Shared version prune
# ----------------------------------------------------------------------
#   fb_prune_versions <keep> <spare|""> <glob> [glob...]
#
# Replaces four hand-rolled copies (slots 12, 16, 22, 24) that had already
# drifted apart in signature, in rm flags and in which paths they ran on, and
# gives slots 04 and 07 the prune they never had — which is where the disk
# actually went: 7 Go toolchains and 2 nvim trees, 1.6 GB of the 3.5 GB in
# APP_DIR.
#
# <keep>  the payload to preserve: the one this run installed or verified.
# <spare> one MORE payload to preserve, or "" for none. This is the deferred
#         delete. On the install path the caller passes the payload it just
#         superseded, because removing a runtime TREE in the same invocation
#         that replaced it is `rm -rf` on something a live process may still be
#         reading: POSIX keeps already-open files alive, so nothing fails at the
#         moment of deletion — it fails on the next lazy load, which is an
#         intermittent failure that will not reproduce under test. On the fast
#         path nothing was superseded, so the caller passes "" and the previous
#         payload goes then. That is a delete deferred by one run, not skipped.
#
#         Both paths prune. Fast-path-only would strand nothing but would
#         ACCUMULATE: a tool whose upstream moves faster than the installer runs
#         never reaches its fast path, which is how seven Go toolchains happened.
#
# <glob>  one or more patterns, relative to APP_DIR. Plural and explicit because
#         the payload names are NOT uniform and a single derived glob silently
#         matches nothing:
#           slot 04 is `go1.*`          — no tool prefix at all
#           slot 07 is `nvim-*` AND `nvim.appimage-*` — a superseded scheme
#           slot 16 is `ghostty-*.AppImage`
#         A helper that globbed "${bin_name}-*" would reclaim none of those.
#
# Best-effort by contract: it warns and returns 0 rather than failing, because a
# prune must never abort a fetcher whose install already succeeded.
fb_prune_versions() {
    local keep="$1" spare="$2"; shift 2
    local pat old n=0

    if [[ $# -eq 0 ]]; then
        echo "  warning: prune skipped, no glob given" >&2
        return 0
    fi

    # REFUSE on an absent keep target. This is the empty-string trap this tree
    # keeps paying for (iter 58's realpath -m, iter 62's version parse, iter 63's
    # own test asserts): with keep="" nothing compares equal to it, so the
    # CURRENT payload is deleted along with the old ones and the tool vanishes
    # from PATH. A cleanup helper must never be able to remove the thing it
    # exists to protect.
    if [[ -z "$keep" || ! -e "$keep" ]]; then
        echo "  warning: prune skipped, keep target missing: ${keep:-<empty>}" >&2
        return 0
    fi

    for pat in "$@"; do
        for old in "${APP_DIR}"/$pat; do
            # An unmatched glob stays literal, so -e is the guard, not nullglob
            # (which would be a global shell-option change inflicted on callers).
            [[ -e "$old" ]] || continue
            # -ef, not string equality: device+inode answers "same file" through
            # a symlink or a differently-spelled path. Iter 62's rule.
            [[ "$old" -ef "$keep" ]] && continue
            [[ -n "$spare" && -e "$spare" && "$old" -ef "$spare" ]] && continue
            rm -rf "$old"
            echo "  pruned old version: $(basename "$old")"
            n=$((n + 1))
        done
    done
    [[ $n -eq 0 ]] || echo "  reclaimed $n old payload(s) from ${APP_DIR}"
    return 0
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
    # jq_filter is a snippet like 'endswith(".tar.gz") and contains($arch)'.
    # $arch comes from $3 and $os from $4; both are always bound (empty when
    # not passed) so a filter may reference either without jq erroring.
    asset_url="$(printf '%s' "$json" | jq -r --arg arch "${3:-}" --arg os "${4:-}" '
        .assets[] | select(.name | '"$jq_filter"') | .browser_download_url
    ' | head -1)"

    if [[ -z "$asset_url" ]]; then
        echo "Error: no matching asset for filter '$jq_filter' (arch=${3:-} os=${4:-})." >&2
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
# Zip extraction WITHOUT a system 'unzip' (prime directive: a plain user
# with no sudo/root must still end up fully operational). broot and ninja
# ship their releases as .zip, and a minimal Debian install does NOT
# include 'unzip'. fb_unzip extracts with whichever no-root tool is present,
# in preference order, and EVERY path preserves unix permission bits — the
# python fallback restores them from the zip's stored attributes, which a
# bare `python3 -m zipfile -e` does NOT.
#
# Preserving the mode bits is load-bearing for any slot that symlinks a payload
# straight out of the extracted tree instead of handing it to install_bin, since
# install_bin's `chmod +x` is then never reached — every versioned-payload slot
# is in that position.
#
#   fb_unzip <zipfile> <destdir>
#
# Set FB_UNZIP_BACKEND=unzip|bsdtar|busybox|python3 to pin exactly one backend
# (the test harness uses this to prove each path in isolation, since the
# preference chain would otherwise always pick the first one present). A pinned
# backend that is absent is a hard error, never a silent fallthrough.
# ----------------------------------------------------------------------
_fb_have_busybox_unzip() {
    command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx unzip
}

# python zip extractor that RESTORES unix permission bits from the archive's
# external attributes (plain `python3 -m zipfile -e` discards them).
_fb_unzip_python() {
    python3 - "$1" "$2" <<'PY'
import sys, zipfile, os
src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        path = z.extract(info, dest)
        mode = (info.external_attr >> 16) & 0o7777
        if mode:
            os.chmod(path, mode)
PY
}

fb_unzip() {
    local zip="$1" dest="$2"
    mkdir -p "$dest"

    # Explicit pin (testing / override): use ONLY the named backend, fail loud
    # if it is absent rather than quietly falling through to another.
    case "${FB_UNZIP_BACKEND:-}" in
        unzip)   command -v unzip  >/dev/null 2>&1 || { echo "fb_unzip: pinned backend 'unzip' not found" >&2; return 1; };   unzip -oq "$zip" -d "$dest"; return ;;
        bsdtar)  command -v bsdtar >/dev/null 2>&1 || { echo "fb_unzip: pinned backend 'bsdtar' not found" >&2; return 1; };   bsdtar -x -f "$zip" -C "$dest"; return ;;
        busybox) _fb_have_busybox_unzip            || { echo "fb_unzip: pinned backend 'busybox unzip' not found" >&2; return 1; }; busybox unzip -oq "$zip" -d "$dest"; return ;;
        python3) command -v python3 >/dev/null 2>&1 || { echo "fb_unzip: pinned backend 'python3' not found" >&2; return 1; }; _fb_unzip_python "$zip" "$dest"; return ;;
        "")      ;;  # no pin — auto-select below
        *)       echo "fb_unzip: unknown FB_UNZIP_BACKEND '${FB_UNZIP_BACKEND}' (want unzip|bsdtar|busybox|python3)" >&2; return 1 ;;
    esac

    # Auto-select: most-compatible / perms-preserving first, python last.
    if command -v unzip >/dev/null 2>&1; then
        unzip -oq "$zip" -d "$dest"
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -x -f "$zip" -C "$dest"
    elif _fb_have_busybox_unzip; then
        busybox unzip -oq "$zip" -d "$dest"
    elif command -v python3 >/dev/null 2>&1; then
        _fb_unzip_python "$zip" "$dest"
    else
        echo "Error: no zip extractor available (need one of: unzip, bsdtar, busybox, python3)." >&2
        echo "       This tool ships as a .zip. Install any ONE of those — python3, or a" >&2
        echo "       user-local build of unzip/bsdtar, needs no root — then re-run." >&2
        return 1
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

    # A plain FILE where a symlink belongs.
    #
    # Everything install_bin manages is a symlink in BIN_DIR: install_bin places
    # the payload under APP_DIR and links to it. A regular file here was put
    # there by something else — a tool's own `--install`, or a fetcher
    # generation that predates the APP_DIR layout — and it used to pass this
    # check, because it is -e and is NOT -L, so neither symlink branch below
    # fired and the function fell through to `return 0`. install_bin then
    # printed "already valid (skipping)" on every run forever, so the tool could
    # never be updated and had no payload to update FROM.
    #
    # Measured 2026-09-05: broot was the only tool in this state, a 13 MB
    # regular file at ~/.local/bin/broot with no ~/.local/apps/broot behind it,
    # pinned at whatever version wrote it. Every other managed tool was already
    # a proper symlink, so this reinstalls exactly one thing rather than the
    # tree.
    #
    # Deliberately NOT removed here, unlike the broken-symlink branches below:
    # those delete because what they found is already unusable, whereas this
    # file still RUNS. Leaving it means a fetch that fails partway leaves the
    # user with a working tool; install_bin's `ln -sfn` replaces it atomically
    # once a verified payload exists.
    if [[ ! -L "$bin_path" && -f "$bin_path" ]]; then
        echo "→ $bin_name: unmanaged plain file at $bin_path (no versioned payload) — will reinstall"
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
# System-provided binary detection
#
#   fb_system_bin <name> [probe-argv...]
#     -> prints the path and returns 0 when a WORKING <name> exists on PATH
#        that this tree did not install; returns 1 otherwise.
#
# Answers "has this box already been provisioned with <name> by someone else?"
# — the question a fetcher asks before spending a download on a tool the distro,
# a vendor installer, or an admin already maintains.
#
# Two traps make a bare `command -v <name>` wrong here:
#
#   1. fb_init PREPENDS $BIN_DIR to PATH, so `command -v` finds OUR OWN symlink
#      first. A fetcher keying off that would conclude "already provided" on its
#      SECOND run and never update itself again — the bug is invisible on a
#      fresh box and permanent on every other one. $BIN_DIR is therefore removed
#      from PATH for the lookup, and anything whose symlink chain lands in
#      $APP_DIR is rejected as ours no matter which PATH entry found it.
#   2. Presence is not operability. This is the delta/`op` rule: `command -v`
#      proves a name resolves, not that the file runs. A binary for the wrong
#      arch, with a missing loader, or half-written by an interrupted install
#      must NOT suppress the fetch. The caller supplies the probe argv because
#      tools disagree about the flag — `tsh version` is a subcommand and
#      `tsh --version` is a hard error. Pass no probe to skip the run check.
# ----------------------------------------------------------------------
fb_system_bin() {
    local name="$1"; shift
    local probe=("$@")
    local search found resolved

    search=":${PATH}:"
    search="${search//:${BIN_DIR}:/:}"
    search="${search#:}"
    search="${search%:}"

    found="$(PATH="$search" command -v "$name" 2>/dev/null || true)"
    [[ -n "$found" && -x "$found" ]] || return 1
    [[ "$found" != "${BIN_DIR}/${name}" ]] || return 1

    resolved="$(readlink -f "$found" 2>/dev/null || printf '%s' "$found")"
    case "$resolved" in
        "${APP_DIR}"/*) return 1 ;;
    esac

    if [[ ${#probe[@]} -gt 0 ]]; then
        "$found" "${probe[@]}" >/dev/null 2>&1 || return 1
    fi

    printf '%s' "$found"
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

    # Missing PATH symlink, payload present: restore the link and stop.
    # In-place `cp` onto a running payload is ETXTBSY (measured 2026-08-29:
    # `op daemon` holds ~/.local/apps/op). Recreating the symlink is the
    # whole repair; replacing the inode would also strip setgid.
    if [[ -x "$final_src" ]] && { [[ ! -e "${BIN_DIR}/${bin_name}" ]] || [[ -L "${BIN_DIR}/${bin_name}" && ! -e "${BIN_DIR}/${bin_name}" ]]; }; then
        ln -sfn "$final_src" "${BIN_DIR}/${bin_name}"
        if [[ -x "${BIN_DIR}/${bin_name}" ]]; then
            echo "Installed ${bin_name} -> ${BIN_DIR}/${bin_name} (restored symlink onto existing payload)"
            return 0
        fi
    fi

    # A caller that already placed the binary at $final_src would otherwise make
    # this a self-copy; cp fails ("are the same file") and set -e kills the script
    # before the symlink below, leaving the runtime installed but nothing on PATH.
    #
    # Never cp onto $final_src in place: Linux refuses to write a running
    # executable (ETXTBSY). Stage beside it and `mv -f` — rename(2) unlinks the
    # old name; any process still running the previous inode keeps it.
    # `realpath -m` (resolve a path whose components need not exist) is a GNU
    # coreutils extension. BSD realpath rejects it outright, and the failure is
    # SILENT in the worst way: both sides of the comparison become the empty
    # string, "" != "" is false, the whole staging block is skipped, and the
    # very next line chmods a file that was never created. The guard failed
    # OPEN — measured on FreeBSD 15.1, where it took the chezmoi bootstrap down
    # with `chmod: .../chezmoi: No such file or directory`.
    #
    # bash's -ef compares device and inode, which is what "the same file"
    # actually means: it is stricter than comparing canonicalized strings
    # (hardlinks, bind mounts), needs no external binary, and is identical on
    # every platform. It requires both paths to exist, so test for the target
    # first — a missing target is trivially "not the same file".
    if [[ ! -e "$final_src" ]] || ! [[ "$src" -ef "$final_src" ]]; then
        local staging="${final_src}.new.$$"
        if cp -a "$src" "$staging" 2>/dev/null || cp "$src" "$staging"; then
            chmod +x "$staging"
            if ! mv -f "$staging" "$final_src"; then
                rm -f "$staging"
                echo "Error: could not replace $final_src" >&2
                exit 1
            fi
        else
            rm -f "$staging"
            echo "Error: could not stage $bin_name to $staging" >&2
            exit 1
        fi
    fi
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
        # Reuse the caller's verify argv instead of hardcoding --version: not
        # every tool has that flag (`tsh version` is a SUBCOMMAND, and
        # `tsh --version` is a usage error), and printing a usage error under
        # the label "version:" is worse than printing nothing. Callers that
        # passed no probe keep the historical default, so this is a no-op for
        # every existing fetcher.
        local version_args=(--version)
        [[ ${#verify_args[@]} -eq 0 ]] || version_args=("${verify_args[@]}")
        echo "  version: $("${BIN_DIR}/${bin_name}" "${version_args[@]}" 2>&1 | head -1)"
    fi
}

# ----------------------------------------------------------------------
# Shell completions (slots 18-21: fd, bat, delta, xh)
#
# Three of those four ship completion files INSIDE their release tarball; delta
# generates its own from the binary. Either way the files are a per-machine
# build artifact, not repo content: the fetchers run everywhere, so the files
# reproduce without being committed (and committing them would pin a version
# that may not match the binary actually installed).
#
#   fb_install_completions <tool> <zsh-src> <bash-src>
#
# Destinations are the XDG user dirs the rc layer knows about:
#   zsh   ${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions      (on $fpath)
#   bash  ${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions
# See doc/shell.md for how each is reached, and why $fpath must be extended
# BEFORE rc.sh's compinit.
#
# THE ZSH FILE IS ALWAYS INSTALLED AS `_<tool>`, whatever it is called in the
# tarball. zsh's $fpath autoloading keys on the leading-underscore convention,
# so bat's `autocomplete/bat.zsh` MUST land as `_bat` or it is never loaded —
# and that failure is SILENT: no error, no warning, just no completions. The
# rename lives here, once, rather than in four call sites that could each get
# it wrong. (fd/xh already ship `_fd`/`_xh`, so for them it is a no-op copy.)
#
# A missing/unreadable source is a warning, never fatal: a completion file that
# upstream drops from a future tarball must not take the binary install down
# with it. install_bin has already run by then.
# ----------------------------------------------------------------------
fb_completion_zsh_dir()  { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions"; }
fb_completion_bash_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"; }

fb_install_completions() {
    local tool="$1" zsrc="${2:-}" bsrc="${3:-}"
    local zdir bdir
    zdir="$(fb_completion_zsh_dir)"
    bdir="$(fb_completion_bash_dir)"

    if [[ -n "$zsrc" && -r "$zsrc" ]]; then
        mkdir -p "$zdir"
        # Autoload name, NOT the tarball's name. See the header note.
        cp "$zsrc" "${zdir}/_${tool}" && chmod 0644 "${zdir}/_${tool}"
        echo "  completions: zsh  -> ${zdir}/_${tool}"
    else
        echo "  warning: no zsh completion source for ${tool} (${zsrc:-unset})" >&2
    fi

    if [[ -n "$bsrc" && -r "$bsrc" ]]; then
        mkdir -p "$bdir"
        cp "$bsrc" "${bdir}/${tool}" && chmod 0644 "${bdir}/${tool}"
        echo "  completions: bash -> ${bdir}/${tool}"
    else
        echo "  warning: no bash completion source for ${tool} (${bsrc:-unset})" >&2
    fi
    return 0
}

# Teardown twin. Same lockstep rule as the binaries: a fetcher that installs a
# completion and is absent from the removal path strands the file forever (the
# tree-sitter bug, applied to a different artifact).
#
# SURGICAL, like the podman/ghostty config removals: these dirs are shared user
# directories that may hold completions from a distro package or another tool,
# so delete only OUR exact files and then rmdir upward. rmdir fails harmlessly
# on a non-empty dir, which preserves a foreign one.
fb_remove_completions() {
    local tool zdir bdir share
    zdir="$(fb_completion_zsh_dir)"
    bdir="$(fb_completion_bash_dir)"
    share="${XDG_DATA_HOME:-$HOME/.local/share}"
    for tool in "$@"; do
        rm -f "${zdir}/_${tool}" "${bdir}/${tool}"
    done
    rmdir "$zdir" "$bdir" 2>/dev/null || true
    rmdir "${share}/zsh" "${share}/bash-completion" 2>/dev/null || true
    echo "  removed completions for: $*"
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
# jq bootstrap — fetch jq FIRST and jq-free, so every other fetcher AND the
# chezmoi bootstrap below can rely on `jq` being on PATH. jq ships one static
# binary per os/arch under a predictable release-asset name (jq-linux-amd64), so
# locating it needs no JSON parsing: gh_latest_tag_nojq reads the tag with
# grep/awk and the URL is built by interpolation. This is the callable-from-
# checkout twin of 01_fetch.jq.sh (which now just calls it), the same pattern
# fetch_chezmoi/09_fetch.chezmoi.sh use. Requires fb_init (FB_TMP, BIN_DIR).
# ----------------------------------------------------------------------
fetch_jq() {
    local os arch tag url
    os="$(fb_os macos)"           # jq labels it "macos"/"linux"
    arch="$(fb_arch amd64)"       # amd64 | arm64
    tag="$(gh_latest_tag_nojq jqlang/jq)"
    url="https://github.com/jqlang/jq/releases/download/${tag}/jq-${os}-${arch}"
    gh_download "$url" "${FB_TMP}/jq"
    install_bin "${FB_TMP}/jq" jq --version
    echo "Installed jq $tag (static release binary, jq-free bootstrap) -> ${BIN_DIR}/jq"
}

# ----------------------------------------------------------------------
# chezmoi bootstrap — fetch the static release binary (chezmoi is pure Go, so
# the plain linux_<arch> asset is statically linked; no libc/musl variant
# needed). Same gh_* pattern as the other fetchers. Requires fb_init (FB_TMP).
# ----------------------------------------------------------------------
fetch_chezmoi() {
    local os arch tag ver url tarball
    os="$(fb_os darwin)"                          # linux | darwin | freebsd
    arch="$(fb_arch amd64)"                       # amd64 | arm64
    tag="$(gh_latest_tag twpayne/chezmoi)"
    ver="${tag#v}"
    # Matches e.g. chezmoi_2.72.0_linux_amd64.tar.gz or _freebsd_amd64.tar.gz.
    # The underscores around $os are load-bearing: upstream also ships
    # linux-glibc_ and linux-musl_ builds, and only the exact "_<os>_<arch>"
    # token excludes them (and the armv*/i386/loong64 variants).
    url="$(gh_asset_url twpayne/chezmoi 'endswith("_" + $os + "_" + $arch + ".tar.gz")' "$arch" "$os")"
    tarball="${FB_TMP}/chezmoi.tar.gz"
    gh_download "$url" "$tarball"
    tar -xzf "$tarball" -C "$FB_TMP" chezmoi 2>/dev/null || tar -xzf "$tarball" -C "$FB_TMP"
    install_bin "${FB_TMP}/chezmoi" chezmoi --version
    echo "Installed chezmoi $ver (static release binary) -> ${BIN_DIR}/chezmoi"
}

# ----------------------------------------------------------------------
# age bootstrap — fetch age (modern file encryption, github.com/FiloSottile/age).
# age is a BOOTSTRAP tool like chezmoi: `chezmoi apply` invokes `age` to decrypt
# the encrypted_ secrets (~/.keys), so the installer fetches it BEFORE the apply
# phase. The release tarball (age-vX.Y.Z-<os>-<arch>.tar.gz) unpacks to age/{age,
# age-keygen}; we install BOTH — age to decrypt/encrypt, age-keygen to mint the
# identity on a machine that is setting secrets up for the first time. Callable
# from the checkout (like fetch_jq/fetch_chezmoi). Requires fb_init (FB_TMP).
# ----------------------------------------------------------------------
fetch_age() {
    local os arch tag ver url tarball dir
    os="$(fb_os darwin)"          # age uses "linux"/"darwin"
    arch="$(fb_arch amd64)"       # amd64 | arm64
    tag="$(gh_latest_tag FiloSottile/age)"
    ver="${tag#v}"
    # Asset e.g. age-v1.2.1-linux-amd64.tar.gz -> extracts to age/{age,age-keygen}
    url="$(gh_asset_url FiloSottile/age 'contains("-'"$os"'-") and endswith("-" + $arch + ".tar.gz")' "$arch")"
    tarball="${FB_TMP}/age.tar.gz"
    gh_download "$url" "$tarball"
    tar -xzf "$tarball" -C "$FB_TMP"
    dir="${FB_TMP}/age"
    install_bin "${dir}/age" age --version
    install_bin "${dir}/age-keygen" age-keygen   # no --version verify: flag varies by release
    echo "Installed age $ver (age + age-keygen, static release) -> ${BIN_DIR}"
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
    # WSL keeps a LIVE-display check: WSLg provides a working display without ever
    # putting a compositor binary on PATH, so "is a compositor installed" is the
    # wrong question there and would skip GUI installs that work fine.
    if is_wsl && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
        echo "WSL without a display server, skipping GUI install" >&2
        exit 0
    fi
    # Everywhere else on Linux: INSTALLED-COMPOSITOR PRESENCE, the same signal
    # home/.chezmoiignore uses to gate desktop config.
    #
    # The old test was `XDG_SESSION_TYPE = tty`. Over ssh that variable is typically
    # UNSET rather than "tty", so on a genuinely headless box this gate PASSED and a
    # GUI app was installed anyway — while .chezmoiignore called the very same box
    # headless. Two predicates disagreeing about one question is how the standing
    # "doctor disagrees with itself" thread started; this makes it one question.
    #
    # Scoped to Linux deliberately: macOS ships no Hyprland, sway or Xorg binary and
    # is never headless in the sense that matters here, so an unscoped check would
    # stop installing GUI tools on every Mac.
    if df_is_linux && ! is_wsl; then
        if ! command -v Hyprland >/dev/null 2>&1 \
            && ! command -v sway >/dev/null 2>&1 \
            && ! command -v Xorg >/dev/null 2>&1; then
            echo "No compositor installed (headless), skipping GUI install" >&2
            exit 0
        fi
    fi
}

# ----------------------------------------------------------------------
# End of library. All functions assume set -euo pipefail.
# See Context.fetch.bins.refactor.md for full design, verified facts,
# and per-tool differences (jq bootstrap, nvim tarball, Zed gating, etc.).
# ----------------------------------------------------------------------
echo "Loaded fetch.bins/_lib.sh (with stow safety guard)" >&2
