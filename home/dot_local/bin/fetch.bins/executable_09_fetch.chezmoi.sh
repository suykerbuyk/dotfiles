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
fb_require_os chezmoi

# No local "already valid" gate any more. That check was fb_check_bin's
# version-agnostic one: it passed as soon as ~/.local/bin/chezmoi resolved to
# something executable, so chezmoi could never be upgraded by this slot or by
# the installer's Phase 2, which carried a copy of the same gate.
#
# fetch_chezmoi now owns the decision: it resolves the version, answers from the
# FILESYSTEM whether that version is installed, and returns without downloading
# when it is. One decision, both callers.
fetch_chezmoi
