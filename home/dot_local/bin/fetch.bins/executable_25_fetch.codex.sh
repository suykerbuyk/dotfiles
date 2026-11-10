#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# codex installer (OpenAI Codex CLI). codex 0.167 expects to run from its upstream
# PACKAGE ROOT, not from a lone binary, so this is a DIRECTORY payload (the slot 07
# nvim idiom, not slot 13 starship's single file). The release asset is
# `codex-package-<triple>.tar.gz` (~200 MB, ~600 MB extracted) and it has NO
# top-level directory: bin/{codex,codex-code-mode-host,codex-exec-server},
# codex-package.json, codex-path/rg and codex-resources/{bwrap,voice/...} are the
# archive roots. It is published as ~/.local/apps/codex-<ver>/ and
# ~/.local/bin/codex links to codex-<ver>/bin/codex.
#
# WHY. The flat `codex-<triple>` binary this slot used to install makes codex exit
# with "this CLI has no complete local package; install a packaged Codex CLI or use
# the standalone installer" (its app-server daemon provisions itself by copying the
# package root). Observed (not an established algorithm): package discovery follows
# the resolved executable path, directly and through a symlink; `codex doctor`
# reports a package for a package root and none for a lone file. The old
# hand-placed codex-code-mode-host sibling was the first symptom of the same gap;
# it now ships inside bin/ and is migrated away below.
#
# Two deviations from the usual slot, both measured (2026-11-09):
#
# 1. THE TAG IS `rust-v<version>`, NOT `v<version>`. openai/codex publishes
#    many products from one repo (codex, codex-app-server, codex-exec, bwrap,
#    argument-comment-lint ...) and tags the CLI release `rust-v0.167.0`. So the
#    strip is `${TAG_NAME#rust-v}` and the pinned path rebuilds `rust-v${VERSION}`
#    -- NOT the `v${VERSION}` / `${TAG_NAME#v}` idiom the other slots share.
#
# 2. EXACT-NAME asset match, not `startswith`/`contains`. The release is full of
#    siblings (codex-<triple>, codex-app-server-*, codex-app-server-package-*,
#    codex-npm-*, bwrap-* ...) and of `.zst` + `.sigstore` twins beside every
#    tarball. `. == ("codex-package-" + $arch + ".tar.gz")` selects ONLY ours.
#
# NOT install_versioned_bin / fb_versioned_current: both hard-require a single
# regular file and reject a directory. Hence the own fast path below, whose test
# (codex_pkg_ok) is the only completeness gate -- `codex doctor` is not one.
#
# Arch tokens are full Rust target triples, so this uses fb_rust_triple (NOT
# fb_arch, NOT raw uname -m). The musl build is preferred: it is the one upstream
# publishes for both linux arches, so one selector covers x86_64 and aarch64.
#
# Same-version migration has NO rollback copy: fb_publish_payload does
# `rm -rf final; mv stage final`, so a flat codex-<ver> file is gone the moment the
# verified package replaces it. That is deliberate -- the payload is re-downloadable
# and a rerun repairs. A VALIDATION or extract failure happens before the publish and
# leaves the previous install untouched. Run it with no live codex session: a running
# legacy codex keeps its unlinked inode but loses its sibling lookup.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="codex"
fb_init
fb_require_os

# codex names assets by full Rust target triple, so ask for one rather than
# gluing `uname -m` to a hardcoded suffix.
TRIPLE="$(fb_rust_triple musl)"

# FB_PIN_CODEX holds a bare version (0.167.0); PIN_TAG carries the tag through to
# the asset lookup and is EMPTY otherwise, so the unpinned path keeps reading the
# one cached /releases/latest document instead of opening a second entry at
# /releases/tags/<tag> for the tag it just read from it. The `||` after fb_pin is
# load-bearing under set -e: it returns 1 when unset.
#
# DEVIATION 1: the tag prefix is `rust-v`, not `v`.
PIN_TAG=""
if VERSION="$(fb_pin "$BIN_NAME")"; then
    TAG_NAME="rust-v${VERSION}"
    PIN_TAG="$TAG_NAME"
else
    TAG_NAME="$(gh_latest_tag openai/codex)"
    VERSION="${TAG_NAME#rust-v}"
fi

PAYLOAD="${APP_DIR}/${BIN_NAME}-${VERSION}"
CODEX_BIN="${PAYLOAD}/bin/codex"

