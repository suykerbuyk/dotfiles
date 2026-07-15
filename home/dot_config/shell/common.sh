# common.sh — the shared INTERACTIVE configuration (rc layer).
#
# Sourced by both bash and zsh from rc.sh, which only interactive shells reach.
# If a setting is not *genuinely* shell-specific, it belongs here rather than in
# bash.sh / zsh.sh — those deltas are deliberately small.
#
# What does NOT belong here: PATH and exported environment. Those are the env
# layer (env.sh), because a non-interactive shell never gets this far, and a
# `make` recipe or a git hook needs PATH just as much as a terminal does. That
# split is the whole point; see doc/shell.md. If you are about to add an `export`
# to this file, ask whether a script spawned by a tool would want it — if so, it
# goes in env.sh.
#
# $DOTFILES_SHELL is "bash" or "zsh" — set by rc.sh before this file is sourced.

# --- secrets ------------------------------------------------------------------
# Deliberately rc-layer, not env: API keys stay confined to shells you typed into.
# `bash -c`, cron and git hooks do not get them.
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
# $NVM_DIR is exported by env.sh (it is environment). Sourcing nvm.sh is not: it
# defines the `nvm` shell function and costs ~150 ms, which would be a tax on
# every `zsh -c` in every loop. So it stays here, in the interactive layer.
# (nvm's completion script is bash-only; bash.sh sources it.)
if [ -n "${NVM_DIR:-}" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
fi

return 0 2>/dev/null || true
