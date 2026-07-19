# Shell configuration (`~/.config/shell/`)

bash and zsh share **one** source of truth, split into two layers. The split is
the load-bearing idea, so it comes first.

## Two layers: env and rc

**PATH and exported variables are environment, not interactive state.** A `make`
recipe, a git hook, `ssh host cmd`, a systemd user unit, and anything Hyprland
launches all need `~/.local/bin` on PATH just as much as a terminal does. So they
live in an **env layer** that *every* shell reads, below an **rc layer** that only
interactive shells reach.

| Layer | Files | Read by | Holds |
|---|---|---|---|
| **env** | `env.sh` (+ `lib.sh`, `env.d/`) | **every** shell | PATH, `GOPATH`, `EDITOR`, `NVM_DIR`, `SSH_AUTH_SOCK`, … |
| **rc** | `rc.sh` → `common.sh`, `<shell>.sh`, `doctor.sh`, `local.d/` | interactive only | aliases, prompt, completions, `~/.keys`, the `nvm` function |

The rule for what goes where: **if a script spawned by a tool would want it, it is
env-layer.** An `export` almost always is. An alias never is.

### Entry points

The env layer is reached from four places, so no shell can miss it:

| File | Read by | Does |
|---|---|---|
| `~/.zshenv` | **every** zsh — `zsh -c`, `ssh host cmd`, scripts | `. env.sh` |
| `~/.profile` | POSIX login shells (`sh`/`dash`), display managers | `. env.sh` |
| `~/.bash_profile` | bash login shells | `. ~/.profile`, then `. ~/.bashrc` |
| `~/.bashrc` | interactive bash + `ssh host cmd` | `. env.sh` **above** the gate, then `. rc.sh` |
| `~/.zshrc` | interactive zsh | `. rc.sh` |
| `~/.config/environment.d/10-dotfiles.conf` | `systemd --user`, `.desktop` launchers | static PATH |

`~/.bash_profile` must source `~/.profile` explicitly, because bash reads
`~/.bash_profile` *instead of* `~/.profile` when it exists. And `~/.bashrc` sources
`env.sh` **above** its `case $- in *i*)` interactivity gate — that ordering is the
whole fix, since bash reads `~/.bashrc` (and nothing else) for the shell it spawns
for `ssh host cmd`.

### The `bash -c` residual

A bare `bash -c` reads **no** startup file — only `$BASH_ENV`, which this repo
deliberately does **not** set (it would fire for every `#!/bin/bash` script on the
box). `bash -c` works anyway because it *inherits* PATH from a parent that finally
has one. The only case that stays broken is `env -i bash -c`, which strips the
environment first — but that arises only when the ancestor was already broken,
which is what the env layer fixes. A test pins this reasoning so nobody "fixes" it
by reaching for `BASH_ENV`.

zsh has no equivalent gap: `~/.zshenv` is read for *every* zsh, `-c` included.

## Layout

| File | Layer | Role |
|---|---|---|
| `env.sh` | env | PATH, exports, the ssh-agent fast path. POSIX, silent, fork-free. |
| `lib.sh` | env | Helpers `df_have`, `path_prepend`, `source_dir`. |
| `rc.sh` | rc | The interactive entry point. Detects the shell, sources everything below. |
| `common.sh` | rc | Shared interactive config: aliases, prompt tools, `~/.keys`, `nvm`. |
| `bash.sh` | rc | bash-only delta: `shopt`, history vars, PS1 fallback, bash-completion. |
| `zsh.sh` | rc | zsh-only delta: `setopt`, `HISTFILE`/`SAVEHIST`, `bindkey -v`. |
| `doctor.sh` | rc | `dotfiles-doctor` and its registry (hyphenated name — see below). |
| `env.d/*.sh` | env | Host-local PATH/exports. **Not managed by chezmoi.** |
| `local.d/*.sh` | rc | Host-local aliases/completions/`$fpath`. **Not managed by chezmoi.** |
| `~/.config/bashrc.d/*.sh` | rc | Shared drop-ins sourced by both shells (the ssh-agent setup). |

