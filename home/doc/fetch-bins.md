# Home bootstrap (`update-user-home-dir.sh`) + fetch.bins

This dotfiles repo is a **chezmoi source tree**. Dotfiles are applied with chezmoi
(GNU Stow is no longer used), and CLI tools are fetched as pinned static binaries
into `~/.local/`.

## The installer: `update-user-home-dir.sh`

Lives at the **repo root only** (never applied into `~`), alongside the other
management CLIs (`./doctor`, `./keys`, `./apply`, `./status`, `./help`). Those
are day-2 tools; this installer is the ordered bootstrap. Run it from the checkout:

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

**Keep the removal list in lockstep with `fetch.bins/`.** Every
`NN_fetch.<tool>.sh` must map to an entry in the `remove_bin` loop, to a special
case, or to the rust block — a tool that installs anything `remove_bin` does not
know about (a versioned path, a desktop entry, generated config) needs the
special case. zed, podman and ghostty have one; `tree-sitter` was missed when it
was added as slot 15 and was stranded by `--uninstall --force` until it was
added to the loop.

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
- **nvim** (`07_fetch.nvim.sh`) extracts the release tarball whole into
  `~/.local/apps/nvim-<ver>/` and symlinks `~/.local/bin/nvim` **directly at
  the in-tree binary** — the go pattern, **never** `install_bin`: its copy step
  detaches the binary from `share/nvim/runtime`, `$VIMRUNTIME` then falls back
  to the compile-time `/usr/local` paths, and startup floods with E5113/E484.
  The fetcher also deletes the legacy detached copy at `~/.local/apps/nvim`
  left by the old install_bin flow, so machines self-heal on their next run.
- **tree-sitter** (`15_fetch.tree-sitter.sh`) is the tree-sitter CLI, required
  by nvim-treesitter's `main` branch (>= 0.26.1) to build parser grammars. A
  single static binary shipped as a **bare `.gz`** (no tarball), so it gunzips
  then follows the plain `install_bin` pattern. Its asset arch tokens are
  node-style (`x64`/`arm64`), so it maps `uname -m` explicitly.
- **herdr** (`17_fetch.herdr.sh`) is a terminal multiplexer/runtime aimed at AI
  coding agents (Rust, Apache-2.0, `herdrdev/herdr`). It is the **shortest**
  fetcher here, because its release ships a **bare, uncompressed binary** per
  os/arch — no tarball, no zip, not even a `.gz` — so it downloads straight into
  `$FB_TMP` and hands the file to `install_bin`. There is no extraction step to
  get wrong. (jq's release is bare too, but jq builds its URL by interpolation
  because the jq-free bootstrap cannot parse the asset list.) Two things to know:
  - Asset arch tokens are **raw `uname -m`** (`x86_64`/`aarch64`), so `fb_arch` is
    unusable — its sed hardcodes `s/aarch64/arm64/` no matter what label it is
    given, and can never emit `aarch64`. Uses `uname -m` directly, like starship.
  - The selector is an **exact** name match, not `contains`: the release also
    carries `herdr-macos-x86_64`, which a `contains("x86_64")` filter would
    happily select on a linux box.
  - It is **adopted, at parity with tmux** — a ruling that reversed the original
    "fetched, not adopted" position. Its config is chezmoi-managed
    (`home/dot_config/herdr/config.toml`), its completions are wired into the rc
    layer, and its keybindings deliberately mirror `dot_tmux.conf` — **including
    the `ctrl+b` prefix**, which is shared on purpose rather than tolerated. The
    two are never nested, and maximising shared meta-keys is what makes switching
    between them free. Full binding table, the three tmux actions with no herdr
    equivalent, and the "manage one file, not the directory" rule:
    [multiplexers.md](multiplexers.md). Its network test is gated behind
    `--herdr` (`RUN_HERDR_FETCH=1`), since the fetch is ~21 MB.
- **podman** (`12_fetch.podman.sh`) is **not** a single-binary `install_bin`
  fetcher — it mirrors the go whole-tree pattern. The `mgoltzsche/podman-static`
  release tarball is a complete static userland (podman + crun/runc/pasta/
  fuse-overlayfs plus the helper binaries conmon/netavark/aardvark-dns/
  rootlessport/quadlet), extracted into `~/.local/apps/podman-<ver>/` with
  `--strip-components=1`; **only** `podman` is symlinked onto `PATH` (the helpers
  are resolved by config, not `PATH`). Because podman finds those helpers via
  *config files that embed absolute paths* into the version dir, the fetcher
  **regenerates host-local `~/.config/containers/{containers,storage}.conf` every
  run** so the embedded paths always point at the live version. `containers.conf`
  must set `conmon_path` explicitly — `helper_binaries_dir` does **not** cover
  conmon, and without it podman dies "could not find a working conmon binary".
  `storage.conf` **omits `runroot`** so podman derives `$XDG_RUNTIME_DIR/containers`
  (a fixed on-disk runroot would be wrong). `policy.json`/`registries.conf`/
  `seccomp.json` are copied verbatim (no path substitution). It also emits
  `~/.local/bin/podman-rootless-setup` — a distro-aware, root-run helper for the
  one-time host steps full multi-UID rootless needs (subuid/subgid range, the
  `uidmap` package, the userns sysctl). The fetcher itself **never calls sudo**: it
  detects the rootless state and prints advisory guidance, always exiting 0. Its
  network test is gated behind `--podman` (`RUN_PODMAN_FETCH=1`), since the fetch
  is 32 MB.
