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

### The `bash -c` residual — and its second, invisible precondition

A bare `bash -c` reads **no** startup file — only `$BASH_ENV`, which this repo
deliberately does **not** set (it would fire for every `#!/bin/bash` script on the
box). `bash -c` works anyway because it *inherits* PATH from a parent that finally
has one. The only case that stays broken is `env -i bash -c`, which strips the
environment first — but that arises only when the ancestor was already broken,
which is what the env layer fixes. A test pins this so nobody "fixes" it by
reaching for `BASH_ENV`.

**That "reads no startup file" holds only when stdin is not a socket.** bash runs
`~/.bashrc` for a *non-interactive* `-c` shell when it believes a remote shell
daemon started it, and it decides that by asking whether file descriptor 0 is a
network connection (bash's `isnetconn()`), plus `$SSH_CLIENT` on builds carrying
`SSH_SOURCE_BASHRC` — **this box's bash does not carry it; measured, not assumed**.
It is additionally gated on `SHLVL < 2`. Measured, same `$HOME`, same `.bashrc`,
with an observable marker planted in `env.sh`:

| stdin | `~/.bashrc` read? |
|---|---|
| tty, `/dev/null`, or a regular file | no |
| a socket (CI, an agent harness, `ssh host cmd`) | **yes** |
| a socket with `SHLVL >= 2` | no |
| `--norc` | no |

This is not a footnote: it is the mechanism the `ssh host cmd` path *depends* on,
and it is why `~/.bashrc` sources `env.sh` above the interactivity gate. The two
readings are easy to confuse, because on a socket stdin `env.sh` runs and sets PATH
itself — so a naive "did PATH survive?" check passes either way and proves nothing.
The suite therefore asserts a **pair** with stdin pinned (`</dev/null`): PATH
*without* `~/.local/bin` must come back `MISSING` (no startup file ran), and PATH
*with* it must come back `HAS` (inheritance works). Pinning stdin is the whole
point — without it the pair measures whatever the caller's fd 0 happened to be.

The socket half is **documented but not asserted**, by ruling. An assertion for it
was written and mutation-proved, then dropped: the trigger is a bash *build*
heuristic this repo does not control, so the test needed a `python3` dependency to
open a socketpair, plus a per-machine capability probe to avoid reddening a correct
config on a build that omits the behaviour. What guards the ordering the
`ssh host cmd` path depends on is the structural assertion that `~/.bashrc` sources
`env.sh` **above** its interactivity gate.

zsh has no equivalent gap: `~/.zshenv` is read for *every* zsh, `-c` included.

## Layout

| File | Layer | Role |
|---|---|---|
| `env.sh` | env | PATH, exports, the ssh-agent fast path. POSIX, silent, fork-free. |
| `lib.sh` | env | Helpers `df_have`, `path_prepend`, `source_dir`. |
| `rc.sh` | rc | The interactive entry point. Detects the shell, sources everything below. |
| `common.sh` | rc | Shared interactive config: aliases, prompt tools, `~/.keys`, `nvm`. |
| `bash.sh` | rc | bash-only delta: `shopt`, history vars, PS1 fallback, bash-completion. |
| `zsh.sh` | rc | zsh-only delta: `setopt`, `HISTFILE`/`SAVEHIST`, `bindkey -v`, the site-functions `$fpath` entry. |
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
  silently drops them. The same rule governs the site-functions entry added in
  `zsh.sh` (below): `zsh.sh` is sourced at step 3 of the rc chain, well before
  `compinit`, which is exactly why the line lives there.
- **Tool completion inits run *after* `compinit`.** `starship`/`fzf`/`tv`/`herdr`/`broot`
  are eval'd from `dotfiles_tool_init` (defined in `common.sh`), which `rc.sh` calls
  only after the `compinit` step. `tv init` ends with an unguarded `compdef _tv tv`
  and `herdr completion zsh` ends with `compdef _herdr herdr`; `compdef` does not
  exist until `compinit` has defined it — running the inits inline in `common.sh`
  printed `(eval):230: command not found: compdef` on every login zsh.
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

### The contract is repo-wide, not env-layer-only

`lib/df-common.sh`, `lib/doctor-registry.sh` and `lib/doctor-report.sh` are bound by
the same rules for a different reason: the repo-root CLIs that source them —
`./doctor`, `./apply`, `./status` — are `#!/usr/bin/env sh`. (`./keys` sources
`df-common.sh` too, but it is `#!/usr/bin/env bash`, so the pressure comes from the
other three.)

Beyond those, **the shebang is the declaration.** Any tracked file opening
`#!/bin/sh` or `#!/usr/bin/env sh` — the root CLIs, the `dotfiles-doctor` and
`dotfiles-keys` trampolines, `tm`, `hrdr`, `preferred-login-shell`, and the rest of
`~/.local/bin` — has declared itself POSIX and is checked as such. The suite finds
that set by scanning `git ls-files` for the shebang rather than carrying a list of
filenames, so a new POSIX script is covered from its first commit and a hand-copied
inventory never goes stale.

### Enforcement: `sh -n` is not a POSIX check

Where `/bin/sh` is bash (Arch, Fedora, most rpm distros), `sh -n` is just bash's
parser wearing a hat: it accepts `a=(1 2 3)` and it accepts a hyphenated function
name. Four assertions here claimed "valid sh" through bash for months. So the suite
**discovers** a genuine POSIX shell instead — it probes `dash ash mksh posh yash sh`
in order and accepts the first whose `${BASH_VERSION}${ZSH_VERSION}` comes back
**empty**. That takes Debian's dash-as-`/bin/sh` and rejects Arch's bash-as-`/bin/sh`
per machine, with no distro guess anywhere in it. If nothing qualifies the suite
**fails** rather than skipping: a box that cannot execute the contract is the exact
state this was built to eliminate.

**A parse alone is still not enough.** `dash -n` catches array syntax and little
else — `local x=1`, `[[ ]]`, `${VAR/a/b}`, `$RANDOM` and `echo -e` all parse clean,
and three of those then *run* to exit 0 with changed behaviour. So the suite also
**sources** `env.sh`, `lib.sh` and `df-common.sh` under the real POSIX shell and
asserts three things separately: exit 0, empty stdout, empty stderr. All three are
load-bearing, and the cheapest one is not the one you would guess. `[[ ]]` under dash
exits 0 with clean stdout and shows up **only** as `[[: not found` on stderr; a stray
`echo` shows up only on stdout, which is the scp/sftp/rsync stream above; and the
exit code guards the class that prints nothing at all — a file whose last command
simply returns non-zero, which is why `env.sh` ends in `return 0 2>/dev/null || true`
rather than trailing off. Most dash errors trip both the exit code and stderr, so
those two overlap heavily; they are kept separate because when they disagree, the
disagreement is the diagnosis.

**`doctor.sh` is the positive control.** Its hyphenated `dotfiles-doctor()` must
**fail** the parse. If that assertion ever goes green the checker has lost its teeth
and every other POSIX assertion is a false green again — which is also why that file
may never migrate into the env layer.

`dash` ships in Arch's **core** repo (`pacman -S dash`) and is standard on Debian.
It is a development dependency only; nothing at runtime needs it.

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

## Completion *files*: the site-functions scheme

`dotfiles_tool_init` (next section) can only carry tools that **print** a snippet
to stdout. fetch.bins slots 18–21 (`fd`, `bat`, `delta`, `xh`) ship completion
**files** instead — three extract them from their release tarball, delta generates
its own — so they need a different route:

| | zsh | bash |
|---|---|---|
| directory | `${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions` | `${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions` |
| filename | `_<tool>` (autoload name) | `<tool>` |
| reached by | the `fpath=(…)` line in `zsh.sh` | the sourcing loop in `bash.sh` |
| written by | `fb_install_completions` in `fetch.bins/_lib.sh` | same |

Four things about this are load-bearing:

- **The directory is not chezmoi-managed, and not `local.d/` either.** The fetchers
  run on every machine, so the files reproduce themselves; committing them would
  pin a completion to a version the installed binary may not match. `local.d/` is
  the wrong home for the opposite reason — it is host-local by definition, and
  these should reproduce *everywhere*.
- **zsh files are renamed to `_<tool>` on install.** bat ships its zsh completion as
  `autocomplete/bat.zsh`, **not** `_bat`. zsh's `$fpath` autoloading keys on the
  leading-underscore convention, so under its shipped name the file is simply never
  loaded — with no error and nothing to grep for. `fb_install_completions` therefore
  renames unconditionally (a no-op for `fd`/`xh`, which already ship `_fd`/`_xh`).
- **`compinit` is cached.** `rc.sh` runs `compinit -C`, which reuses `~/.zcompdump`
  rather than rescanning `$fpath`. A newly-fetched completion may not appear until
  the dump is rebuilt — which reads as "the completions don't work":

      rm -f ~/.zcompdump && exec zsh

- **bash sources the directory explicitly.** bash-completion *does* search this exact
  path on its own, but `bash.sh` already concedes that bash-completion may not be
  installed at all, and on such a host nothing would load these files. Sourcing them
  directly works either way; the files are clap-generated and self-contained.
  (Upstream caveat: bat's bash completion falls back to `_get_comp_words_by_ref`,
  a bash-completion helper, so on a host with *no* bash-completion bat's Tab
  completion errors at completion time. The other three are unaffected.)

Teardown is in lockstep: `fb_remove_completions` deletes only these exact files and
then `rmdir`s upward, so a shared directory holding a distro package's completions
survives.

## Tool integration: print and eval, never "install"

`dotfiles_tool_init` (in `common.sh`, called by `rc.sh` after `compinit`) wires
five tools into the interactive shell, and every one of them uses a
**print-to-stdout** form that is then `eval`'d:

| Tool | Invocation | Provides |
|---|---|---|
| starship | `starship init <shell>` | prompt |
| fzf | `fzf --<shell>` | keybindings + completion |
| tv | `tv init <shell>` | completion (unguarded `compdef`) |
| herdr | `herdr completion <shell>` | completion (`compdef`/`complete`) |
| broot | `broot --print-shell-function <shell>` | the `br` function |

**The print form is not a style preference — the "install" alternatives are
actively harmful here.** `broot --install` appends a `source …` line to *both*
`~/.bashrc` and `~/.zshrc`, which are chezmoi-managed stubs, so the next
`chezmoi apply` deletes it (the same trap the `env.d/` + `local.d/` split exists
to solve). Printing the function writes nothing and works identically in both
shells. Measured cost of the whole set is ~2 ms per interactive shell, so none
of it is cached to disk.

Two invocation details that are easy to get wrong:

- herdr's subcommand is **`completion`**, singular — `herdr completions bash` is
  not valid. The emitted snippet registers itself (`complete -F _herdr herdr`
  under bash, `compdef _herdr herdr` under zsh), so the `eval` is all that is
  needed. Because it calls `compdef`, it is subject to the after-`compinit`
  ordering rule above.
- broot only ever generates a **bash** launcher. There is no
  `~/.config/broot/launcher/zsh/`, and there never will be — for zsh, `--install`
  points `~/.zshrc` at the bash launcher. Any code that reads a *per-shell*
  launcher path silently does nothing under zsh.

### `^R` belongs to fzf, `^T` to tv — a ruling, not a default

Two of the five bind the same keys. `fzf --<shell>` binds `^R`, `^T` and `Alt-C`;
`tv init <shell>` binds `^R` and `^T`. tv is eval'd **after** fzf in the table
above, so by plain line order tv won both — for two months, with nothing
anywhere recording that a choice had been made.

That is not cosmetic, because the two `^R` widgets differ in exactly the
property people care about:

| | dedupes candidates | reads `$FZF_CTRL_R_OPTS` |
|---|---|---|
| `fzf-history-widget` | **yes** — `if (!seen[cmd]++)` | **yes** |
| `_tv_shell_history` | **no** — `history -n -1 0 \| tv …`, raw | no |

So `^R` had no dedupe at all, and the `FZF_CTRL_R_OPTS='--exact'` set in
`common.sh` was **inert** — it is read only inside the widget that nothing was
invoking. A fuzzy-matching complaint that `--exact` was written to fix stayed
broken and was believed fixed, which is worse than either being broken or being
fixed.

`dotfiles_tool_init` therefore ends by rebinding `^R` to fzf's widget, leaving
`^T` with tv. Two properties of that fix are load-bearing:

- it is **inside** `dotfiles_tool_init`, after the tv eval. Outside the function
  it would run once at startup and be silently undone by the first
  `dotfiles-reinit`, which re-runs tv's init.
- it **degrades to a no-op**, not to a broken key. If fzf ever renames the
  widget, `^R` keeps tv's binding rather than binding nothing. The harness
  asserts the binding behaviourally against stubs that reproduce the contest, so
  a rename surfaces as a red test instead of a dead keystroke.

### Staleness: `dotfiles-reinit` and the `tool-init` row

`dotfiles_tool_init` evals each integration exactly **once**, at shell start.
Phase 5 of the installer then replaces those same binaries underneath shells that
are already running, and nothing reconciles the two — so a long-lived shell
(herdr and tmux sessions here live for weeks) keeps the old integration
indefinitely, with nothing to grep and no version mismatch anywhere a user would
look. Stale integration is indistinguishable from a bug in the tool.

Two halves close it:

- **`dotfiles-reinit`** re-runs the integrations in place. It is a thin wrapper
  over `dotfiles_tool_init` — one implementation, so the manual and startup paths
  cannot drift. Re-running is safe: measured idempotent, with hook arrays,
  keybindings and the widget list byte-identical across runs. (starship adds one
  wrapper function on the second call and then converges; runs 3–5 add nothing.)
- **`dotfiles_tool_init` exports `DOTFILES_TOOL_INIT_EPOCH`**, and `./doctor`
  compares it against the mtime of each of the five binaries. `export` is
  required — doctor is a child process and reads it from the environment.

The comparison **must** dereference (`stat -Lc %Y`). These are
`~/.local/bin/<tool>` symlinks whose mtime tracks neither the tool nor the
upgrade: measured here, fzf's link was four months *older* than its binary while
starship's was *newer* than its own. A check without `-L` reports `ok` forever
and greps perfectly clean.

### `installed-v4` is tracked on purpose

`home/dot_config/broot/launcher/installed-v4` is a chezmoi-managed file whose
content is broot's own "the installation of the br function was done" note. It
looks like stray state committed by accident. It is not, and it must not be
removed: without it, broot's **first TUI launch prompts `Can I install it now?
[Y/n]`, defaulting to yes**, and the only thing that install does is patch the
managed rc stubs. Shipping the marker suppresses that prompt on every machine,
while the rc layer supplies `br` properly. (An explicit `broot --install` still
works if you ever want it — the marker only suppresses the automatic offer.)

Correspondingly, `home/dot_config/broot/launcher/bash/br` is **not** in the
source tree, and a test asserts `chezmoi apply` does not produce it: it is a
machine-local symlink into `~/.local/share`, not portable state.

## Dotfiles awareness — `./doctor` / `dotfiles-doctor`

The health report is a **real CLI** at the repo root (`./doctor`). The
implementation and tool registry live under [`lib/`](../../lib/)
(`doctor-report.sh`, `doctor-registry.sh`). After apply,
`~/.local/bin/dotfiles-doctor` trampolines into that script.

Interactive shells still expose the hyphenated name as a thin function in
`doctor.sh` (rc layer only — dash cannot parse `foo-bar()` in the env layer)
so the once-per-login greet and `command -v dotfiles-doctor` keep working:

```sh
dotfiles-doctor() { "$HOME/.local/bin/dotfiles-doctor" "$@"; }
```

### Report contents

Startup is **silent by design**. Rather than nag on every shell start, the config
knows how this repo provisions tools and reports on demand:

```
$ dotfiles-doctor
  starship  ok    /home/johns/.local/bin/starship
  fzf       ok    /home/johns/.local/bin/fzf
  broot     ok    /home/johns/.local/bin/broot
  herdr     ok    /home/johns/.local/bin/herdr
  tv        n/a   not provisioned by fetch.bins
  keychain  n/a   superseded by ~/.config/bashrc.d/10-ssh-agent.sh
  tool-init ok    integrations current
```

The `tool-init` row is the staleness check described above. It has three states,
and only the first is a call to action:

```
  tool-init STALE fzf, starship newer than this shell's integrations — run: dotfiles-reinit
  tool-init ok    integrations current
  tool-init n/a   no stamp (non-interactive shell)
```

`n/a` is not a failure. A non-interactive shell never runs the rc layer, so it
has no integrations and nothing to be stale; only an *interactive* shell missing
the stamp would be interesting, and doctor cannot tell the two apart.

A missing tool names the exact installer that fixes it. The installer path is
resolved by **globbing** `fetch.bins/*_fetch.<stem>.sh` rather than hardcoding the
`NN_` prefix, so renumbering a fetcher does not silently rot the table. The stem is
usually the command, but not always — `rg` ships from `ripgrep.sh` and `cargo` from
`rust.sh`, which is why the registry maps command → stem explicitly.

```
  ghostty   MISS  → run ~/.local/bin/fetch.bins/16_fetch.ghostty.sh  (community AppImage; upstream ships Linux via distros)
```

**Provisioning is decided by the STEM alone** — an empty stem means this repo
does not ship the tool, and the row reports `n/a`. The note is free-form context
and carries no meaning about provisioning: a provisioned row may have one, and
it is appended in parentheses to the `MISS` line.

That distinction was a real bug until iteration 43. `doctor-report.sh` keyed
`n/a` on a **non-empty note**, which is indistinguishable from the stem test only
while notes appear exclusively on stemless rows — true when the code was written,
false the moment a provisioned tool wanted an explanation. `tree-sitter`, `herdr`,
`ghostty` and `delta` were all reported as "not provisioned by this repo" when
absent, and the `→ run <fetcher>` hint was suppressed. The failure is
self-concealing twice over: it fires only when a provisioned tool is **missing**,
so a maintainer adding a note sees no change on their own machine (the row says
`ok` there), and it lands at exactly the moment the installer path is the one
useful thing on the screen. `delta` shipped with its note deliberately stripped
as a workaround until the reporter was fixed.

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
- **A lying diagnostic, and then a second one.** zsh first printed "broot is not
  installed locally" when broot *was* installed — it was checking for the `br`
  launcher shim. The fix at the time was to source the **per-shell** launcher,
  `~/.config/broot/launcher/$DOTFILES_SHELL/br`, and to have `dotfiles-doctor`
  distinguish "no binary" from "no shim". That was still wrong, just more quietly:
  **broot never creates a `zsh/` launcher directory at all.** `broot --install`
  generates only `launcher/bash/br` and, for zsh, patches `~/.zshrc` to source
  that same bash file — so under zsh the per-shell path can never resolve, `br`
  was never defined, and doctor's `→ run: broot --install` advice could never
  clear its own note however many times you ran it. Both are now gone: the rc
  layer eval's `broot --print-shell-function "$DOTFILES_SHELL"` (see below) and
  doctor carries no broot special case.
- **Two bashrc files.** `.bashrc-debian` and `.bashrc-arch` differed by exactly one
  alias. `.chezmoiremove` deletes the stale copies from every machine.
