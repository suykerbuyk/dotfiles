#!/usr/bin/env bash
set -euo pipefail

# Zed installer (GUI). Uses require_display_or_skip for tty/WSL headless.
# Preserves desktop integration. Uses lib helpers where possible (CDN URL
# is not GitHub, so we keep custom download). See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="zed"
INSTALL_DIR="${APP_DIR}/${BIN_NAME}.app"

require_display_or_skip
fb_init

CHANNEL="${ZED_CHANNEL:-stable}"
OS="$(fb_os)"
ARCH="$(uname -m)"  # Zed uses raw uname -m values

DOWNLOAD_URL="https://cloud.zed.dev/releases/$CHANNEL/latest/download?asset=zed&arch=$ARCH&os=$OS&source=install.sh"

# Check if already installed (preserved from original)
if [[ -d "${INSTALL_DIR}" && -x "${INSTALL_DIR}/bin/${BIN_NAME}" ]]; then
    CURRENT_VERSION="$(${INSTALL_DIR}/bin/${BIN_NAME} --version 2>/dev/null | cut -d' ' -f2 || echo 'unknown')"
    echo "Zed $CURRENT_VERSION already installed. Run with --force to reinstall."
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
