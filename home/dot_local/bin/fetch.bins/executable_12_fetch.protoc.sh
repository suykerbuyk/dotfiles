#!/usr/bin/env bash
set -euo pipefail

# protoc (Protocol Buffers compiler) installer. The release asset is a .zip that
# bundles BOTH bin/protoc AND include/google/protobuf/*.proto (the "well-known"
# types). protoc resolves those imports relative to its own real binary path
# (../include, via /proc/self/exe), so — exactly like Go's GOROOT — we must NOT
# copy the bare binary out with install_bin. Instead we extract the whole tree
# into a versioned dir under ~/.local/apps and symlink ~/.local/bin/protoc
# straight at bin/protoc, so '../include' still resolves. Uses lib for the safety
# guard, temp discipline, and gh_download. See home/doc/fetch-bins.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="protoc"
fb_init

# protoc needs 'unzip' (its release asset is a .zip, unlike the tarball tools).
if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: 'unzip' is required to install protoc (its release is a .zip)." >&2
    echo "       Install it (e.g. 'sudo apt install unzip' or 'sudo pacman -S unzip') and re-run." >&2
    exit 1
fi

# protoc's asset arch tokens differ from uname: x86_64 stays, aarch64 -> aarch_64.
# macOS uses the 'osx-<arch>' prefix. The asset version omits the tag's leading 'v'.
OS="$(fb_os osx)"          # linux | osx  (darwin -> osx)
ARCH="$(uname -m)"
case "${OS}:${ARCH}" in
    linux:x86_64)               PLAT="linux-x86_64" ;;
    linux:aarch64|linux:arm64)  PLAT="linux-aarch_64" ;;
    osx:x86_64)                 PLAT="osx-x86_64" ;;
    osx:aarch64|osx:arm64)      PLAT="osx-aarch_64" ;;
    *) echo "Error: unsupported platform '${OS}/${ARCH}' for protoc." >&2; exit 1 ;;
esac

TAG_NAME="$(gh_latest_tag protocolbuffers/protobuf)"
VERSION="${TAG_NAME#v}"
ASSET="protoc-${VERSION}-${PLAT}.zip"

VERSION_DIR="${APP_DIR}/protoc-${VERSION}"
PROTOC_BIN="${VERSION_DIR}/bin/protoc"

# Fast path: this exact version is already extracted and runnable. Re-assert the
# symlink (self-healing, version-agnostic) and exit.
if [[ -x "$PROTOC_BIN" ]] && "$PROTOC_BIN" --version >/dev/null 2>&1; then
    echo "protoc $VERSION already installed; symlink ensured -> $PROTOC_BIN"
    ln -sfn "$PROTOC_BIN" "${BIN_DIR}/${BIN_NAME}"
    exit 0
fi

# Exact asset-name match (names carry the version + a non-uname arch token).
ASSET_URL="$(gh_asset_url protocolbuffers/protobuf '. == $arch' "$ASSET")"

ZIP="${FB_TMP}/protoc.zip"
gh_download "$ASSET_URL" "$ZIP"

# Extract the whole tree (bin/ + include/) into the versioned dir. Clear any
# partial/old extraction of this exact version first.
rm -rf "$VERSION_DIR"
mkdir -p "$VERSION_DIR"
unzip -oq "$ZIP" -d "$VERSION_DIR"   # yields bin/protoc, include/…, readme.txt

# Verify in place (include/ sits next to bin/) before linking.
if ! "$PROTOC_BIN" --version >/dev/null 2>&1; then
    echo "Error: extracted protoc is not runnable at $PROTOC_BIN" >&2
    exit 1
fi

ln -sfn "$PROTOC_BIN" "${BIN_DIR}/${BIN_NAME}"

echo "Installed protoc $VERSION (release zip, with well-known includes) to $VERSION_DIR"
echo "  version: $("$PROTOC_BIN" --version)"
echo "  symlink: ${BIN_DIR}/${BIN_NAME} -> $PROTOC_BIN"
