#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# Go installer (uses official go.dev JSON, not GitHub). Uses lib for safety,
# temp discipline, and install_bin. Preserves version check.
# See Context.fetch.bins.refactor.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="go"
fb_init
fb_require_os

OS="$(fb_os linux)"  # go uses "linux", not "linux" change but consistent
ARCH="$(fb_arch amd64)"

JSON_URL="https://go.dev/dl/?mode=json"

# FB_PIN_GO short-circuits the upstream lookup entirely — no request, no parse.
# NOTE the value shape: go.dev reports versions WITH the prefix ("go1.26.5"), and
# that string is interpolated straight into both the URL and the payload path, so
# the pin is FB_PIN_GO=go1.26.5, not 1.26.5.
#
# The `||` is load-bearing under `set -e`: fb_pin returns 1 when unset, and a bare
# `VERSION="$(fb_pin go)"` would abort the script on that status rather than fall
# through to the lookup.
VERSION="$(fb_pin go)" || \
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
    # Nothing was superseded on this path, so the previous payload is cold: it
    # has survived at least one whole run since it stopped being current. This is
    # where the deferred delete from the install path is actually collected.
    #
    # The glob is `go1.*`, NOT `go-*`: slot 04 alone names its payload with no
    # tool prefix, because go.dev's version string already starts with "go".
    fb_prune_versions "$VERSION_DIR" "" 'go1.*'
    exit 0
fi

# The payload the PATH symlink currently resolves to — captured BEFORE relinking,
# because that is the tree this run is about to supersede. fb_prune_versions
# spares it for exactly one run: deleting a live GOROOT in the same invocation
# that replaced it is `rm -rf` on files a running process may still lazily load,
# and POSIX keeps already-open files alive so nothing fails at the moment of
# deletion — it fails later, intermittently, and not under test.
GO_PREV_DIR=""
_prev_bin="$(readlink -f "${BIN_DIR}/go" 2>/dev/null || true)"
# The -x test is NOT redundant with the case match. GNU `readlink -f` resolves a
# path whose final component does not exist and prints it anyway, so on a machine
# with no prior install this yielded "$HOME/.local/bin/go", matched the pattern,
# and left PREV_DIR = "$HOME/.local" — a variable whose name claims "the previous
# payload" while holding the parent of BIN_DIR. Harmless as a SPARE, since a
# spare is only ever compared and never deleted, but false, and one refactor away
# from being passed somewhere that does delete. BSD readlink differs again on a
# missing path, so the guard is what makes both platforms agree.
if [[ -n "$_prev_bin" && -x "$_prev_bin" ]]; then
    case "$_prev_bin" in
        */bin/go) GO_PREV_DIR="${_prev_bin%/bin/go}" ;;
    esac
fi
unset _prev_bin

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
fb_prune_versions "$VERSION_DIR" "$GO_PREV_DIR" 'go1.*'

echo "Installed Go $VERSION (official tarball) to $VERSION_DIR"
echo "  version: $("$GO_BIN" version)"
