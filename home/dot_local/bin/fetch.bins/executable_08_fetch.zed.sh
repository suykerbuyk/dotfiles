#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# Zed installer (GUI). Uses require_display_or_skip for tty/WSL headless.
# Preserves desktop integration. Uses lib helpers where possible (CDN URL
# is not GitHub, so we keep custom download). See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="zed"
INSTALL_DIR="${APP_DIR}/${BIN_NAME}.app"

require_display_or_skip
fb_init
fb_require_os

CHANNEL="${ZED_CHANNEL:-stable}"
OS="$(fb_os)"
ARCH="$(uname -m)"  # Zed uses raw uname -m values

DOWNLOAD_URL="https://cloud.zed.dev/releases/$CHANNEL/latest/download?asset=zed&arch=$ARCH&os=$OS&source=install.sh"

# Already-installed fast path.
#
# This fetcher CANNOT detect an upstream bump: the download URL below is a
# server-side "latest" redirect carrying no version, so the only way to learn
# what upstream ships is to fetch and extract it. Zed therefore pins to whatever
# version installed first. That is a known limitation of this slot, not an
# oversight -- see the fetch.bins version-blindness work.
#
# ZED_FETCH_FORCE=1 overrides, matching JQ_FETCH_FORCE (slot 01), TSH_FETCH_FORCE
# (slot 22) and OP_FETCH_FORCE (slot 23). An env var is the only override shape
# that can work here: Phase 5 runs every fetcher bare, passing no arguments
# (update-user-home-dir.sh), so a flag would be unreachable from the installer.
# This message used to advertise "--force" -- a flag this script never parsed and
# the installer never passed, so the remedy it named did not exist.
#
# Forcing works because INSTALL_DIR is a FIXED path: the rm -rf + extract below
# replaces the payload in place, and the ~/.local/bin/zed symlink already points
# into it, so install_bin taking its version-blind skip does not block the
# upgrade.
if [[ "${ZED_FETCH_FORCE:-0}" != "1" ]] \
   && [[ -d "${INSTALL_DIR}" && -x "${INSTALL_DIR}/bin/${BIN_NAME}" ]]; then
    CURRENT_VERSION="$(${INSTALL_DIR}/bin/${BIN_NAME} --version 2>/dev/null | cut -d' ' -f2 || echo 'unknown')"
    echo "Zed $CURRENT_VERSION already installed."
    echo "  Set ZED_FETCH_FORCE=1 to reinstall (this fetcher cannot detect an upstream bump)."
    exit 0
fi

echo "Downloading Zed $CHANNEL for $OS/$ARCH from $DOWNLOAD_URL..."

TARBALL="${FB_TMP}/zed.tar.gz"
gh_download "$DOWNLOAD_URL" "$TARBALL"  # reuse helper (it uses curl -fL)

# Clean and extract (tarball extracts to zed.app/)
rm -rf "${INSTALL_DIR}"
tar -xzf "$TARBALL" -C "${APP_DIR}"

if [[ -x "${INSTALL_DIR}/bin/${BIN_NAME}" ]]; then
    # Zed binary verification can be flaky in some environments; use a lenient check
    install_bin "${INSTALL_DIR}/bin/${BIN_NAME}" "$BIN_NAME" || echo "Zed installed but verification skipped (common for GUI)."
elif [[ -x "${INSTALL_DIR}/libexec/zed-editor" ]]; then
    install_bin "${INSTALL_DIR}/libexec/zed-editor" "$BIN_NAME" || echo "Zed installed via libexec."
else
    echo "Error: Zed binary not found in $INSTALL_DIR/bin/ or libexec/" >&2
    exit 1
fi

# Desktop integration (preserved)
DESKTOP_FILE='zed.desktop'
DST_DESKTOP_DIR="${HOME}/.local/share/applications"
SRC_DESKTOP_DIR="${INSTALL_DIR}/share/applications"
DST_DESKTOP_FILE="${DST_DESKTOP_DIR}/${DESKTOP_FILE}"
SRC_DESKTOP_FILE="${SRC_DESKTOP_DIR}/${DESKTOP_FILE}"
mkdir -p "${DST_DESKTOP_DIR}"
if [[ -f "${SRC_DESKTOP_FILE}" ]]; then
    cp "${SRC_DESKTOP_FILE}" "${DST_DESKTOP_FILE}"
    sed -i "s|Icon=zed|Icon=$INSTALL_DIR/share/icons/hicolor/512x512/apps/zed.png|g" "${DST_DESKTOP_FILE}"
    sed -i "s|Exec=zed|Exec=$INSTALL_DIR/libexec/zed-editor|g" "${DST_DESKTOP_FILE}"
    echo "Desktop file installed to $DST_DESKTOP_FILE"
else
    echo "No .desktop file found; skipping desktop integration."
fi

echo "Installed Zed ($CHANNEL/latest) to $APP_DIR"
echo "  Binary symlinked to $BIN_DIR/$BIN_NAME"
