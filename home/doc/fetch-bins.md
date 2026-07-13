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

### Why the order is fetch-chezmoi → apply → fetch-tools

The repo is a chezmoi source, so script names are attribute-encoded
(`executable_01_fetch.jq.sh`, `dot_zshrc`, `private_dot_ssh/…`) and are **not
runnable in place** from the checkout. So the installer:

1. **Phase 1 — chezmoi binary.** Fetches the static Go release binary
   (`fetch_chezmoi` in `_lib.sh`) into `~/.local/bin/chezmoi`. Skipped if already
   present and valid (unless `--force`).
2. **Phase 2 — `chezmoi apply --force`.** Lays down every dotfile *and* the
   `~/.local/bin/` tooling (with decoded names) into `$HOME`. `--force` keeps it
   non-interactive — chezmoi otherwise prompts (`overwrite/skip/…`) when a target
   changed and would block a scripted run.
3. **Phase 3 — tool fetchers.** Runs `~/.local/bin/fetch.bins/*.sh` (now present
   and correctly named) in numeric order (jq first). `09_fetch.chezmoi.sh` is
   skipped here (already done in Phase 1).
4. **Phase 4 — ssh-agent.** Runs `~/.local/bin/setup-ssh-agent.sh` **only** when a
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
- `gh_latest_tag` / `gh_asset_url` / `gh_download` — GitHub release helpers.
- `install_bin src name [verify-args]` — copy to `~/.local/apps`, verify, then
  symlink (verification gate before the symlink is created).
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

## chezmoi source layout (`home/`)
- Attribute-encoded names: `dot_*`, `private_*` (e.g. `private_dot_ssh` → 0700),
  `executable_*`, `symlink_*` (a text file holding the link target), `empty_*` (so
  0-byte files are not silently dropped).
- `home/.chezmoiignore` keeps repo docs (`doc/`) out of `~`.
- Config lives at `~/.config/chezmoi/`; the installer passes `--source`/`--destination`
  explicitly, so no in-repo `.chezmoi.toml` is required.

See `doc/ssh-agent.md` for the systemd user ssh-agent details.
