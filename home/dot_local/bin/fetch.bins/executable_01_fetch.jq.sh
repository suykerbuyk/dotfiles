#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# 01_fetch.jq.sh — install jq via the shared fetch_jq() helper. jq is the ONE
# tool that must bootstrap without jq (every other fetcher parses GitHub release
# JSON with it), so fetch_jq() uses only the jq-free helpers (gh_latest_tag_nojq
# + an interpolated URL). See Context.fetch.bins.refactor.md.
#
# Note: the installer (update-user-home-dir.sh) bootstraps jq itself in Phase 1,
# BEFORE `chezmoi apply`, so this script is mainly for idempotent re-fetch or
# standalone use from ~/.local/bin/fetch.bins/. Mirrors 09_fetch.chezmoi.sh.
#
# The stow safety guard (in fb_init) ensures we never run from the checkout.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

fb_init

# Defer to a system-wide jq (the same trap as slot 22/23): fb_init prepends
# $BIN_DIR, so a bare `command -v jq` would find OUR OWN symlink after the
# first install and skip forever. A distro jq is enough; fetching another
# copy hits the GitHub API for no gain. JQ_FETCH_FORCE=1 overrides.
if [[ "${JQ_FETCH_FORCE:-0}" != "1" ]]; then
    if SYSTEM_JQ="$(fb_system_bin jq --version)"; then
        echo "jq: already provided system-wide at ${SYSTEM_JQ} — skipping."
        echo "  $("$SYSTEM_JQ" --version 2>&1 | head -1)"
        echo "  Set JQ_FETCH_FORCE=1 to install a user-local copy anyway."
        exit 0
    fi
fi

# Skip if already present and valid (version-agnostic check).
if fb_check_bin jq && [[ -x "${BIN_DIR}/jq" ]]; then
    echo "jq: already valid ($("${BIN_DIR}/jq" --version 2>&1 | head -1))"
    exit 0
fi

fetch_jq
