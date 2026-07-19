# env.sh — the environment layer. Sourced by EVERY shell, interactive or not.
#
# Reached from four places, so that no shell can miss it:
#
#   ~/.zshenv       every zsh — including `zsh -c` and `ssh host cmd`
#   ~/.profile      login sh/dash, and display managers
#   ~/.bashrc       ABOVE its interactivity gate (bash reads .bashrc for `ssh host cmd`)
#   rc.sh           belt and braces, for an interactive shell that arrived some other way
#
# Everything a NON-interactive shell needs lives here: PATH and exported vars,
# nothing else. Aliases, the prompt, completions and ~/.keys are the rc layer
# (rc.sh → common.sh), which only interactive shells reach. See doc/shell.md.
#
# Three constraints, all load-bearing:
#
#   POSIX      ~/.profile may be dash on Debian. No arrays, no [[ ]], no `local`,
#              and no hyphen in a function name (dash rejects `foo-bar()` outright,
#              which is why dotfiles-doctor lives in doctor.sh and not in lib.sh).
#   silent     ~/.zshenv runs for every zsh, and a single stray character on stdout
#              breaks scp, sftp and rsync.
#   cheap      it runs on every `zsh -c`, so a fork here is a tax on every shell in
#              every loop. The EDITOR lookup below is the only one, deliberately.

# Derive once per shell. Deliberately NOT exported: a child shell re-derives from
# its own $HOME rather than trusting an inherited flag.
[ -n "${DOTFILES_ENV_LOADED:-}" ] && return 0
DOTFILES_ENV_LOADED=1

DOTFILES_SHELL_DIR="$HOME/.config/shell"

# df_have / path_prepend / source_dir.
[ -r "$DOTFILES_SHELL_DIR/lib.sh" ] || return 0 2>/dev/null || exit 0
. "$DOTFILES_SHELL_DIR/lib.sh"

# --- environment --------------------------------------------------------------
export GOPATH="$HOME/code/go"
[ -d "$GOPATH" ] || mkdir -p "$GOPATH/bin"

export XZ_OPT="-9 -T0"
export CLAUDE_VAULT="$HOME/obsidian/ObsMeetings"

# nvm's location is environment; nvm's *scripts* (the `nvm` function, the
# completions) are heavyweight and stay in the rc layer.
[ -d "$HOME/.local/apps/nvm" ] && export NVM_DIR="$HOME/.local/apps/nvm"

# --- PATH ---------------------------------------------------------------------
# The rule this repo follows:
#
#   A binary we FETCH is symlinked into ~/.local/bin (install_bin, in
#   fetch.bins/_lib.sh), so a single PATH entry covers every one of them.
#
#   A bin directory a package MANAGER owns cannot be symlinked, because the
#   manager keeps adding to it after install time: `cargo install` and `rustup
#   component add` write to ~/.cargo/bin, `go install` writes to $GOPATH/bin. A
#   symlink set captured at install time would go stale the first time you did
#   either. Those directories go on PATH directly.
#
# path_prepend skips a directory that does not exist and never adds a duplicate,
# so this is safe to re-source. Lowest priority first: each prepend pushes the
# previous entries down.
path_prepend "$HOME/.local/bin"
path_prepend "$HOME/.cargo/bin"
path_prepend "$GOPATH/bin"

if [ -d /opt/rocm/bin ]; then
    export ROCM_PATH=/opt/rocm
    path_prepend "$ROCM_PATH/bin"
fi

# --- editor -------------------------------------------------------------------
# The absolute path, not the bare name: sudo resets PATH to its secure_path, so a
# bare `nvim` in SUDO_EDITOR would not resolve to the one under ~/.local/bin.
for _e in nvim vim vi; do
    if df_have "$_e"; then
        EDITOR="$(command -v "$_e")"
        break
    fi
done
if [ -n "${EDITOR:-}" ]; then
    export EDITOR
    export VISUAL="$EDITOR"
    export SUDO_EDITOR="$EDITOR"
fi
unset _e

# --- ssh agent ----------------------------------------------------------------
# SSH_AUTH_SOCK is environment, not interactive state — a git hook that pushes
# over ssh needs it just as much as a terminal does. This is the fork-free fast
# path: if the systemd unit's socket is already there, point at it.
#
# Everything else — starting the unit, the keychain and bare-ssh-agent fallbacks,
# ssh-add — is fork-heavy and stays in the rc layer's
# ~/.config/bashrc.d/10-ssh-agent.sh, whose own fast path returns immediately when
# we have already set a working socket here.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/openssh_agent" ]; then
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/openssh_agent"
fi

# --- host-local ---------------------------------------------------------------
# env.d/ is the environment-layer twin of local.d/ (rc layer, sourced by rc.sh
# before compinit). A host-local drop-in that touches PATH belongs here, so that
# non-interactive shells see it; one that adds completions or extends $fpath
# belongs in local.d/. Neither directory is managed by chezmoi.
source_dir "$DOTFILES_SHELL_DIR/env.d"

return 0 2>/dev/null || true
