#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# delta installer (syntax-highlighting pager for git/diff output; Rust, MIT,
# dandavison/delta). Same tarball shape as fd/bat/xh, but delta is the odd one
# out in THREE ways, all of them load-bearing.
#
# 1. NO aarch64 MUSL BUILD. This is the hazard that makes delta different from
#    every sibling. Its linux assets are:
#        delta-0.19.2-aarch64-unknown-linux-gnu.tar.gz      <- gnu ONLY
#        delta-0.19.2-arm-unknown-linux-gnueabihf.tar.gz
#        delta-0.19.2-i686-unknown-linux-gnu.tar.gz
#        delta-0.19.2-x86_64-unknown-linux-gnu.tar.gz
#        delta-0.19.2-x86_64-unknown-linux-musl.tar.gz      <- musl exists here only
#    The blanket musl filter its siblings use therefore resolves to NOTHING on
#    arm64, and the fetcher dies at gh_asset_url's "no matching asset" exit. And
#    like the fb_arch trap, that failure is INVISIBLE from an x86_64 machine: it
#    passes here forever. Hence the explicit prefer-musl / fall-back-to-gnu
#    branch below — a deliberate, commented decision rather than an accident of
#    a loose filter. The other three have musl for both arches and stay
#    musl-only.
#
# 2. THE TAG HAS NO "v". Upstream tags delta as `0.19.2`, not `v0.19.2`, and the
#    directory inside the tarball carries the tag verbatim
#    (delta-0.19.2-x86_64-unknown-linux-musl/delta). So delta interpolates
#    ${VERSION} — exactly the ripgrep idiom — while fd/bat/xh must use
#    ${TAG_NAME} WITH the "v". The asymmetry between slot 20 and its neighbours
#    is real and per-project. Do not "fix" it in either direction.
#
# 3. NO COMPLETION FILES IN THE TARBALL. delta ships only the binary, a README
#    and a LICENSE; it generates completions on demand instead
#    (`delta --generate-completion zsh|bash`). Generating from the binary that
#    was just installed keeps the completions matched to the installed version
#    for free.
#
# Arch tokens are RAW `uname -m`, so fb_arch is unusable here for the usual
# reason: its sed hardcodes `s/aarch64/arm64/` and can never emit `aarch64`.
# Uses `uname -m` directly.
#
# GIT WIRING. delta is inert as a bare binary: it does nothing until git's
# core.pager and interactive.diffFilter point at it. This fetcher therefore owns
# five git keys IMPERATIVELY, via `git config --global`, after a successful
# install — the podman (slot 12) and ghostty (slot 16) precedent, where a
# fetcher generates host-local config the committed tree does not carry.
#
# Why imperative and NOT a chezmoi-managed ~/.gitconfig: three other writers
# already own parts of that file — `gh` writes the credential helpers, `vp`
# writes its merge driver, and `git config --global` itself writes on any manual
# change. A declarative managed copy would fight all three forever. It would
# also be actively dangerous here: this user's git identity is deliberately
# per-host (nine distinct author emails across the public history), and a
# managed file carrying a hardcoded `[user] email` would silently re-attribute
# commits on every machine at the next apply. Setting only the five keys we own
# makes that entire hazard disappear — we never see, touch, or restate the rest
# of the file. See doc/fetch-bins.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="delta"
fb_init
fb_require_os

OS="$(fb_os)"
ARCH="$(uname -m)"  # x86_64 | aarch64 — matches delta's asset names as-is

TAG_NAME="$(gh_latest_tag dandavison/delta)"
# No-op today (the tag has no "v"), so $VERSION == $TAG_NAME. Kept anyway: it
# costs nothing and stays correct if upstream ever starts tagging with a "v".
VERSION="${TAG_NAME#v}"

# Prefer musl (fully static, no glibc floor); fall back to gnu where upstream
# publishes no musl build for this arch — which today means aarch64.
#
# gh_asset_url `exit 1`s when nothing matches, which is what makes probing it
# awkward. The `|| ASSET_URL=""` MUST sit OUTSIDE the command substitution:
# `exit` terminates the subshell outright, so an inner `$(… || true)` never runs
# its fallback — the substitution still yields status 1, and `set -e` kills the
# script at the assignment. That form looks correct, passes every structural
# grep, and fails ONLY on an arch with no musl build. It was written that way
# first and caught by an aarch64 dry run, not by the test suite.
LIBC="musl"
ASSET_URL="$(gh_asset_url dandavison/delta \
    'endswith(".tar.gz") and contains("linux-musl") and contains($arch)' "$ARCH" 2>/dev/null)" \
    || ASSET_URL=""