## Load order (it is load-bearing)

```
env layer   lib → env.sh → env.d/
rc  layer   env.sh (again, no-op) → common → <shell>.sh → doctor → bashrc.d/ → local.d/ → [zsh] compinit → tool-init → greet
```

Three invariants inside that order:

- **`compinit` runs last** *of the completion setup*, because `local.d/` may extend
  `$fpath` (the grok completions do). Initialising completions before that point
  silently drops them.
- **Tool completion inits run *after* `compinit`.** `starship`/`fzf`/`tv` are eval'd
  from `dotfiles_tool_init` (defined in `common.sh`), which `rc.sh` calls only after
  the `compinit` step. `tv init` ends with an unguarded `compdef _tv tv`, and
  `compdef` does not exist until `compinit` has defined it — running the inits inline
  in `common.sh` printed `(eval):230: command not found: compdef` on every login zsh.
- **`env.sh` is idempotent.** A login shell runs it via `~/.bash_profile` →
  `~/.profile`; `rc.sh` then sources it again defensively. A non-exported
  `DOTFILES_ENV_LOADED` guard makes the second call a no-op, while each *new* shell
  still re-derives from its own `$HOME`.

## POSIX, silence, and the hyphen

The env layer is sourced from `~/.profile`, which on Debian is **dash**. So `env.sh`
and `lib.sh` are strictly POSIX: no bash arrays, no zsh glob qualifiers, no `[[ ]]`,
no `local`, **and no hyphen in a function name** — dash rejects `foo-bar()` as a
syntax error. That last one is why `dotfiles-doctor` lives in `doctor.sh` (rc layer)
and not in `lib.sh`: if the env layer sourced a hyphenated function under dash, it
would break the login shell.

The env layer must also be **silent**. `~/.zshenv` runs for every zsh, including the
one `scp`, `sftp`, and `rsync` spawn on the remote side — and those parse the stream
as protocol, so a single stray character breaks file transfer outright. A test
asserts `zsh -c true` emits nothing.

## The fetch/PATH rule

```
A binary we FETCH → symlinked into ~/.local/bin (install_bin). One PATH entry covers all.
A bin dir a MANAGER owns → goes on PATH directly.
```

`install_bin` symlinks a fixed binary out of a release archive (`go`, `gofmt`, `rg`,
`fzf`, `nvim`, `starship`…), so a single `~/.local/bin` entry reaches every one. It
**cannot** work for a directory a package manager keeps writing to: `cargo install`
and `rustup component add` add binaries to `~/.cargo/bin`, and `go install` adds them
to `$GOPATH/bin`, both *after* install time. A symlink set captured once would go
stale the first time you ran either. Those directories go on PATH in `env.sh`.

## Host-local config: `env.d/` and `local.d/`

Two directories, one per layer, for things only one machine needs. chezmoi manages
neither, so `chezmoi apply` never touches them.

- **`env.d/*.sh`** — host-local PATH and exports (env layer). A PATH mutation goes
  here so non-interactive shells see it. `path_prepend` is idempotent, so it is safe
  to re-source.
- **`local.d/*.sh`** — host-local aliases, completions, `$fpath` (rc layer, before
  `compinit`).

**This is where installer-appended blocks must go.** An installer that appends to
`~/.bashrc` or `~/.zshrc` (grok does exactly this) will have its block **destroyed by
the next `chezmoi apply`**, because those files are managed stubs. The grok block is
split accordingly: its `path_prepend "$HOME/.grok/bin"` lives in `env.d/50-grok.sh`,
its completions/`fpath` line in `local.d/50-grok.sh`. The `fpath=(…)` line in
particular *cannot* be re-sourced (it stacks duplicates), which is the concrete
reason the two directories are separate rather than one sourced from both layers.

## Dotfiles awareness — `dotfiles-doctor`

Startup is **silent by design**. Rather than nag on every shell start, the config
knows how this repo provisions tools and reports on demand:

