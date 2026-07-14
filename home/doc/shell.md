# Shell configuration (`~/.config/shell/`)

bash and zsh share **one** source of truth. `~/.bashrc` and `~/.zshrc` are thin
stubs that do two things — guard against non-interactive shells, then source
`~/.config/shell/rc.sh` by absolute path. Nothing else lives in them.

## Layout

| File | Role |
|---|---|
| `rc.sh` | The only entry point. Detects the shell, then sources everything below in order. |
| `lib.sh` | Helpers (`have`, `path_prepend`, `source_dir`) plus the dotfiles-awareness registry and `dotfiles-doctor`. |
| `common.sh` | **The source of truth.** Anything not genuinely shell-specific goes here. |
| `bash.sh` | bash-only delta: `shopt`, history vars, PS1 fallback, bash-completion. |
| `zsh.sh` | zsh-only delta: `setopt`, `HISTFILE`/`SAVEHIST`, `bindkey -v`. |
| `local.d/*.sh` | Host-local drop-ins. **Not managed by chezmoi** — see below. |
| `~/.config/bashrc.d/*.sh` | Shared drop-ins sourced by both shells (the ssh-agent setup). |

## Load order (it is load-bearing)

```
lib → common → <shell>.sh → bashrc.d/ → local.d/ → [zsh only] compinit
```

`compinit` runs **last** because `local.d/` may extend `$fpath` (the grok
completions do). Initialising completions before that point silently drops them.

## Why so little is shell-specific

Most tool integrations take the shell's name as an argument, so they parameterize
cleanly and live in `common.sh`:

```sh
have starship && eval "$(starship init "$DOTFILES_SHELL")"
have fzf      && eval "$(fzf --"$DOTFILES_SHELL")"
have tv       && eval "$(tv init "$DOTFILES_SHELL")"
```

`$DOTFILES_SHELL` is `bash` or `zsh`, set by `rc.sh` from `$BASH_VERSION` /
`$ZSH_VERSION`. Those are the reliable signals: `$SHELL` is the *login* shell
(wrong inside a nested shell) and `$0` varies with how the shell was invoked.

What is genuinely shell-specific is small: history mechanisms (`HISTCONTROL` +
`shopt` vs `HISTFILE`/`SAVEHIST` + `setopt`), completion systems
(`bash_completion` vs `compinit`), keybindings, and the PS1 fallback.

**Portability rules for `common.sh` and `lib.sh`:** POSIX constructs only — no
bash arrays, no zsh glob qualifiers. `local` is fine (both shells have it). Note
that zsh *aborts* on a glob matching nothing while bash leaves the pattern
unexpanded; `source_dir` sets `null_glob` under zsh to paper over the difference.

## Host-local config: `local.d/`

`~/.config/shell/local.d/*.sh` is for things only one machine needs. chezmoi does
not manage it, so `chezmoi apply` will not touch it.

**This is where installer-appended blocks must go.** An installer that appends to
`~/.bashrc` or `~/.zshrc` (grok does exactly this) will have its block **destroyed
by the next `chezmoi apply`**, because those files are now managed stubs. The grok
PATH + completions block lives in `local.d/50-grok.sh` for precisely that reason.

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
`NN_` prefix, so renumbering a fetcher does not silently rot the table. The stem
is usually the command, but not always — `rg` ships from `ripgrep.sh` and `cargo`
from `rust.sh`, which is why the registry maps command → stem explicitly.

`DOTFILES_SHELL_VERBOSE=1` prints that report at every shell start.

## Bugs this structure fixed

- **Relative source.** The old `~/.bashrc` ran `source .bashrc-debian` — a
  relative path — so bash started anywhere other than `$HOME` silently loaded
  *none* of the config. Every path in `rc.sh` is now absolute, and a test probes
  an interactive shell from `/tmp` to keep it that way.
- **Wrong ssh-agent socket.** `~/.bashrc` hardcoded
  `$XDG_RUNTIME_DIR/ssh-agent.socket` and ran *after* `10-ssh-agent.sh` had
  correctly set `$XDG_RUNTIME_DIR/openssh_agent` (the path the systemd unit's
  `ListenStream` actually creates), clobbering the good value. `ssh-add -l` failed
  with "Error connecting to agent". The stub no longer sets `SSH_AUTH_SOCK` at
  all; the shared drop-in owns it.
- **Duplicate PATH entries.** Nothing deduped, so re-sourcing stacked entries
  (`~/.grok/bin` appeared twice). `path_prepend` skips anything already present.
- **A lying diagnostic.** zsh printed "broot is not installed locally" when broot
  *was* installed — it was checking for the `br` launcher shim, and sourcing the
  **bash** launcher under zsh. `common.sh` sources the per-shell launcher, and
  `dotfiles-doctor` distinguishes "no binary" from "no shim".
- **Two bashrc files.** `.bashrc-debian` and `.bashrc-arch` differed by exactly
  one alias. `.chezmoiremove` deletes the stale copies from every machine.
