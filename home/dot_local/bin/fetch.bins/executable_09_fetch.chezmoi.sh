#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# 09_fetch.chezmoi.sh — install chezmoi (static Go release binary) into
# ~/.local/bin via the shared fetch_chezmoi() helper (same gh_* pattern as the
# other fetchers). Runs after jq (01) so gh_asset_url's jq filter is available.
#
# Note: the installer (update-user-home-dir.sh) bootstraps chezmoi itself BEFORE
# `chezmoi apply`, so this script is mainly for idempotent re-fetch or standalone
# use from ~/.local/bin/fetch.bins/.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

fb_init

# Skip if already present and valid (version-agnostic check).
if fb_check_bin chezmoi && [[ -x "${BIN_DIR}/chezmoi" ]]; then
    echo "chezmoi: already valid ($("${BIN_DIR}/chezmoi" --version 2>&1 | head -1))"
    exit 0
fi

fetch_chezmoi
