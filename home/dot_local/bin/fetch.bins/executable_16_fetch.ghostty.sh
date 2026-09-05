#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# Ghostty installer (GUI terminal emulator) — the ONLY AppImage in fetch.bins/.
#
# PROVENANCE CAVEAT: every other fetcher here pulls the upstream project's own
# release assets. This one does not. The Ghostty project ships prebuilt binaries
# for macOS ONLY; on Linux it defers to distro maintainers and community
# builders (https://ghostty.org/docs/install/binary), which lists
# pkgforge-dev/ghostty-appimage under "Community-Maintained Binaries" with an
# explicit warning that community builds "carry a much higher risk compared to
# builds directly from the Ghostty project or from distro maintainers". Where a
# first-party distro package exists (Arch ships extra/ghostty), prefer it.
#
# Why this does NOT use install_bin: install_bin hardcodes its destination to
# ${APP_DIR}/${BIN_NAME}, which cannot carry a version. The versioned path is
# what makes the fast path below possible, and the fast path is not an
# optimization — Phase 5 of the installer runs on EVERY invocation and the
# asset is ~48 MB. (The nvim fetcher bypasses install_bin too, for a different
# reason: its copy step detaches the binary from its runtime tree.)
#
# The AppImage runtime is uruntime (VHSgunzo/uruntime, SquashFS + DwarFS), which
# provides --appimage-extract [PATTERN] and --appimage-extract-and-run. Both are
# load-bearing here: pattern extraction pulls the terminfo/desktop/icon payload
# for ~4 KB instead of unpacking the full 153 MB tree, and extract-and-run is
# the no-FUSE fallback that keeps the repo's no-root guarantee intact.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="ghostty"
REPO="pkgforge-dev/ghostty-appimage"
APP_ID="com.mitchellh.ghostty"

require_display_or_skip   # GUI: skip on tty-only and display-less WSL
fb_init
fb_require_os

# Asset arch tokens are raw `uname -m` (x86_64 / aarch64), NOT fb_arch's
# amd64/arm64 mapping. Fail loud on anything else rather than 404 on download.
case "$(uname -m)" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    *) echo "Error: unsupported architecture '$(uname -m)' for ghostty-appimage." >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# FUSE detection. The AppImage mounts itself with FUSE by default; without it,
# uruntime still runs via APPIMAGE_EXTRACT_AND_RUN=1 (self-extract to a temp
# dir first — correct, just slower to start). Detect once and thread the answer
# through both the verification call and the generated .desktop Exec line.
# ---------------------------------------------------------------------------
GHOSTTY_ENV_PREFIX=""
if [[ -e /dev/fuse ]] && { command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1; }; then
    HAVE_FUSE=1
else
    HAVE_FUSE=0
    GHOSTTY_ENV_PREFIX="env APPIMAGE_EXTRACT_AND_RUN=1 "
    export APPIMAGE_EXTRACT_AND_RUN=1
    echo "→ ghostty: no FUSE (/dev/fuse + fusermount) — falling back to extract-and-run."
    echo "  The AppImage still works; it self-extracts on each launch, so startup is slower."
fi

# ---------------------------------------------------------------------------
# Payload installers. Both are re-run on the fast path so a half-installed or
# hand-deleted desktop entry / terminfo entry self-heals without a re-download.
#
# Extraction lands under AppDir/ for a pattern extract; a full extract also
# leaves a `squashfs-root -> ./AppDir` symlink. Resolve both names.
# ---------------------------------------------------------------------------
ghostty_extract() {
    # ghostty_extract <appimage> <pattern> ; echoes the extraction root
    local img="$1" pattern="$2" root
    root="$(mktemp -d "${FB_TMP}/xtract.XXXXXX")"
    ( cd "$root" && "$img" --appimage-extract "$pattern" >/dev/null 2>&1 ) || return 1
    if   [[ -d "$root/AppDir" ]];        then printf '%s' "$root/AppDir"
    elif [[ -d "$root/squashfs-root" ]]; then printf '%s' "$root/squashfs-root"
    else return 1
    fi
}

