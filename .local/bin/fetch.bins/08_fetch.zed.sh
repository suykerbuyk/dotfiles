#!/usr/bin/env bash
set -euo pipefail

if [ "${XDG_SESSION_TYPE}" == "tty" ] ; then
	echo "Did not detect a windowing session, skipping Zed install"
	exit
fi

PREFIX_DIR="${HOME}/.local"
APP_DIR="${PREFIX_DIR}/apps"
BIN_DIR="${PREFIX_DIR}/bin"
BIN_NAME="zed"
INSTALL_DIR="${APP_DIR}/${BIN_NAME}.app"

CHANNEL="${ZED_CHANNEL:-stable}" # Allow env override, default stable
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)" # e.g., x86_64, aarch64; adjust if needed
# Construct download URL (mimics install.sh)
DOWNLOAD_URL="https://cloud.zed.dev/releases/$CHANNEL/latest/download?asset=zed&arch=$ARCH&os=$OS&source=install.sh"

# Ensure dirs exists or create.
TEMP_DIR="$(mktemp -d)"
[ ! -d "${APP_DIR}" ] && mkdir -p "${APP_DIR}"
[ ! -d "${BIN_DIR}" ] && mkdir -p "${BIN_DIR}"
[ ! -d "${INSTALL_DIR}" ] && mkdir -p "${INSTALL_DIR}"
# Check if already installed
if [[ -d "${INSTALL_DIR}" && -x "${INSTALL_DIR}/bin/${BIN_NAME}" ]]; then
    CURRENT_VERSION="$(${INSTALL_DIR}/bin/${BIN_NAME} --version 2>/dev/null | cut -d' ' -f2 || echo 'unknown')"
    echo "Zed $CURRENT_VERSION already installed at $APP_DIR. Run with --force to reinstall."
    exit 0
fi

echo "Downloading Zed $CHANNEL for $OS/$ARCH from $DOWNLOAD_URL..."
# Download tar.gz
TARBALL="$TEMP_DIR/zed.tar.gz"
curl -s -L -f -o "$TARBALL" "$DOWNLOAD_URL"

# Clean up existing install
rm -rf "${INSTALL_DIR}/*"

# Extract.  The tarball extracts to a zed.app directory.
tar -xzf "$TARBALL" -C "${APP_DIR}"

# Symlink binary (zed or fallback to cli if needed, but per docs it's zed)
if [[ -x "${INSTALL_DIR}/bin/${BIN_NAME}" ]]; then
    ln -sf "${INSTALL_DIR}/bin/${BIN_NAME}" "${BIN_DIR}/${BIN_NAME}"
else
    echo "Warning: $BIN_NAME binary not found in $INSTALL_DIR/bin/" >&2
    exit 1
fi

# Optional: Desktop integration (XDG)
DESKTOP_FILE='zed.desktop'
DST_DESKTOP_DIR="${PREFIX_DIR}/share/applications"
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

# Clean up
rm -rf "$TEMP_DIR"

echo "Installed Zed ($CHANNEL/latest) to $APP_DIR"
echo "Binary symlinked to $BIN_DIR/$BIN_NAME"
echo "Add $BIN_DIR to your \$PATH if not already (e.g., in ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\")"
