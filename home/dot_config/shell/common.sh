# common.sh — the single source of truth for shell configuration.
#
# Sourced by both bash and zsh (after lib.sh). If a setting is not *genuinely*
# shell-specific, it belongs here and nowhere else. The shell-specific deltas are
# deliberately small: see bash.sh and zsh.sh.
#
# $DOTFILES_SHELL is "bash" or "zsh" — set by rc.sh before this file is sourced.

# --- environment --------------------------------------------------------------
export GOPATH="$HOME/code/go"
[ -d "$GOPATH" ] || mkdir -p "$GOPATH/bin"

export XZ_OPT="-9 -T0"
export CLAUDE_VAULT="$HOME/obsidian/ObsMeetings"

# --- PATH ---------------------------------------------------------------------
# path_prepend skips directories that do not exist and never adds a duplicate,
# so this is safe to re-source. Lowest priority first: each prepend pushes the
# previous entries down.
path_prepend "$HOME/.local/bin"
path_prepend "$HOME/.cargo/bin"
path_prepend "$HOME/.local/go/bin"
path_prepend "$GOPATH/bin"

# --- editor -------------------------------------------------------------------
for _e in nvim vim vi; do
    if have "$_e"; then
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

# --- secrets ------------------------------------------------------------------
[ -r "$HOME/.keys" ] && . "$HOME/.keys"

# --- aliases ------------------------------------------------------------------
if have dircolors; then
    if [ -r "$HOME/.dircolors" ]; then
        eval "$(dircolors -b "$HOME/.dircolors")"
    else
        eval "$(dircolors -b)"
    fi
fi

alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias gl='git log --oneline --graph --decorate'

# --- tool integration ---------------------------------------------------------
# Every one of these takes the shell's name as an argument, which is precisely
# why they can live in the shared file rather than being duplicated per shell.
have starship && eval "$(starship init "$DOTFILES_SHELL")"
have fzf && eval "$(fzf --"$DOTFILES_SHELL")"
have tv && eval "$(tv init "$DOTFILES_SHELL")"

have fzf && have tmux && export FZF_DEFAULT_OPTS='--tmux center'

# broot's `br` function comes from a launcher script that `broot --install`
# generates *per shell* — the binary alone does not provide it. Source the
# launcher for THIS shell (the old zshrc sourced the bash launcher under zsh) and
# stay quiet when it is absent; `dotfiles-doctor` reports the missing shim and
# the command that creates it.
_br="$HOME/.config/broot/launcher/$DOTFILES_SHELL/br"
[ -r "$_br" ] && . "$_br"
unset _br

# --- nvm ----------------------------------------------------------------------
# (nvm's completion script is bash-only; bash.sh sources it.)
if [ -d "$HOME/.local/apps/nvm" ]; then
    export NVM_DIR="$HOME/.local/apps/nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
fi

# --- ROCm ---------------------------------------------------------------------
if [ -d /opt/rocm/bin ]; then
    export ROCM_PATH=/opt/rocm
    path_prepend "$ROCM_PATH/bin"
fi

return 0 2>/dev/null || true