# A "complete package" per codex 0.167, driven by the manifest. The manifest
# declares layoutVersion, variant, version, target, entrypoint, execServer,
# resourcesDir and pathDir. codex-code-mode-host is NOT manifest-declared (it is
# a required sibling in bin/ that we check separately); execServer IS declared.
# The files below are the ones the daemon's package copy names (strings on the
# 0.167.0 binary: codex-package.json, codex-code-mode-host, codex-path/rg,
# codex-resources/bwrap, codex-resources/voice/manifest.json). It also rejects
# directory links and non-regular entries, so the three bins must not be
# symlinks. `codex doctor` is NOT a completeness oracle (it reports a package
# for a hollow tree), so this predicate is the only gate. It is a conservative
# approximation of upstream's check, not an implementation of it.
# It needs jq: with jq missing it fails, the slot falls through to the download,
# which fails in gh_asset_url and leaves any existing install in place.
codex_pkg_ok() {          # <root>
    local r="$1" m="$1/codex-package.json"
    [[ -f "$m" && -x "$r/bin/codex" && ! -L "$r/bin/codex" ]] || return 1
    jq -e --arg v "$VERSION" --arg t "$TRIPLE" '
        .layoutVersion == 1 and .variant == "codex"
        and .version == $v and .target == $t
        and .entrypoint == "bin/codex"
        and .execServer == "bin/codex-exec-server"
        and .resourcesDir == "codex-resources"
        and .pathDir == "codex-path"
    ' "$m" >/dev/null 2>&1 || return 1
    [[ -x "$r/bin/codex-code-mode-host" && ! -L "$r/bin/codex-code-mode-host" ]] || return 1
    [[ -x "$r/bin/codex-exec-server" && ! -L "$r/bin/codex-exec-server" ]] || return 1
    [[ -f "$r/codex-resources/bwrap" && -x "$r/codex-resources/bwrap" ]] || return 1
    [[ -f "$r/codex-path/rg" && -x "$r/codex-path/rg" ]] || return 1
    [[ -f "$r/codex-resources/voice/manifest.json" ]] || return 1
    "$r/bin/codex" --version >/dev/null 2>&1
}

# One-shot migration off the flat layout (4a8fa81/6abd15a): the hand-placed
# codex-code-mode-host sibling symlink and its versioned payloads. Called only AFTER
# a complete package is live, on BOTH paths. Plain rm with an -e guard, not the
# shared prune helper (no keep semantics wanted). -L is tested separately because a
# dangling link is not -e.
migrate_legacy_codex() {
    local old
    [[ -L "${APP_DIR}/codex-code-mode-host" ]] && rm -f "${APP_DIR}/codex-code-mode-host"
    for old in "${APP_DIR}"/codex-code-mode-host-[0-9]*; do
        [[ -e "$old" || -L "$old" ]] || continue
        rm -rf "$old"
        echo "  removed legacy companion: $(basename "$old")"
    done
    return 0
}

link_codex() { ln -sfn "$CODEX_BIN" "${BIN_DIR}/${BIN_NAME}"; }

# Fast path, BEFORE the download: a COMPLETE package of this version is already
# there (a flat file or a hollow directory of that name is not). -[0-9] rather
# than a bare -*, per fb_prune_versions.
if codex_pkg_ok "$PAYLOAD"; then
    echo "codex ${VERSION} already installed; symlink ensured -> ${CODEX_BIN}"
    link_codex
    migrate_legacy_codex
    fb_prune_versions "$PAYLOAD" "" "${BIN_NAME}-[0-9]*"
    exit 0
fi
CODEX_PREV="$(fb_prev_payload "$BIN_NAME" /bin/codex)"

# Exact equality, not startswith -- see deviation 2.
ASSET_URL="$(gh_asset_url openai/codex \
    '. == ("codex-package-" + $arch + ".tar.gz")' "$TRIPLE" "" "$PIN_TAG")"

TARBALL="${FB_TMP}/codex-package.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"
# Integrity before the tarball is extracted; the .sigstore bundles are a follow-on.
fb_verify_gh_digest "$TARBALL" openai/codex "$ASSET_URL" "$PIN_TAG"

STAGE="$(fb_stage_payload "$PAYLOAD")"
trap 'rm -rf "$STAGE"; rm -rf "$FB_TMP"' EXIT
mkdir -p "$STAGE"
# NO --strip-components: the upstream package tarball has no top-level directory
# (bin/, codex-package.json, ... are the archive roots). Do not copy slot 07's flag.
tar -xzf "$TARBALL" -C "$STAGE"
if ! codex_pkg_ok "$STAGE"; then
    echo "Error: extracted codex package is incomplete or does not match ${VERSION} ${TRIPLE}." >&2
    echo "       Nothing was published and nothing was relinked; the previous install is untouched." >&2
    exit 1
fi

fb_publish_payload "$STAGE" "$PAYLOAD"
trap 'rm -rf "$FB_TMP"' EXIT
link_codex
migrate_legacy_codex
fb_prune_versions "$PAYLOAD" "$CODEX_PREV" "${BIN_NAME}-[0-9]*"

echo "Installed codex ${VERSION} -> ${BIN_DIR}/${BIN_NAME}"
echo "  target: ${CODEX_BIN} (package root ${PAYLOAD})"
echo "  version: $("$CODEX_BIN" --version 2>&1 | head -1)"
