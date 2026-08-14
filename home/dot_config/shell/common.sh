# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

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
if df_have dircolors; then
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
# These emit shell code, and some of it calls `compdef`: television's `tv init`
# ends with an unguarded `compdef _tv tv`, and `herdr completion zsh` ends with
# `compdef _herdr herdr`. `compdef` does not exist until `compinit` has run, and
# rc.sh runs compinit LAST (so local.d/ can extend $fpath first). So these inits
# cannot run inline here — they are wrapped in a function that rc.sh invokes
# *after* the compinit step. Each takes the shell's name, which is why they share
# this file rather than being duplicated per shell. (fzf guards its own compdef
# call; starship emits none. Two of the five now depend on the ordering, so it is
# a rule rather than a tv quirk.)
#
# Every one of these is a print-to-stdout form that is then eval'd. That is
# deliberate and it is the *only* safe shape here: the alternative "install"
# subcommands these tools ship append a source line to ~/.bashrc / ~/.zshrc,
# which are chezmoi-managed stubs — anything written there is destroyed by the
# next `chezmoi apply` (see doc/shell.md, "Host-local config"). Total cost is
# ~2 ms per interactive shell, so nothing here is worth caching to disk.
#
# herdr: the subcommand is `completion` (singular), and the emitted snippet
# registers itself (`complete -F _herdr herdr` / `compdef _herdr herdr`), so the
# eval is all that is required.
#
# broot: `--print-shell-function` is used rather than `broot --install`, which
# CANNOT work here. --install only ever generates the *bash* launcher
# (~/.config/broot/launcher/bash/br) — it never creates a zsh/ directory, and for
# zsh it instead patches ~/.zshrc to source that same bash file. So a per-shell
# launcher path can never resolve under zsh no matter how often --install runs,
# and --install's rc-file patching is destroyed by the next `chezmoi apply`
# anyway. Printing the function and eval'ing it is correct for both shells and
# touches no file at all.
dotfiles_tool_init() {
    df_have starship && eval "$(starship init "$DOTFILES_SHELL")"
    df_have fzf && eval "$(fzf --"$DOTFILES_SHELL")"
    df_have tv && eval "$(tv init "$DOTFILES_SHELL")"
    df_have herdr && eval "$(herdr completion "$DOTFILES_SHELL" 2>/dev/null)"
    df_have broot && eval "$(broot --print-shell-function "$DOTFILES_SHELL" 2>/dev/null)"
    return 0
}

df_have fzf && df_have tmux && export FZF_DEFAULT_OPTS='--tmux center'

# fzf's ^R widget defaults to FUZZY matching, so a query is treated as scattered
# characters rather than a substring: searching `dang` matched 693 entries here,
# most of them because d-a-n-g appears in that order somewhere in the line. Exact
# matching is what people actually mean when searching shell history, and it cuts
# the candidate set far harder than any zsh dedupe option.
#
# Scoped to ^R on purpose. FZF_DEFAULT_OPTS above would force --exact on file and
# directory pickers too, where fuzzy matching is the point.
df_have fzf && export FZF_CTRL_R_OPTS='--exact'

# --- nvm ----------------------------------------------------------------------
# $NVM_DIR is exported by env.sh (it is environment). Sourcing nvm.sh is not: it
# defines the `nvm` shell function and costs ~150 ms, which would be a tax on
# every `zsh -c` in every loop. So it stays here, in the interactive layer.
# (nvm's completion script is bash-only; bash.sh sources it.)
if [ -n "${NVM_DIR:-}" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
fi

return 0 2>/dev/null || true
