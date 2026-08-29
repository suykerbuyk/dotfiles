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
   phases below. **Defers to a system-wide `jq`** via `fb_system_bin` (same
   trap as slots 22/23): a distro jq is enough, and hitting GitHub for a second
   copy is what exhausted the unauthenticated 60 req/hour budget after a couple
   of `--force` runs. Skipped if the user-local copy is already valid (unless
   `--force` *and* no system jq). `JQ_FETCH_FORCE=1` on `01_fetch.jq.sh`
   installs a user-local copy anyway.
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
special case. zed, podman, ghostty and delta have one; `tree-sitter` was missed
when it was added as slot 15 and was stranded by `--uninstall --force` until it
was added to the loop.

The rule covers **artifacts, not just binaries**. Slots 18–21 install shell
completion files, so the uninstall path calls `fb_remove_completions` alongside
the `remove_bin` loop; delta additionally owns five global git keys, so it gets a
special case that unsets them. A fetcher whose *side effects* are absent from
teardown strands them exactly the way tree-sitter's binary was stranded.

## `fetch.bins/` + `_lib.sh`

Each `NN_fetch.<tool>.sh` sources `_lib.sh` and installs one tool as a **versioned
static binary** under `~/.local/apps/`, symlinked into `~/.local/bin/`. There are
currently **23 slots** (01–23).

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
- `fb_install_completions tool zsh-src bash-src` / `fb_remove_completions tool…` —
  install (or tear down) shell completion **files** for slots 18–21. The zsh file
  is always installed as `_<tool>`, whatever it is called upstream. Full scheme,
  and why the rename is load-bearing: [shell.md](shell.md).

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
- **fd / bat / delta / xh** (slots **18–21**) are four Rust CLI tools that all
  follow the ripgrep (slot 03) shape — a single binary in a release `.tar.gz` —
  and all four also install **shell completions** (see
  [shell.md](shell.md#completion-files-the-site-functions-scheme)). What is worth
  knowing is where they differ from ripgrep and from each other:
  - **All four use raw `uname -m`**, never `fb_arch`. Their asset names carry
    `x86_64`/`aarch64`, and `fb_arch`'s sed hardcodes `s/aarch64/arm64/`, so it can
    never emit `aarch64` — a fetcher routed through it 404s on every arm64 box
    while passing forever on x86_64. Same trap as starship, herdr and ghostty.
  - **The asset filter is anchored with `endswith(".tar.gz")`.** fd and bat both
    publish `.deb` files whose names contain `musl` (`fd-musl_10.4.2_amd64.deb`,
    `bat-musl_0.26.1_musl-linux-amd64.deb`). Their Debian-style arch tokens
    (`amd64`/`arm64`) exclude them from a raw-`uname -m` match today, but that is
    luck, not a guard. The filter also says `linux-musl` rather than bare `musl`,
    which would additionally match the armv7 `musleabihf` builds.
  - **delta has NO aarch64 musl build** — the one genuinely new hazard here.
    Upstream publishes musl for `x86_64` only; every other linux asset is `gnu`.
    The blanket musl filter its three siblings use therefore resolves to nothing on
    arm64 and the fetcher dies at `gh_asset_url`'s "no matching asset" exit —
    invisibly from an x86_64 machine. `20_fetch.delta.sh` accordingly **prefers
    musl and falls back to gnu** in an explicit, commented branch (the probe works
    because `gh_asset_url`'s `exit 1` happens in a command-substitution subshell,
    so `|| true` turns "no match" into an empty string instead of killing the
    script). The other three are musl for both arches and stay musl-only.
  - **The tag-vs-version split is per-project and is not a bug.** The directory
    inside each tarball carries the tag *verbatim*. fd/bat/xh tag with a leading
    `v` (`fd-v10.4.2-…`) so they interpolate `${TAG_NAME}`; delta tags **without**
    one (`delta-0.19.2-…`) so it uses `${VERSION}`. Applying ripgrep's
    `VERSION="${TAG_NAME#v}"` idiom uniformly is correct for delta and wrong for
    the other three.
  - **delta is inert as a bare binary**, so `20_fetch.delta.sh` also wires it into
    git — see the next bullet.
- **delta's git wiring is imperative, by design.** After a successful install,
  `20_fetch.delta.sh` runs `git config --global` for exactly five keys:
  `core.pager`, `interactive.diffFilter`, and `delta.{navigate,side-by-side,line-numbers}`.
  This is the podman/ghostty precedent — a fetcher owning host-local config the
  committed tree does not carry — rather than a chezmoi-managed `~/.gitconfig`.
  - **Why not managed:** three other writers already own parts of that file (`gh`
    writes the credential helpers, `vp` writes its merge driver, and `git config
    --global` writes on any manual change), so a declarative copy would fight all
    three forever. It would also be dangerous: this user's git identity is
    deliberately **per-host** (nine distinct author emails across the public
    history), and a managed file carrying a hardcoded `[user] email` would silently
    re-attribute commits on every machine at the next apply. Owning only five keys
    removes that hazard entirely — the rest of the file is never read or restated.
  - **Idempotent:** `git config --global <key> <value>` replaces in place, so
    re-running never duplicates a line or a section.
  - **Ordering is a safety property.** The keys are set only *after* `install_bin`
    succeeds. `core.pager = delta` with no delta on PATH does not degrade — `git
    diff` dies with `fatal: unable to execute pager 'delta'` and exit 128, printing
    no diff at all; an unset-less `interactive.diffFilter` likewise breaks
    `git add -p` with "mismatched output from interactive.diffFilter". A
    pre-existing non-delta `core.pager` is overwritten (that is the point) but is
    reported on stderr rather than silently swallowed.
  - **Teardown is a special case, not a `for b in …` loop entry**, since
    `remove_bin` knows nothing about git config — and it is *conditional*. See
    the reconcile below.
- **`df_delta_gitconfig_reconcile` (`lib/df-common.sh`) owns removing those keys.**
  One rule — *"if delta cannot run, drop the five keys; otherwise leave them"* —
  with **one implementation and two call sites**, so the two paths cannot drift
  apart about what "delta is available" means:
  1. **`./doctor`**, the once-per-login health check (`rc.sh` runs
     `dotfiles-doctor` once per login session era), so a machine whose delta went
     away self-heals.
  2. **`update-user-home-dir.sh --uninstall --force`**, immediately *after*
     `remove_bin delta`.
  - **The predicate is OPERABILITY, not presence**: `delta --version`, never
    `command -v delta` and never `df_have`. delta is the one fetcher with a gnu
    fallback on architectures with no musl build, so *present-but-not-runnable* is
    a real state for it — wrong glibc, dangling symlink, cross-arch ELF.
    `command -v` reports success for all of those and would leave `core.pager`
    aimed at a binary that cannot execute, which is exactly the breakage the
    reconcile exists to prevent. The harness pins this with a stub that **exists
    and is executable but exits non-zero**; that assert fails the moment anyone
    "simplifies" the predicate.
  - **A system-packaged delta is a legitimate delta.** If one still runs after
    ours is gone, the wiring is still valid and is left alone. This is why
    uninstall does not unset unconditionally.
  - **Ordering is load-bearing in uninstall:** the reconcile runs *after*
    `remove_bin delta`. Checking first would find our own binary still on PATH,
    always conclude "keep", and never clean the wiring — a bug that looks exactly
    like the feature working.
  - **Surgical:** `--unset core.pager`, `--unset interactive.diffFilter`,
    `--remove-section delta`, each guarded with `|| true` and its stderr
    suppressed (`--unset` on an absent key exits 5, `--remove-section` on an
    absent section exits 128, and both callers run under `set -e`). It **never**
    does `--remove-section core` or `--remove-section interactive`: the user keeps
    unrelated settings in both (`excludesfile`, `singleKey`, …). Only `[delta]` is
    ours end to end.
  - **Silence:** nothing to remove ⇒ completely silent. Keys actually removed ⇒
    exactly one informational line, because silently rewriting a user's global git
    config is worse than saying so.
  - **No locking needed:** `rc.sh` gates the greet behind a `set -C` stamp in
    `$XDG_RUNTIME_DIR`, so exactly one shell per login session reaches it. A lost
    race degrades to "heals next session", never to an error.
  - **Note the character change:** `./doctor` was a read-only health *report*.
    This makes it mutate state in one narrow case (five keys we set ourselves,
    only when their target is broken). That is deliberate and is **not** licence
    for other checks to start self-healing.
  - **Not covered:** nothing re-adds the keys if a *system* delta later appears on
    a machine where the fetcher never ran. The fetcher owns setting them. A
    considered omission, not an oversight.
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

- **tsh / tctl** (slot **22**) are the Teleport client tools, and this slot
  inverts four rules the others establish — read the file's own header before
  changing it. It makes **no GitHub API call at all** (Teleport publishes on
  `cdn.teleport.dev`), so it is the only fetcher that cannot be rate-limited.
  It pins the version to the **cluster**, not to upstream latest, by reading
  `auto_update.tools_version` from `https://<proxy>/v1/webapi/find`; a client
  matching its own proxy avoids `tsh`'s version-skew warnings by construction,
  and being unable to read it is a hard failure rather than a hardcoded
  fallback, which would quietly stage the skewed client the pinning exists to
  prevent. **`fb_arch` is correct here** — the opposite of slots 17–21 —
  because Teleport names assets `amd64`/`arm64`, exactly what `fb_arch` emits;
  "correcting" it to raw `uname -m` 404s on arm64 and is invisible from x86_64.
  And `version` is a **subcommand**: `tsh --version` is a hard error, so that
  argv is what `install_bin` receives.

  Two behaviours are specific to this slot:
  - **It defers to a system-wide `tsh`.** Teleport's vendor installer writes
    `/usr/local/bin/tsh`, and a box provisioned that way needs nothing from us
    — a second copy in `~/.local/bin` would only *shadow* it, since the env
    layer puts `~/.local/bin` first. The check is `fb_system_bin`, not a bare
    `command -v`: `fb_init` puts `$BIN_DIR` on `PATH`, so `command -v tsh`
    finds **our own symlink** and the fetcher would skip forever after its
    first install. `fb_system_bin` strips `$BIN_DIR`, rejects anything
    resolving into `$APP_DIR`, and probes **operability** rather than presence.
    `TSH_FETCH_FORCE=1` overrides the deferral.
  - **It checks the installed version before downloading.** The asset is
    ~207 MB — the whole Teleport suite, of which only `tsh` and `tctl` are
    extracted — and the installer runs every fetcher on every Phase-5 pass.
    Leaving that decision to `install_bin` would re-pull a fifth of a gigabyte
    each run only to be told "already valid". Same reasoning as the versioned
    ghostty AppImage in slot 16.

  It installs **no completions**, deliberately: `tsh --completion-script-zsh`
  emits a `#compdef` directive with no command name and a function named
  literally `_`, which zsh either ignores or loads as a garbage completer,
  silently either way. That is worse than bat's rename trap, so the honest
  move is to ship none.

- **op** (slot **23**) is the 1Password CLI (v2). It uses the official
  AgileBits CDN (`cache.agilebits.com`) with a predictable URL pattern.
  Default version is 2.39.0 (`OP_FETCH_VERSION=2.x.y` overrides). It
  downloads `op_linux_amd64_vX.Y.Z.zip` (a single static binary), extracts
  it with `fb_unzip`, and installs via `install_bin`.

  **It defers to a system-wide `op`.** The distro/AUR package is named
  `1password-cli` and writes `/usr/bin/op` already setgid `onepassword-cli`.
  A second copy in `~/.local/bin` would only *shadow* it, and a fetch.bins
  copy is user-owned 0755 — the desktop app then resets CLI IPC. The check
  is `fb_system_bin`, not a bare `command -v` (same trap as slot 22).
  `OP_FETCH_FORCE=1` overrides the deferral.

  After a user-local `install_bin` it checks that the binary is **setgid
  `onepassword-cli`**. The 1Password desktop app authenticates Linux CLI
  IPC by that GID and resets the connection otherwise (`connecting to
  desktop app: read: connection reset`). Fetchers are rootless, so if the
  bit is missing the fetcher tries `chgrp`/`chmod` without sudo, then
  prints the two `sudo` commands and continues — the binary is installed,
  just not usable for app integration until those run. A later re-fetch
  recopies the file and strips setgid, so the check runs every time,
  including the "already valid" skip. `./doctor` reports `NEED` on the
  same predicate (`df_op_linux_sgid_ok` in `lib/df-common.sh`).

## chezmoi source layout (`home/`)
- Attribute-encoded names: `dot_*`, `private_*` (e.g. `private_dot_ssh` → 0700),
  `executable_*`, `symlink_*` (a text file holding the link target), `empty_*` (so
  0-byte files are not silently dropped).
- `home/.chezmoiignore` keeps repo docs (`doc/`) out of `~`.
- Config lives at `~/.config/chezmoi/`; the installer passes `--source`/`--destination`
  explicitly, so no in-repo `.chezmoi.toml` is required.

See `doc/chezmoi.md` for the source-layout encoding, apply/uninstall, and the
migration gotchas; `doc/ssh-agent.md` for the systemd user ssh-agent details.
