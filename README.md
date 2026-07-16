# dotfiles

Self-bootstrapping, test-covered dotfiles for a Linux desktop — managed with
[chezmoi](https://www.chezmoi.io/), with a layered shell, a cross-distro
toolchain installer, and **age-encrypted secrets that are safe to keep in a
public repo**.

One `git pull` and one script takes a freshly provisioned machine to a working,
fully configured state — editor, prompt, window manager, CLI tools, SSH agent,
and secrets — with nothing to install by hand first.

```bash
git clone https://github.com/<you>/dotfiles.git
cd dotfiles
./update-user-home-dir.sh
```

That's the whole bring-up. The script fetches its own tools, lays down every
config file, and wires up the rest. It's idempotent — run it again any time to
converge back to a known state.

---

## From GNU Stow to chezmoi

This repo started life as a pile of symlinks managed by [GNU Stow](https://www.gnu.org/software/stow/).
Stow is elegant for what it does — symlink-farm a `package/` into `$HOME` — but a
real multi-machine setup keeps bumping into its edges:

- **No templating.** One host wants a slightly different `.gitconfig`; Stow has
  no answer but a second copy.
- **No file modes.** A `0600` SSH config or an executable hook is just a symlink
  to a repo file; permissions live outside the model.
- **No secrets story.** Anything sensitive is either symlinked in the clear or
  left out entirely.
- **Symlinks, not files.** Some tools misbehave when their config is a symlink
  into a git checkout.

**chezmoi** replaces all of that with a single source tree under [`home/`](home/),
where each file's name *encodes* its target and attributes — `dot_zshrc` →
`~/.zshrc`, `private_dot_ssh/` → `~/.ssh/` at `0700`, `executable_*` for scripts,
`encrypted_*` for secrets, `symlink_*` for the few things that genuinely want to
be links. `chezmoi apply` renders real files with the right modes, so nothing in
`$HOME` is a dangling link into the repo. Templating, per-host data, and
first-class encryption come along for free.

The migration is documented in [`home/doc/chezmoi.md`](home/doc/chezmoi.md).

---

## What makes it interesting

Most of the engineering here is invisible when it works — which is exactly why
it's worth writing down.

### A self-bootstrapping, cross-distro toolchain

A fresh box rarely has the tools this config assumes (`fzf`, `ripgrep`, `nvim`,
`starship`, a Go toolchain, …). Rather than lean on whatever the distro packages,
the installer fetches pinned static binaries straight from upstream releases into
`~/.local/bin`, via small scripts in [`home/dot_local/bin/fetch.bins/`](home/dot_local/bin/fetch.bins/)
that share a hardened [`_lib.sh`](home/dot_local/bin/fetch.bins/) (verify-before-symlink,
versioned installs, fail-loud).

The install runs in **six ordered phases**:

```mermaid
flowchart LR
    A["1 · jq<br/>(jq-free bootstrap)"] --> B["2 · chezmoi"]
    B --> C["3 · secrets<br/>(age + key)"]
    C --> D["4 · chezmoi apply"]
    D --> E["5 · tool fetchers"]
    E --> F["6 · ssh-agent"]
```

The ordering is load-bearing. `jq` comes **first** because every other fetcher
parses GitHub's release JSON with it — and `jq` bootstraps *without* `jq`, using
a `grep`/`awk` fallback, so a machine with nothing installed can still start the
chain. `chezmoi` and `age` are fetched before `apply`, because `apply` needs them
to lay down files and decrypt secrets. See [`home/doc/fetch-bins.md`](home/doc/fetch-bins.md).

### A shell config split into two layers

The subtle bug that reshaped the shell config: **PATH and exported environment
were only set for *interactive* shells.** So `bash -c`, `make`, git hooks,
`ssh host cmd`, and systemd user units all ran without `~/.local/bin` on `PATH` —
they couldn't find any of the tools above.

The fix was to split the config into an **env layer** (`PATH`, exports — read by
*every* shell, strictly POSIX so a Debian `dash` `~/.profile` can source it, and
silent so it doesn't corrupt `scp`/`rsync`) beneath an **rc layer** (aliases,
prompt, completions — interactive only). Getting that split right, and keeping
the env layer dash-safe and byte-silent, is the kind of thing you only get to do
once and then never think about again. See [`home/doc/shell.md`](home/doc/shell.md).

A `dotfiles-doctor` command reports which tools are present and the exact
installer for anything missing — and it greets you **once per login session**
(a tmpfs stamp under `$XDG_RUNTIME_DIR`, created atomically so ten tmux panes
opening at once produce exactly one greeting).

### Secrets that live safely in a public repo

API keys and tokens live in `~/.keys`, which the shell sources. In a public repo
that can never be committed in the clear — so it isn't. `~/.keys` is stored as an
[**age**](https://github.com/FiloSottile/age)-encrypted blob
(`home/encrypted_private_dot_keys.age`) and decrypted on `chezmoi apply`. The one
secret that *can't* live in the repo — the age private key — never does: it sits
at `~/.config/chezmoi/key.txt` (`0600`), mirrored in 1Password, and the installer
fetches it automatically on a new machine (or tells you how). A clone **without**
the key still applies cleanly; it just has no secrets until the key lands.

Day-to-day, there's one command to remember:

```bash
dotfiles-keys          # edit ~/.keys decrypted; re-encrypt + apply on save
dotfiles-keys status   # is the key present? is ~/.keys decrypted?
```

The full model — including key rotation and the honest threat model — is in
[`home/doc/secrets.md`](home/doc/secrets.md).

### It's tested

The whole bootstrap runs against an **integration test suite**
([`test-update-user-home-dir.sh`](test-update-user-home-dir.sh)) in a throwaway sandbox
`$HOME` — **~95 checks offline, ~118 with live network fetches**. It proves the
phase ordering, that `jq` truly bootstraps without `jq`, that PATH reaches
non-interactive shells, that startup is byte-silent (the `scp`-safety invariant),
that a keyless machine applies cleanly, and a full age encrypt → apply → `0600`
round-trip. Dotfiles you can refactor without fear.

---

## Layout

| Path | What |
|---|---|
| [`home/`](home/) | The chezmoi source tree (attribute-encoded names). |
| `home/dot_config/shell/` | The two-layer shell config (`env.sh` + `rc.sh`, plus per-shell deltas). |
| [`home/dot_local/bin/fetch.bins/`](home/dot_local/bin/fetch.bins/) | Per-tool release fetchers + the shared `_lib.sh`. |
| `home/dot_config/` | Hyprland / sway / i3, waybar / wofi / rofi / mako, alacritty / kitty, nvim, starship, tmux, … |
| `home/private_dot_ssh/` | SSH config + host data (rendered at `0700`/`0600`). |
| [`home/doc/`](home/doc/) | Deep-dive docs (see below). |
| [`update-user-home-dir.sh`](update-user-home-dir.sh) | The bootstrap installer. |
| [`test-update-user-home-dir.sh`](test-update-user-home-dir.sh) | The integration test suite. |

## Documentation

| Doc | Covers |
|---|---|
| [`chezmoi.md`](home/doc/chezmoi.md) | The Stow→chezmoi migration and source-tree conventions. |
| [`fetch-bins.md`](home/doc/fetch-bins.md) | The bootstrap installer and the toolchain fetchers. |
| [`shell.md`](home/doc/shell.md) | The env/rc layering and the bugs it fixed. |
| [`secrets.md`](home/doc/secrets.md) | The age-encrypted secrets model. |
| [`ssh-agent.md`](home/doc/ssh-agent.md) | The systemd user ssh-agent with socket activation. |

## Running the tests

```bash
./test-update-user-home-dir.sh            # structural + light network
./test-update-user-home-dir.sh --no-net   # structural only (needs chezmoi on PATH)
./test-update-user-home-dir.sh --go --rust  # also exercise the heavy toolchains
```

Everything runs in an isolated sandbox `HOME`; it never touches your real `~`.

## Uninstall

```bash
./update-user-home-dir.sh --uninstall           # preview
./update-user-home-dir.sh --uninstall --force   # actually remove
```

---

These are personal dotfiles, shared as a reference for anyone building something
similar. Fork freely; the interesting parts are the docs.