# Ghostty sets TERM=xterm-ghostty. The compiled entry ships INSIDE the AppImage,
# so without this step nothing outside the AppImage's own environment can
# resolve it — that is the well-known "ghostty breaks over ssh" failure. Install
# by plain file copy: `tic` is an ncurses extra that a minimal no-root box may
# not have, and the bundled file is already a compiled terminfo entry.
install_terminfo() {
    local img="$1" root src dst="${HOME}/.terminfo/x/xterm-ghostty"
    if ! root="$(ghostty_extract "$img" 'share/terminfo/x/xterm-ghostty')"; then
        echo "  warning: could not extract xterm-ghostty terminfo from the AppImage." >&2
        echo "           TERM=xterm-ghostty will not resolve outside ghostty itself." >&2
        return 0
    fi
    src="${root}/share/terminfo/x/xterm-ghostty"
    [[ -f "$src" ]] || { echo "  warning: terminfo entry missing from extract." >&2; return 0; }
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    echo "  terminfo: installed xterm-ghostty -> $dst"
}

# The shipped .desktop is CI-poisoned: Exec/TryExec point at the GitHub Actions
# build path (/__w/ghostty-appimage/...), which exists on no user's machine.
# Rewrite Exec, TryExec and Icon, exactly as the zed fetcher does.
install_desktop() {
    local img="$1" root src icon_src
    local apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
    local dst="${apps_dir}/${APP_ID}.desktop"
    local icon_dst="${icon_dir}/${APP_ID}.png"

    if ! root="$(ghostty_extract "$img" "*${APP_ID}*")"; then
        echo "  warning: could not extract desktop entry — skipping desktop integration." >&2
        return 0
    fi

    src="${root}/${APP_ID}.desktop"
    [[ -f "$src" ]] || src="${root}/share/applications/${APP_ID}.desktop"
    [[ -f "$src" ]] || { echo "  warning: no .desktop found in the AppImage." >&2; return 0; }

    icon_src="${root}/share/icons/hicolor/512x512/apps/${APP_ID}.png"
    [[ -f "$icon_src" ]] || icon_src="${root}/${APP_ID}.png"
    if [[ -f "$icon_src" ]]; then
        mkdir -p "$icon_dir"
        cp -f "$icon_src" "$icon_dst"
    else
        echo "  warning: no icon found in the AppImage; the entry will use a themed name." >&2
    fi

    mkdir -p "$apps_dir"
    # Rewrite the whole Exec/TryExec lines (not a substring swap): the CI path is
    # absolute and arbitrary, so only a full-line replacement is safe. Keep the
    # --gtk-single-instance=true argument the upstream entry ships with. The
    # Exec rule deliberately has no `1` address so it also rewrites the
    # [Desktop Action new-window] Exec, which carries the same poisoned path.
    #
    # DBusActivatable is forced OFF: the entry ships it as true, but the AppImage
    # bundles NO D-Bus .service file (share/dbus-1 has none), so the activation
    # name com.mitchellh.ghostty can never be served from a user-local install.
    # Left true, a launcher may try D-Bus activation, fail, and never fall back
    # to Exec — a desktop icon that silently does nothing. False makes the Exec
    # line we just repointed authoritative.
    sed -e "s|^TryExec=.*|TryExec=${BIN_DIR}/${BIN_NAME}|" \
        -e "s|^Exec=[^ ]*ghostty|Exec=${GHOSTTY_ENV_PREFIX}${BIN_DIR}/${BIN_NAME}|" \
        -e "s|^DBusActivatable=.*|DBusActivatable=false|" \
        "$src" > "$dst"
    if [[ -f "$icon_dst" ]]; then
        sed -i "s|^Icon=.*|Icon=${icon_dst}|" "$dst"
    fi
    echo "  desktop: installed $dst"
}

link_ghostty() {
    ln -sfn "$1" "${BIN_DIR}/${BIN_NAME}"
    echo "  symlink: ${BIN_DIR}/${BIN_NAME} -> $1"
}

