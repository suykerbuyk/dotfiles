# chezmoi in this dotfiles repo

This repo's `home/` directory **is a chezmoi source tree**. Dotfiles are applied
with chezmoi (GNU Stow was retired). This doc explains the layout and the
gotchas that bit the initial migration, so they don't bite again.

See also `home/doc/fetch-bins.md` for the installer/bootstrap flow.

## Source layout: attribute-encoded names

chezmoi does not store files under their literal target names. Each entry's name
encodes the target name **and** its attributes. In this repo:

| Source (`home/…`) | Applied to `~` | Meaning |
|---|---|---|
| `dot_zshrc` | `~/.zshrc` | leading-dot components → `dot_` (every level) |
| `dot_config/starship.toml` | `~/.config/starship.toml` | nested dirs encode too |
| `private_dot_ssh/private_config` | `~/.ssh/config` (dir `0700`) | `private_` → owner-only perms |
| `executable_tm` | `~/.local/bin/tm` (`0755`) | `executable_` → +x on apply |
| `symlink_nvim` | `~/.config/nvim` → `nvim-kickstart-modular` | a **regular file** whose contents are the link target |
| `private_empty_keep.me` | `~/.ssh/hosts/keep.me` (empty) | `empty_` → keep 0-byte files |

Attribute prefixes stack in a fixed order, e.g. `private_empty_keep.me`.

### Why `cp -a` cannot build the source
A plain dotfile tree copied into the source dir does **not** work: chezmoi
**ignores every source entry whose name begins with `.`** (that namespace is
reserved for `.chezmoiignore`, `.chezmoiroot`, …). So `cp -a ~/.zshrc source/`
lands `.zshrc`, which chezmoi silently skips. Real dotfiles must be `dot_zshrc`.
Build/extend the source with `chezmoi add <path>` (which encodes names correctly)
or `chezmoi re-add` — never a raw copy.

### Empty files vanish without `empty_`
chezmoi removes (does not create) a target whose source content is empty, unless
the source name carries `empty_`. A 0-byte or whitespace-only tracked file will
**silently disappear** on apply otherwise. The migration hit this on
`~/.ssh/hosts/keep.me`; the test harness guards against a regression.

### Exclusions
`home/.chezmoiignore` lists target paths chezmoi should not apply (here: `doc/`,
so repo docs don't leak into `~/doc`). The machine-specific broot launcher
(`.config/broot/launcher/bash/br`, an absolute symlink) is simply not tracked.

## Bootstrap order: fetch → apply → fetch tools

Because script names are encoded (`executable_01_fetch.jq.sh`), the fetch scripts
are **not runnable in place** from the checkout. `update-user-home-dir.sh` therefore:

1. fetches the chezmoi static binary,
2. `chezmoi apply --force` — lays down dotfiles *and* the `~/.local/bin` tooling
   with decoded names,
3. runs the tool fetchers from the now-populated `~`,
4. sets up the ssh-agent (guarded by a session-bus check).

### `apply --force` is required for scripted runs
`chezmoi apply` is **interactive by default**: if a target changed since chezmoi
last wrote it, it prompts (`overwrite/skip/…`) and, non-interactively, aborts
mid-apply. Always pass `--force` in scripts.

### Persistent state
chezmoi keeps state (`chezmoistate.boltdb`) and config under
`~/.config/chezmoi/` — **not** in the destination. Tests isolate it with
`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` overrides so they never touch the real one.

## Common commands

```bash
# apply this repo's source into ~ (what the installer does)
chezmoi --source ~/dotfiles/home --destination ~ apply --force

chezmoi --source ~/dotfiles/home status     # what would change (empty = in sync)
chezmoi --source ~/dotfiles/home managed    # every path chezmoi manages
chezmoi add ~/.config/newapp/config         # bring a new file into the source (encodes the name)
```

### Uninstall
`./update-user-home-dir.sh --uninstall` previews by default; add `--force` to act.
It removes chezmoi-**managed** files from `~` (via `chezmoi managed`), removes the
fetched tools (`remove_bin`), and clears `~/.config/chezmoi`. It never touches the
repo source. (Note: `chezmoi purge` wipes chezmoi's own dirs and takes no per-file
target; `chezmoi destroy <path>` removes a single file from both `~` and source —
know which you want.)

## Migration from stow
Before: `stow -R -d ~/dotfiles -t ~ home` symlinked plain-named files into `~`.
Now: the same files live under `home/` with encoded names and are applied as real
files (chezmoi). `~/.ssh` now gets a true `0700` (stow could not enforce mode).
The one-time switch just runs the installer; `chezmoi apply` replaces the old stow
symlinks with managed files.

## Tests
`./test-update-user-home-dir.sh` runs the full suite in an isolated sandbox HOME
(never the real `~`): apply parity vs `git ls-tree`, idempotency, the `empty_`/
`private_`(0700) guards, the installer dry-run (all phases + no repo
contamination), and the fetch/uninstall paths. `--go` adds the 150 MB Go fetch
(GOROOT check); `--no-net` runs structural-only.
