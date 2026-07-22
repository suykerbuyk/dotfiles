# Home bootstrap (`update-user-home-dir.sh`) + fetch.bins

This dotfiles repo is a **chezmoi source tree**. Dotfiles are applied with chezmoi
(GNU Stow is no longer used), and CLI tools are fetched as pinned static binaries
into `~/.local/`.

## The installer: `update-user-home-dir.sh`

Lives at the **repo root only** (never applied into `~`). Run it from the checkout:

```bash
./update-user-home-dir.sh              # full bootstrap
./update-user-home-dir.sh --dry-run    # preview every phase, no changes
./update-user-home-dir.sh --force      # re-fetch the chezmoi binary, then apply
./update-user-home-dir.sh --uninstall  # preview removal (add --force to actually remove)
```

### Why the order is fetch-jq → fetch-chezmoi → apply → fetch-tools

The repo is a chezmoi source, so script names are attribute-encoded
(`executable_01_fetch.jq.sh`, `dot_zshrc`, `private_dot_ssh/…`) and are **not
runnable in place** from the checkout. So the installer:

1. **Phase 1 — jq (jq-free bootstrap).** Fetches jq FIRST, via `fetch_jq` in
   `_lib.sh`, using only the jq-free helpers (`gh_latest_tag_nojq` + an
   interpolated URL — jq's asset name `jq-linux-amd64` is predictable). This is
   the fresh-machine fix: `fetch_chezmoi` and every other fetcher parse GitHub
   release JSON with `jq`, so a box with no system jq used to die at Phase 2's
   first `jq` call. `fb_init` also puts `~/.local/bin` on `PATH` **for this run**
   (the env layer that normally does so is only laid down in Phase 3 and is never
   sourced into the running installer), so the jq installed here is found by the
   phases below. Skipped if already present and valid (unless `--force`).
2. **Phase 2 — chezmoi binary.** Fetches the static Go release binary
   (`fetch_chezmoi` in `_lib.sh`, which uses the jq from Phase 1) into
   `~/.local/bin/chezmoi`. Skipped if already present and valid (unless `--force`).
3. **Phase 3 — `chezmoi apply --force`.** Lays down every dotfile *and* the
   `~/.local/bin/` tooling (with decoded names) into `$HOME`. `--force` keeps it
   non-interactive — chezmoi otherwise prompts (`overwrite/skip/…`) when a target
   changed and would block a scripted run.
4. **Phase 4 — tool fetchers.** Runs `~/.local/bin/fetch.bins/*.sh` (now present
   and correctly named) in numeric order. `01_fetch.jq.sh` and
   `09_fetch.chezmoi.sh` are skipped here (already bootstrapped in Phases 1–2).
5. **Phase 5 — ssh-agent.** Runs `~/.local/bin/setup-ssh-agent.sh` **only** when a
   user session bus is present (`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`);
   otherwise skipped cleanly (headless/WSL). The guard is inline in the installer.

### Uninstall

`--uninstall` is a **preview by default**; pass `--force` to act. It removes the
chezmoi-managed files from `~` (via `chezmoi managed`), removes fetched tools (via
`remove_bin`), and clears chezmoi's own state/config. It never touches the repo.

## `fetch.bins/` + `_lib.sh`

Each `NN_fetch.<tool>.sh` sources `_lib.sh` and installs one tool as a **versioned
static binary** under `~/.local/apps/`, symlinked into `~/.local/bin/`.

Key `_lib.sh` helpers:
- `fb_init` — dirs, temp dir with cleanup trap, and a guard against running inside
  the git checkout.
- `gh_latest_tag` / `gh_asset_url` / `gh_download` — GitHub release helpers (the
  first two use `jq`). `gh_latest_tag_nojq` is the `grep`/`awk` variant used only
  by the jq bootstrap, which cannot depend on jq.
- `fb_unzip zip destdir` — extract a `.zip` with **no root and no system `unzip`**
  (the prime directive: an unprivileged user must still end up fully operational).
  Tries, in order, `unzip` → `bsdtar` → `busybox unzip` → `python3`; every path
  **preserves the unix exec bit** (the `python3` fallback restores it from the
  archive's stored attributes, which a bare `python3 -m zipfile -e` drops — that
  would leave `ninja` non-executable). Fails loud only if *none* of
  the four exist. Set `FB_UNZIP_BACKEND=unzip|bsdtar|busybox|python3` to pin a
  single backend (used by the test harness to prove each path in isolation). Used
  by broot and ninja.
- `fetch_jq` / `fetch_chezmoi` — the two bootstrap installers that live in
  `_lib.sh` (not standalone scripts) so the root installer can call them from the
  checkout before `chezmoi apply` exists. `01_fetch.jq.sh` and `09_fetch.chezmoi.sh`
  are thin wrappers that just call them, for idempotent re-fetch / standalone use.
- `install_bin src name [verify-args]` — copy to `~/.local/apps`, verify, then
  symlink (verification gate before the symlink is created). **Pass a `src` that is
  not already `~/.local/apps/<name>`** — idiomatically the extracted binary in
  `$FB_TMP`; `install_bin` owns the copy into `~/.local/apps`. A caller that
  pre-moves the binary to that destination itself makes the copy a self-copy, which
  `cp` rejects; under `set -e` the script then dies *before* the symlink, leaving the
  runtime installed and nothing on `PATH`. (This silently broke fzf. `install_bin`
  now skips the copy when `src` and the destination resolve to the same path, but
  the calling convention above is still the one to follow.)
- `fb_check_bin name` — **version-agnostic** validity check: reinstalls on a broken
  symlink or a target that is missing / not executable (no hardcoded versions).
- `fetch_chezmoi` — fetch the chezmoi static release binary (same `gh_*` pattern).
- `remove_bin name` — remove a tool's symlink and `~/.local/apps` runtime.

### Notes on specific tools
- **Go** (`04_fetch.go.sh`) is symlinked **in place** at `~/.local/apps/<version>/bin/go`
  — never copied out — so `GOROOT` resolves correctly. The symlinks are re-asserted
  on every run (self-healing across version bumps).
- **chezmoi** uses the plain `chezmoi_<ver>_linux_<arch>.tar.gz` asset (statically
  linked Go binary; no glibc/musl variant needed).
- **Rust** (`10_fetch.rust.sh`) installs via the official `rustup-init` into the
  **standard layout** (`~/.cargo` + `~/.rustup`), not `~/.local/apps` — the shell
  rc (`dot_zshrc`, `dot_bashrc-*`) already sources `~/.cargo/env`. Run with
  `--no-modify-path` so rustup never edits `~/.profile`/`~/.bashrc` (chezmoi owns
  those). On re-run it self-heals via `rustup update stable` (latest stable).
  Like nvm, it is a self-updating toolchain manager, so it bypasses
  `install_bin`/`fb_check_bin`; uninstall is `rustup self uninstall -y`.
- **ninja** (`11_fetch.ninja.sh`) is a single statically-linked binary shipped in
  a **.zip** (not a tarball), so it unzips instead of untars but is otherwise the
  plain `install_bin` pattern. The release assets are named by platform, not the
  usual arch tokens (`ninja-linux.zip`, `ninja-linux-aarch64.zip`,
  `ninja-mac.zip`), so it matches the exact asset name. Extracted via `fb_unzip`,
  so no system `unzip` is required.
- **starship** (`13_fetch.starship.sh`) is the prompt for **both** shells (see
  `doc/shell.md`), fetched as a single static binary in a `.tar.gz` — the plain
  `install_bin` pattern, same shape as fzf. Its asset arch tokens are Rust target
  triples (`x86_64`, `aarch64`), **not** the `amd64`/`arm64` that `fb_arch`
  normalizes to, so it uses `uname -m` directly. It selects the **musl** build:
  it is fully static, and it is the only linux build published for aarch64, so one
  selector covers both architectures.

## chezmoi source layout (`home/`)
- Attribute-encoded names: `dot_*`, `private_*` (e.g. `private_dot_ssh` → 0700),
  `executable_*`, `symlink_*` (a text file holding the link target), `empty_*` (so
  0-byte files are not silently dropped).
- `home/.chezmoiignore` keeps repo docs (`doc/`) out of `~`.
- Config lives at `~/.config/chezmoi/`; the installer passes `--source`/`--destination`
  explicitly, so no in-repo `.chezmoi.toml` is required.

See `doc/chezmoi.md` for the source-layout encoding, apply/uninstall, and the
migration gotchas; `doc/ssh-agent.md` for the systemd user ssh-agent details.
