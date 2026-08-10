#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# 14_fetch.age.sh — install age (file encryption) via the shared fetch_age()
# helper. age is a BOOTSTRAP tool: `chezmoi apply` calls it to decrypt the
# encrypted ~/.keys, so the installer bootstraps age BEFORE the apply phase
# (like jq and chezmoi). This script is for idempotent re-fetch / standalone use
# from ~/.local/bin/fetch.bins/. Mirrors 01_fetch.jq.sh / 09_fetch.chezmoi.sh.
#
# The stow safety guard (in fb_init) ensures we never run from the checkout.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

fb_init

# Skip if both binaries are already present and valid (version-agnostic check).
if fb_check_bin age && [[ -x "${BIN_DIR}/age" ]] && fb_check_bin age-keygen; then
    echo "age: already valid ($("${BIN_DIR}/age" --version 2>&1 | head -1))"
    exit 0
fi

fetch_age
