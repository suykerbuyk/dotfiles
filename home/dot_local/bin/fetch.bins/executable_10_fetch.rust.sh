#!/usr/bin/env bash
set -euo pipefail

# Rust installer (runs the official rustup-init static binary). Uses lib for the
# safety guard, temp discipline, and gh_download (works for any URL, not just
# GitHub). Rust is special — like nvm — in that it is a self-updating toolchain
# manager that owns its own home dirs (~/.cargo, ~/.rustup) rather than a single
# symlinked binary. So it does NOT go through install_bin / fb_check_bin.
# See Context.fetch.bins.refactor.md and home/doc/fetch-bins.md.

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/_lib.sh"

fb_init

# Standard rustup layout. Hardcoded to the defaults on purpose: the shell rc
# (dot_zshrc / dot_bashrc-*) already sources "$HOME/.cargo/env" and adds
# ~/.cargo/bin to PATH when ~/.cargo/bin/cargo exists. Keep these in lockstep
# with that wiring — don't relocate into APP_DIR.
export CARGO_HOME="$HOME/.cargo"
export RUSTUP_HOME="$HOME/.rustup"
RUSTUP_BIN="${CARGO_HOME}/bin/rustup"

# Self-heal fast path: rustup already present and runnable. Pull the latest
# stable toolchain and exit (idempotent, mirrors Go's symlink re-assert and
# nvm's "already installed" message). This is also what keeps us on *latest*
# stable across re-runs.
if [[ -x "$RUSTUP_BIN" ]] && "$RUSTUP_BIN" --version >/dev/null 2>&1; then
    echo "rustup already at $CARGO_HOME; updating stable toolchain…"
    "$RUSTUP_BIN" update stable
    echo "  cargo: $("${CARGO_HOME}/bin/cargo" --version 2>&1 | head -1)"
    echo "  rustc: $("${CARGO_HOME}/bin/rustc" --version 2>&1 | head -1)"
    exit 0
fi

# rustup publishes a static rustup-init per host triple. Target the gnu triples
# (glibc) to match the Debian/Arch machines this repo bootstraps.
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)          TRIPLE="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64)   TRIPLE="aarch64-unknown-linux-gnu" ;;
    *) echo "Error: unsupported arch '$ARCH' for rustup-init." >&2; exit 1 ;;
esac

INIT_URL="https://static.rust-lang.org/rustup/dist/${TRIPLE}/rustup-init"
INIT_BIN="${FB_TMP}/rustup-init"

echo "Fetching rustup-init ($TRIPLE)…"
gh_download "$INIT_URL" "$INIT_BIN"   # generic curl helper — any URL, fail-loud
chmod +x "$INIT_BIN"

# Non-interactive install of latest stable.
#   --no-modify-path : chezmoi-managed dotfiles own PATH (dot_zshrc / dot_bashrc-*
#                      already source ~/.cargo/env). Never let rustup scribble
#                      into ~/.profile / ~/.bashrc — that would contaminate
#                      files chezmoi is the source of truth for.
#   --profile default: rustc, cargo, rust-std, rust-docs, clippy, rustfmt.
"$INIT_BIN" -y --no-modify-path --profile default --default-toolchain stable

# Verify in place before declaring success.
if ! "${CARGO_HOME}/bin/cargo" --version >/dev/null 2>&1; then
    echo "Error: cargo is not runnable after install." >&2
    exit 1
fi

echo "Installed Rust (rustup, stable) to $CARGO_HOME / $RUSTUP_HOME"
echo "  cargo: $("${CARGO_HOME}/bin/cargo" --version 2>&1 | head -1)"
echo "  rustc: $("${CARGO_HOME}/bin/rustc" --version 2>&1 | head -1)"
echo "  (shell already sources ~/.cargo/env; run 'exec \$SHELL -l' to pick it up)"
