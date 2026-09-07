# dotfiles

Self-bootstrapping, test-covered dotfiles for a Linux desktop — managed with
[chezmoi](https://www.chezmoi.io/), with a layered shell, a cross-distro
toolchain installer, and **age-encrypted secrets that are safe to keep in a
public repo**.

One `git pull` and one script takes a freshly provisioned machine to a working,
fully configured state — editor, prompt, window manager, CLI tools, SSH agent,
and secrets — with nothing to install by hand first.

```bash
git clone https://github.com/suykerbuyk/dotfiles.git
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

A `./doctor` command (also `dotfiles-doctor` on `PATH` after apply) reports
which tools are present and the exact installer for anything missing — and the
interactive shell greets you with that report **once per login session**
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

### SSH keys that work without the 1Password GUI

Almost every private key here lives in 1Password, not on disk — **zero plaintext
private keys**, and the one key that is on disk is passphrase-encrypted. That's
comfortable on a desktop, where the 1Password app serves its own SSH agent and
approves each signature. It's a problem everywhere else: a headless box, an
inbound SSH session, or WSL on a laptop where you'd rather not install the app at
all.

Three mechanisms cover it, split by **direction of travel** rather than by
machine. They aren't alternatives — each handles a case the others can't.

**1 · The agent you arrived with wins.** If a shell inherits a live
`SSH_AUTH_SOCK` — a forwarded agent, a multiplexer pane — it keeps it.
1Password is the *default* for a shell that arrived with nothing, never an
override. That sounds obvious; it wasn't true here for a long time, and `ssh -A`
silently lost its forwarded agent to a local one that might be locked.

**2 · Forward the agent from a desktop that has the app.** Enabled per host in
`~/.ssh/config` — never globally, because root on the far end can use the socket
for the life of the session. Signatures then raise an approval prompt on the
desktop where you already are. For multi-hop use `ProxyJump`, never a chain of
`ForwardAgent yes`: under ProxyJump the intermediate host never sees the socket.

**3 · Pull the key from 1Password directly**, for a box with no local agent worth
forwarding:

```bash
ssh-load-keys.sh --list   # what this machine would load, contacts nothing
ssh-load-keys.sh          # op read → ssh-add, with a TTL
```

Key material goes vault → stdout → pipe → agent memory. It never touches disk,
never appears in argv, never enters the environment.

#### Populating the manifest

`ssh-load-keys.sh` reads **`~/.config/shell/ssh-keys.manifest`** — one 1Password
item UUID per line, text after the UUID is a label, `#` comments ignored.

The file is **host-local and unmanaged on purpose**: chezmoi does not sync it.
The keys a laptop needs aren't the keys a workstation needs, and this repo is
public, so which vault item unlocks which host is metadata that shouldn't be in
it. Create it per machine.

```bash
op signin                                  # no desktop app needed
op item list --categories 'SSH Key'        # ID + TITLE for every key
```

Then pick the ones *that machine actually reaches* and write them in:

```
# ~/.config/shell/ssh-keys.manifest
x6xvuvozbcxxcbtae2gxakjun4   github / primary
bs2a3qbbvj5o42ikrcxf3l47ma   digital ocean
```

Pick by **evidence, not by name**. On a host where things already work, run
`ssh-add -l` and match the fingerprint; or read the target's
`~/.ssh/authorized_keys`. Listing more keys than you need recreates the problem
below.

Then `ssh-load-keys.sh`, and expect `loaded github / primary (ttl 36000s)`.

Two things that will otherwise waste your afternoon:

- **On a desktop with the 1Password app, the loader refuses** — that agent
  rejects added keys, and it already serves the vault directly, so there's
  nothing to load. This tool is for the machines *without* it.
- **`op read` blocks on an approval prompt nobody answers.** It's bounded, so it
  fails legibly instead of hanging; raise the budget with `OP_READ_TIMEOUT` if an
  approval is just slow.

#### Offering one key, not thirteen

`IdentitiesOnly no` is OpenSSH's default, and it means ssh offers **every key the
agent holds** before touching any `IdentityFile`. Measured against a throwaway
`sshd` with the stock `MaxAuthTries 6`: an 8-key agent queued 14 candidates, got
6 offers in, and was disconnected — never reaching the authorised key. This agent
serves thirteen.

So hosts that need it pin `IdentitiesOnly yes` plus a **public** key. Naming the
`.pub` is the trick: ssh matches it against the agent and lets the *agent* sign,
so no private key needs to be on disk at all.

The full model, including the traps — `IdentityFile` is cumulative while
`IdentityAgent` and `IdentitiesOnly` are first-wins, and why the Teleport pin
must sit *above* the tsh-generated block — is in
[`home/doc/ssh-agent.md`](home/doc/ssh-agent.md).

### It's tested

The whole bootstrap runs against an **integration test suite**
([`test-update-user-home-dir.sh`](test-update-user-home-dir.sh)) in a throwaway sandbox
`$HOME` — **1263 checks offline, more with live network fetches**. It proves the
phase ordering, that `jq` truly bootstraps without `jq`, that PATH reaches
non-interactive shells, that startup is byte-silent (the `scp`-safety invariant),
that a keyless machine applies cleanly, a full age encrypt → apply → `0600`
round-trip, and — since the ssh work — that a forwarded agent survives the rc
layer and that `ssh -G` resolves the intended identity per host. New assertions
are mutation-proved: the check has to be shown failing against a broken file
before it counts. Dotfiles you can refactor without fear.

---

## Layout

### Management CLIs (repo root)

These stay in the checkout — they are **not** lifestyle tools. Run them from the
project root (`./help` or `make help` lists the same catalog).

| Command | What |
|---|---|
| [`./update-user-home-dir.sh`](update-user-home-dir.sh) | Full bootstrap / converge (jq → chezmoi → age → apply → fetchers → ssh-agent). |
| [`./apply`](apply) | Day-2 `chezmoi apply` with this repo as `--source`. |
| [`./status`](status) | `chezmoi status` + tool health rollup. |
| [`./doctor`](doctor) | Tool/env health; names the exact `fetch.bins` installer for misses. |
| [`./keys`](keys) | age-encrypted `~/.keys` workflow (`edit` / `status` / `show` / `get-key`). |
| [`./test-update-user-home-dir.sh`](test-update-user-home-dir.sh) | Integration suite (throwaway `HOME` sandbox). |
| [`./help`](help) / [`Makefile`](Makefile) | Catalog of the commands above. |
| [`lib/`](lib/) | Shared helpers + the doctor registry (not user commands). |

After `chezmoi apply`, `~/.local/bin/dotfiles-doctor` and `dotfiles-keys` are
short trampolines back into `./doctor` and `./keys` so those names work from any
directory.

### Chezmoi source and payload

| Path | What |
|---|---|
| [`home/`](home/) | The chezmoi source tree (attribute-encoded names). |
| `home/dot_config/shell/` | The two-layer shell config (`env.sh` + `rc.sh`, plus per-shell deltas). |
| [`home/dot_local/bin/fetch.bins/`](home/dot_local/bin/fetch.bins/) | Per-tool release fetchers + the shared `_lib.sh`. |
| `home/dot_local/bin/` | Lifestyle CLIs applied to `~/.local/bin` (`tm`, backups, IPMI, …). |
| `home/dot_config/` | Hyprland / sway / i3, waybar / wofi / rofi / mako, kitty / ghostty, nvim, starship, tmux, … |
| `home/private_dot_ssh/` | SSH config + host data (rendered at `0700`/`0600`). |
| [`home/doc/`](home/doc/) | Deep-dive docs (see below). |

## Documentation

| Doc | Covers |
|---|---|
| [`chezmoi.md`](home/doc/chezmoi.md) | The Stow→chezmoi migration and source-tree conventions. |
| [`fetch-bins.md`](home/doc/fetch-bins.md) | The bootstrap installer and the toolchain fetchers. |
| [`shell.md`](home/doc/shell.md) | The env/rc layering and the bugs it fixed. |
| [`secrets.md`](home/doc/secrets.md) | The age-encrypted secrets model. |
| [`ssh-agent.md`](home/doc/ssh-agent.md) | Agent selection, forwarding, and loading keys from 1Password without a GUI. |
| [`multiplexers.md`](home/doc/multiplexers.md) | tmux and herdr as peers: the shared prefix, `tm`/`hrdr`. |
| [`teleport.md`](home/doc/teleport.md) | Reaching hosts via `tsh`, and browser-less boxes via `--headless`. |

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

## License

Copyright (c) 2026 John Suykerbuyk and SykeTech LTD.

Dual-licensed under either of

- MIT license ([LICENSE](LICENSE))
- Apache License, Version 2.0 ([LICENSE](LICENSE))

at your option — `SPDX-License-Identifier: MIT OR Apache-2.0`. Both texts are in
the single root [LICENSE](LICENSE) file.

`home/dot_config/nvim-kickstart-modular/` is a fork of
[kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim) and remains under
its own upstream MIT license — see the `LICENSE.md` in that directory.
`home/dot_config/waybar/mocha.css` is the
[Catppuccin](https://github.com/catppuccin/catppuccin) Mocha palette.
