#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

# 1Password CLI (op v2) installer.
#
# Follows the tsh (slot 22) pattern closely. Key differences from the
# ripgrep-style fetchers:
#
# - Uses AgileBits CDN directly (predictable URL, no GitHub API).
# - Ships as a simple .zip containing a single static binary (no tarball,
#   no nested dirs).
# - Pinned to v2.39.0. Set OP_FETCH_VERSION=2.x.y to override.
# - Uses fb_unzip (already battle-tested by broot, ninja, etc.).
# - DEFERS TO A SYSTEM-WIDE `op`. The distro/AUR package is named
#   `1password-cli` and writes /usr/bin/op (setgid onepassword-cli). A
#   second copy in ~/.local/bin would SHADOW it — the env layer puts
#   ~/.local/bin first — and we would take over an upgrade treadmill
#   for a tool the box already maintains, WITHOUT the setgid bit the
#   desktop app requires. fb_system_bin, not a bare `command -v`:
#   fb_init prepends $BIN_DIR, so command -v would find OUR OWN symlink
#   and skip forever after run 1. OP_FETCH_FORCE=1 overrides.
# - Linux desktop-app IPC authenticates the CLI by setgid group
#   onepassword-cli. A user-owned 0755 binary gets ECONNRESET on
#   1Password-BrowserSupport.sock. install_bin recopies and STRIPS
#   setgid, so the check below runs after every user-local install,
#   including the "already valid" skip. Fetchers stay rootless: try
#   chgrp/chmod without sudo, then print the two commands. Never call
#   sudo here.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

BIN_NAME="op"
fb_init

# Report (and try to apply) Linux setgid onepassword-cli on a resolved
# binary. Used for both a system op we deferred to and a user-local
# copy we just installed. Keep the predicate in lockstep with
# df_op_linux_sgid_ok in lib/df-common.sh.
op_ensure_linux_sgid() {
    local op_bin="$1"
    [[ -n "$op_bin" && -e "$op_bin" ]] || return 0
    if [[ -g "$op_bin" && "$(stat -c '%G' "$op_bin" 2>/dev/null)" == onepassword-cli ]]; then
        echo "op: desktop IPC ok (setgid onepassword-cli) at ${op_bin}"
        return 0
    fi
    if getent group onepassword-cli >/dev/null 2>&1 \
        && chgrp onepassword-cli "$op_bin" 2>/dev/null \
        && chmod g+s "$op_bin" 2>/dev/null \
        && [[ -g "$op_bin" && "$(stat -c '%G' "$op_bin")" == onepassword-cli ]]; then
        echo "op: applied setgid onepassword-cli (desktop-app IPC) at ${op_bin}"
        return 0
    fi
    echo "WARNING: ${op_bin} is not setgid onepassword-cli." >&2
    echo "  The 1Password desktop app will reset CLI connections until it is." >&2
    echo "  Fetchers are rootless and cannot do this for you:" >&2
    if ! getent group onepassword-cli >/dev/null 2>&1; then
        echo "    sudo groupadd -f onepassword-cli" >&2
    fi
    echo "    sudo chgrp onepassword-cli ${op_bin}" >&2
    echo "    sudo chmod g+s ${op_bin}" >&2
    echo "  Then: op whoami   (approve the prompt in the 1Password app)" >&2
    return 0
}

# ----------------------------------------------------------------------
# Defer to a system-wide install (the `1password-cli` package).
# See header. Probe is `op --version` (unlike tsh, that flag works).
# ----------------------------------------------------------------------
if [[ "${OP_FETCH_FORCE:-0}" != "1" ]]; then
    if SYSTEM_OP="$(fb_system_bin "$BIN_NAME" --version)"; then
        echo "op: already provided system-wide at ${SYSTEM_OP} — skipping."
        echo "  $("$SYSTEM_OP" --version 2>&1 | head -1)"
        echo "  Set OP_FETCH_FORCE=1 to install a user-local copy anyway."
        if [[ -e "${BIN_DIR}/${BIN_NAME}" ]]; then
            echo "  note: ${BIN_DIR}/${BIN_NAME} still shadows it; delete that symlink to use the system binary."
        fi
        op_ensure_linux_sgid "$SYSTEM_OP"
        exit 0
    fi
fi

VERSION="${OP_FETCH_VERSION:-2.39.0}"
OS="$(fb_os)"
ARCH="$(fb_arch)"

if [[ "$OS" != "linux" ]]; then
    echo "Error: this fetcher currently supports only linux (got '$OS')." >&2
    echo "       macOS/Windows users should use the official 1Password installer." >&2
    exit 1
fi

if [[ "$ARCH" != "amd64" ]]; then
    echo "Error: this fetcher is currently amd64-only (got '$ARCH')." >&2
    echo "       arm64 support can be added later using op_linux_arm64_*.zip." >&2
    exit 1
fi

# Already-valid fast path: do not re-download the zip only for install_bin
# to answer "already valid". Still run the setgid check — a previous
# apply is stripped the moment install_bin recopies, and a previous skip
# leaves a binary whose perms were never checked.
#
# Restore a missing PATH symlink onto an existing payload FIRST. fb_check_bin
# only looks at BIN_DIR, so a deleted ~/.local/bin/op with a live
# ~/.local/apps/op (held open by `op daemon`) looked like "not installed"
# and the subsequent in-place cp hit ETXTBSY, leaving PATH still empty.
if [[ -x "${APP_DIR}/${BIN_NAME}" ]]; then
    ln -sfn "${APP_DIR}/${BIN_NAME}" "${BIN_DIR}/${BIN_NAME}"
fi
if fb_check_bin "$BIN_NAME" && [[ -x "${BIN_DIR}/${BIN_NAME}" ]]; then
    echo "op: already valid (skipping download)"
    op_ensure_linux_sgid "${APP_DIR}/${BIN_NAME}"
    echo "Desktop integration: 1Password Settings > Developer > Integrate with 1Password CLI."
    exit 0
fi

ASSET_URL="https://cache.agilebits.com/dist/1P/op2/pkg/v${VERSION}/op_linux_amd64_v${VERSION}.zip"

ZIP="${FB_TMP}/op.zip"
curl -fL -o "$ZIP" "$ASSET_URL"

# Extract directly to $FB_TMP — the zip contains only the 'op' binary
fb_unzip "$ZIP" "$FB_TMP"

install_bin "${FB_TMP}/op" "$BIN_NAME" --version

op_ensure_linux_sgid "${APP_DIR}/${BIN_NAME}"

echo "Installed op ${VERSION} -> ${BIN_DIR}/${BIN_NAME}"
echo "Desktop integration: 1Password Settings > Developer > Integrate with 1Password CLI."
