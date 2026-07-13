#!/usr/bin/env bash
set -euo pipefail

# Go installer (uses official go.dev JSON, not GitHub). Uses lib for safety,
# temp discipline, and install_bin. Preserves version check.
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="go"
fb_init

OS="$(fb_os linux)"  # go uses "linux", not "linux" change but consistent
ARCH="$(fb_arch amd64)"

JSON_URL="https://go.dev/dl/?mode=json"
VERSION="$(curl -fsSL "$JSON_URL" | jq -r '.[] | select(.stable == true) | .version' | sort -V | tail -1)"

if [[ -z "$VERSION" ]]; then
    echo "Error: could not determine latest stable Go version." >&2
    exit 1
fi

ASSET_URL="https://go.dev/dl/${VERSION}.${OS}-${ARCH}.tar.gz"
VERSION_DIR="${APP_DIR}/${VERSION}"

# The Go tarball has a top-level go/ dir; --strip-components=1 removes it, so the
# binaries land at $VERSION_DIR/bin/{go,gofmt}. Symlink to THAT path.
#
# Root-cause fix: the prior code installed from $VERSION_DIR/go/bin/go — the
# NON-stripped path, which never exists after --strip-components=1 — producing a
# broken symlink that was then band-aided with hardcoded version strings
# (go1.25 / go1.26.5). Both the wrong path and the version hardcoding are gone.
#
# Go is also NOT run through install_bin: install_bin copies the binary into
# APP_DIR, which would detach `go` from its GOROOT ($VERSION_DIR) and break the
# stdlib. We verify in place and symlink directly so GOROOT resolves correctly.
GO_BIN="${VERSION_DIR}/bin/go"
GOFMT_BIN="${VERSION_DIR}/bin/gofmt"

link_go() {
    ln -sfn "$GO_BIN" "${BIN_DIR}/go"
    ln -sfn "$GOFMT_BIN" "${BIN_DIR}/gofmt"
}

# Fast path: this exact version is already extracted and runnable. Re-assert the
# symlinks (self-healing, version-agnostic) and exit.
if [[ -x "$GO_BIN" ]] && "$GO_BIN" version >/dev/null 2>&1; then
    echo "Go $VERSION already installed; symlinks ensured -> $GO_BIN"
    link_go
    exit 0
fi

# Remove any partial/old extraction of this version dir before re-extracting.
rm -rf "$VERSION_DIR"

TARBALL="${FB_TMP}/go.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"  # reuses helper (works for any URL)

mkdir -p "$VERSION_DIR"
tar -C "$VERSION_DIR" -xzf "$TARBALL" --strip-components=1

# Verify in place (GOROOT = $VERSION_DIR) before linking.
if ! "$GO_BIN" version >/dev/null 2>&1; then
    echo "Error: extracted go is not runnable at $GO_BIN" >&2
    exit 1
fi
link_go

echo "Installed Go $VERSION (official tarball) to $VERSION_DIR"
echo "  version: $("$GO_BIN" version)"