- **ghostty** (`16_fetch.ghostty.sh`) is the **only AppImage** in `fetch.bins/`
  and the only fetcher that does **not** pull the upstream project's own release
  asset. The Ghostty project ships prebuilt binaries for **macOS only**; on Linux
  it defers to distro maintainers and community builders
  ([ghostty.org/docs/install/binary](https://ghostty.org/docs/install/binary)),
  which lists `pkgforge-dev/ghostty-appimage` under *Community-Maintained
  Binaries* and warns they "carry a much higher risk compared to builds directly
  from the Ghostty project or from distro maintainers". **Where a first-party
  distro package exists (Arch ships `extra/ghostty`), prefer it.** Details that
  are specific to this fetcher:
  - It is a **GUI** tool, so it calls `require_display_or_skip` before `fb_init`
    (zed's ordering) — a tty-only or display-less WSL box skips the 48 MB fetch.
  - It **bypasses `install_bin`**, for a different reason than nvim's: the
    destination is hardcoded to `~/.local/apps/<name>` and cannot carry a
    version. The image installs to `~/.local/apps/ghostty-<ver>.AppImage`, which
    is what enables a **fast path** — an already-current version re-asserts the
    symlink and payloads and exits without re-downloading 48 MB (Phase 5 runs on
    *every* installer invocation). Older versions are pruned on upgrade.
  - Assets are `Ghostty-<ver>-<arch>.AppImage` with **raw `uname -m` tokens**
    (`x86_64`/`aarch64`), not the `amd64`/`arm64` `fb_arch` normalizes to. Each
    has a `.zsync` twin, which the exact-name match excludes.
  - The runtime is **uruntime** (SquashFS + DwarFS), not the stock AppImage
    runtime. Two of its flags are load-bearing: `--appimage-extract [PATTERN]`
    pulls the terminfo/desktop/icon payload for ~4 KB instead of unpacking the
    full **153 MB** tree, and `--appimage-extract-and-run` is the **no-FUSE
    fallback**. The fetcher probes `/dev/fuse` + `fusermount`/`fusermount3` and,
    when absent, verifies under `APPIMAGE_EXTRACT_AND_RUN=1` and prefixes the
    generated `.desktop` `Exec=` with the same env — the no-root guarantee that
    `fb_unzip` exists to protect, applied to AppImages.
  - **terminfo is mandatory, not cosmetic.** Ghostty sets `TERM=xterm-ghostty`,
    and the compiled entry ships *inside* the image, so nothing outside the
    AppImage's own environment can resolve it — the well-known "ghostty breaks
    over ssh" failure. The fetcher extracts `share/terminfo/x/xterm-ghostty` and
    installs it to `~/.terminfo/x/xterm-ghostty` by **plain file copy**: it is
    already a compiled entry, and `tic` is an ncurses extra a minimal no-root box
    may not have.
  - **The shipped `.desktop` is unusable as-is**: `Exec=`/`TryExec=` point at the
    CI build path (`/__w/ghostty-appimage/...`). The fetcher rewrites whole
    lines (the CI path is absolute and arbitrary, so substring swaps are unsafe)
    and repoints `Icon=` at the 512x512 PNG it installs under
    `~/.local/share/icons/hicolor/`.
  - Config is **not** a portable sidecar. uruntime supports `<AppImage>.home` /
    `.config`, but ghostty is left to read `~/.config/ghostty` like every other
    tool, so `home/dot_config/ghostty/config` stays chezmoi-managed and is
    reproduced on a fresh machine. That config pins CaskaydiaCove Nerd Font 10
    and Catppuccin Mocha to match the repo-wide theme; validate edits with
    `ghostty +validate-config --config-file=<path>`.
  - **kitty is the default terminal; ghostty is opt-in.** This is a deliberate
    ruling, not an oversight. Every automated spawn point names kitty —
    hyprland `$terminal` and its `exec-once`, sway `$term`, and rofi
    `terminal:` — so ghostty is reached only by launching it by name or from
    the desktop entry this fetcher installs. Both are kept: kitty is the distro
    package (`extra/kitty`) and carries the tuned 2261-line config; ghostty is
    the no-root AppImage that also works on a box with no package manager
    access. Font and theme are held identical across the two on purpose, so
    switching costs nothing. If you ever do promote ghostty, all four spawn
    points must move together — a partial switch is how you end up with two
    terminals whose configs drift, which is exactly the bug that put a dead
    `font_family` override in `kitty.conf` for months.

## chezmoi source layout (`home/`)
- Attribute-encoded names: `dot_*`, `private_*` (e.g. `private_dot_ssh` → 0700),
  `executable_*`, `symlink_*` (a text file holding the link target), `empty_*` (so
  0-byte files are not silently dropped).
- `home/.chezmoiignore` keeps repo docs (`doc/`) out of `~`.
- Config lives at `~/.config/chezmoi/`; the installer passes `--source`/`--destination`
  explicitly, so no in-repo `.chezmoi.toml` is required.

See `doc/chezmoi.md` for the source-layout encoding, apply/uninstall, and the
migration gotchas; `doc/ssh-agent.md` for the systemd user ssh-agent details.