# Retire older versions so ~/.local/apps does not accumulate ~48 MB per release.
# The symlink points at $keep, so anything else is dead weight. Called from BOTH
# the fast path and the install path: the normal upgrade run prunes as a side
# effect of installing, but a run interrupted between download and prune would
# otherwise strand the old image forever, since every later run takes the fast
# path and never reaches this.

# ---------------------------------------------------------------------------
# Resolve the latest release and its asset.
# Assets are Ghostty-<version>-<arch>.AppImage; each has a .zsync twin that the
# exact-name match below excludes.
# ---------------------------------------------------------------------------
TAG_NAME="$(gh_latest_tag "$REPO")"
VERSION="${TAG_NAME#v}"
APPIMAGE="${APP_DIR}/${BIN_NAME}-${VERSION}.AppImage"

# Fast path: this exact version is already installed and runnable. Re-assert the
# symlink and re-install the desktop/terminfo payloads (cheap, and self-heals a
# hand-deleted entry), then exit WITHOUT re-downloading ~48 MB.
if [[ -x "$APPIMAGE" ]] && "$APPIMAGE" --version >/dev/null 2>&1; then
    echo "ghostty $VERSION already installed; symlink + payloads ensured."
    link_ghostty "$APPIMAGE"
    fb_prune_versions "$APPIMAGE" "" 'ghostty-*.AppImage' 
    install_terminfo "$APPIMAGE"
    install_desktop "$APPIMAGE"
    exit 0
fi

# gh_asset_url binds its 3rd argument to jq's $arch — that is the ONLY jq
# variable it defines — so the version is interpolated shell-side and the arch
# rides the jq arg (the age fetcher's shape).
ASSET_URL="$(gh_asset_url "$REPO" \
    '. == ("Ghostty-'"$VERSION"'-" + $arch + ".AppImage")' "$ARCH")"

GHOSTTY_PREV="$(fb_prev_payload "$BIN_NAME")"

echo "→ Downloading ghostty $VERSION ($ARCH AppImage, ~48 MB)..."
# Downloaded straight into a staging path BESIDE the payload, not into FB_TMP.
# FB_TMP is tmpfs and APP_DIR is not, so the old `mv -f` out of FB_TMP was
# copy-then-unlink rather than rename(2) — a publish that could be interrupted
# half-written. fb_publish_payload refuses a stage that is not beside its
# destination, so this cannot silently regress.
TMP_IMG="$(fb_stage_payload "$APPIMAGE")"
trap 'rm -f "$TMP_IMG"; rm -rf "$FB_TMP"' EXIT
gh_download "$ASSET_URL" "$TMP_IMG"
chmod +x "$TMP_IMG"

# Verification gate BEFORE anything is placed on PATH (install_bin's contract,
# reproduced here because we bypass it for the versioned destination).
if ! "$TMP_IMG" --version >/dev/null 2>&1; then
    echo "Error: the downloaded ghostty AppImage is not runnable (verification failed)." >&2
    if [[ "$HAVE_FUSE" == 1 ]]; then
        echo "       Retrying once without FUSE to rule out a mount failure..." >&2
        if APPIMAGE_EXTRACT_AND_RUN=1 "$TMP_IMG" --version >/dev/null 2>&1; then
            echo "       It runs with APPIMAGE_EXTRACT_AND_RUN=1 — your FUSE setup is broken." >&2
            echo "       Re-run with APPIMAGE_EXTRACT_AND_RUN=1 exported to install anyway." >&2
        fi
    fi
    exit 1
fi

# Place the verified image at its versioned path, then link.
fb_publish_payload "$TMP_IMG" "$APPIMAGE"
trap 'rm -rf "$FB_TMP"' EXIT
chmod +x "$APPIMAGE"
link_ghostty "$APPIMAGE"

fb_prune_versions "$APPIMAGE" "$GHOSTTY_PREV" 'ghostty-*.AppImage'
install_terminfo "$APPIMAGE"
install_desktop "$APPIMAGE"

echo "Installed ghostty ${VERSION} (community AppImage, ${ARCH}) -> ${BIN_DIR}/${BIN_NAME}"
echo "  version: $("${BIN_DIR}/${BIN_NAME}" --version 2>&1 | head -1)"