```
$ dotfiles-doctor
  starship  ok    /home/johns/.local/bin/starship
  fzf       ok    /home/johns/.local/bin/fzf
  broot     ok    /home/johns/.local/bin/broot
  broot     note  binary present, but the `br` shim is missing → run: broot --install
  tv        n/a   not provisioned by fetch.bins
  keychain  n/a   superseded by ~/.config/bashrc.d/10-ssh-agent.sh
```

A missing tool names the exact installer that fixes it. The installer path is
resolved by **globbing** `fetch.bins/*_fetch.<stem>.sh` rather than hardcoding the
`NN_` prefix, so renumbering a fetcher does not silently rot the table. The stem is
usually the command, but not always — `rg` ships from `ripgrep.sh` and `cargo` from
`rust.sh`, which is why the registry maps command → stem explicitly.

### The once-per-session greeting

The report also runs **automatically, once per login session era**: the first
interactive shell after you log in prints it; every shell after that (new tmux
panes, splits, subshells) stays silent. The one-shot is a stamp file,
`$XDG_RUNTIME_DIR/dotfiles-shell.greeted`:

- `$XDG_RUNTIME_DIR` is `/run/user/$UID`, a **tmpfs** systemd-logind creates at your
  first login and **removes when your last session ends** — so the greeting resets
  on a full logout and on reboot, with no cleanup code of our own.
- The create is done under `set -C` (noclobber) in a subshell, which is **atomic**:
  when several panes open simultaneously, exactly one wins the create and prints.
- If `$XDG_RUNTIME_DIR` is unset (a non-systemd host, some containers), the one-shot
  simply does not fire — startup stays silent, and `dotfiles-doctor` is still there
  on demand.
- Caveat: with `loginctl enable-linger` set for your user, logind keeps the runtime
  dir across a full logout, so the greeting then resets only on reboot.

`DOTFILES_SHELL_VERBOSE=1` forces the report on **every** shell start instead.

## Bugs this structure fixed

- **Non-interactive shells had no PATH.** PATH lived in `common.sh`, reachable only
  through the `~/.bashrc`/`~/.zshrc` interactivity gate — so `bash -c`, `make`, git
  hooks, `ssh host cmd`, systemd units, and even `bash -lc` (a *login* shell!) ran
  without `~/.local/bin`, `~/.cargo/bin`, or `$GOPATH/bin`. Splitting PATH into an
  env layer with its own entry points (`~/.zshenv`, `~/.profile`, `~/.bash_profile`,
  and `~/.bashrc` above its gate) fixed it; tests probe `-c`/`-lc` from a stripped
  `env -i` to keep it fixed.
- **Relative source.** The old `~/.bashrc` ran `source .bashrc-debian` — a relative
  path — so bash started anywhere other than `$HOME` silently loaded *none* of the
  config. Every path is now absolute, and a test probes an interactive shell from
  `/tmp` to keep it that way.
- **Wrong ssh-agent socket.** `~/.bashrc` hardcoded `$XDG_RUNTIME_DIR/ssh-agent.socket`
  and ran *after* `10-ssh-agent.sh` had correctly set `$XDG_RUNTIME_DIR/openssh_agent`,
  clobbering the good value. `ssh-add -l` failed with "Error connecting to agent". The
  env layer now sets the socket from the systemd unit's path; the shared drop-in owns
  the fork-heavy fallbacks.
- **Duplicate PATH entries.** Nothing deduped, so re-sourcing stacked entries
  (`~/.grok/bin` appeared twice). `path_prepend` skips anything already present.
- **A lying diagnostic.** zsh printed "broot is not installed locally" when broot
  *was* installed — it was checking for the `br` launcher shim, and sourcing the
  **bash** launcher under zsh. `common.sh` sources the per-shell launcher, and
  `dotfiles-doctor` distinguishes "no binary" from "no shim".
- **Two bashrc files.** `.bashrc-debian` and `.bashrc-arch` differed by exactly one
  alias. `.chezmoiremove` deletes the stale copies from every machine.