if [[ -z "$ASSET_URL" ]]; then
    LIBC="gnu"
    echo "→ delta publishes no linux-musl build for ${ARCH}; falling back to linux-gnu" >&2
    ASSET_URL="$(gh_asset_url dandavison/delta \
        'endswith(".tar.gz") and contains("linux-gnu") and contains($arch)' "$ARCH")"
fi

TARBALL="${FB_TMP}/delta.tar.gz"
gh_download "$ASSET_URL" "$TARBALL"

tar -xzf "$TARBALL" -C "$FB_TMP"
# ${VERSION}, not ${TAG_NAME}: delta's tag carries no "v". See note 2 above.
# ${LIBC} is what the musl/gnu branch above resolved to.
SRC_DIR="${FB_TMP}/${BIN_NAME}-${VERSION}-${ARCH}-unknown-${OS}-${LIBC}"

install_bin "${SRC_DIR}/${BIN_NAME}" "$BIN_NAME" --version

# Generated, not shipped (note 3). Generate from the INSTALLED binary rather
# than the extracted one, so that on a run where install_bin took its
# "already valid (skipping)" path the completions still describe the delta that
# is actually on PATH.
"${BIN_DIR}/${BIN_NAME}" --generate-completion zsh  > "${FB_TMP}/_delta"
"${BIN_DIR}/${BIN_NAME}" --generate-completion bash > "${FB_TMP}/delta.bash"
fb_install_completions "$BIN_NAME" "${FB_TMP}/_delta" "${FB_TMP}/delta.bash"

# --- git wiring ---------------------------------------------------------------
# Only reached after install_bin succeeded (it exits non-zero on a failed
# verification), so core.pager never names a delta that is not there. That
# ordering is load-bearing: `core.pager = delta` with no delta on PATH does NOT
# degrade — `git diff` dies with "fatal: unable to execute pager 'delta'" and
# exit 128, printing no diff at all. An unguarded interactive.diffFilter is just
# as brittle: `git add -p` fails with "mismatched output from
# interactive.diffFilter", exit 1.
#
# Idempotent by construction: `git config --global <key> <value>` REPLACES the
# key in place, so re-running this fetcher never duplicates a line or a section.
#
# We own exactly these five keys and never restate the rest of the file, which
# is what keeps `gh`'s credential helpers, `vp`'s merge driver and the user's
# per-host [user] identity out of our blast radius entirely.
#
# core.pager is set unconditionally — delta ownership is the whole point — but a
# pre-existing NON-delta value is reported rather than silently swallowed, since
# that is a user preference being overridden.
#
# Guarded on git EXISTING. This repo's prime directive is that an unprivileged
# user on a minimal box still ends up operational, and such a box may well have
# no git. Without the guard the first `git config` call fails, `set -e` kills the
# script, and the fetcher exits non-zero having ALREADY installed delta
# successfully — a spurious failure for a tool that is otherwise fine. delta is
# useful standalone (`delta a.txt b.txt`), so no git is not an error here.
if command -v git >/dev/null 2>&1; then
    _prev_pager="$(git config --global --get core.pager 2>/dev/null || true)"
    if [[ -n "$_prev_pager" && "$_prev_pager" != delta* ]]; then
        echo "  note: replacing existing git core.pager ('${_prev_pager}') with delta" >&2
    fi

    git config --global core.pager delta
    git config --global interactive.diffFilter 'delta --color-only'
    git config --global delta.navigate true
    git config --global delta.side-by-side true
    git config --global delta.line-numbers true
    echo "  git:     core.pager + interactive.diffFilter -> delta (navigate, side-by-side, line-numbers)"
else
    echo "  note: git not found — skipped the delta git wiring (delta itself is installed)" >&2
fi

echo "Installed delta ${VERSION} (${LIBC} tarball) -> ${BIN_DIR}/${BIN_NAME}"
