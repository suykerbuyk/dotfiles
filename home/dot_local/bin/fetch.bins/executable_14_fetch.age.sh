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
fb_require_os age

# No local "already valid" gate any more. That check was fb_check_bin's
# version-agnostic one: it passed as soon as both symlinks resolved, so age could
# never be upgraded by this slot or by the installer's Phase 3, which carried a
# copy of the same gate.
#
# fetch_age now owns the decision, and keeps the both-or-neither rule inside it:
# the two binaries live in ONE versioned directory, so a run interrupted partway
# can no longer leave age and age-keygen at different versions.
fetch_age
