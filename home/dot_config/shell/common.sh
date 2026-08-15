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

    # ^R BELONGS TO fzf — a RULING (iter 44), not a default.
    #
    # `tv init` binds ^R and ^T, and it runs after fzf above, so for two months
    # television silently won a contest nobody had recorded. That is not a
    # cosmetic difference: fzf's widget DEDUPES its candidate list
    # (`if (!seen[cmd]++)`, `fzf --zsh`) and reads $FZF_CTRL_R_OPTS; tv's pipes
    # `history -n -1 0` straight into `tv` with no dedupe stage and reads no
    # FZF_* variable at all. So ^R had no dedupe and the --exact set below was
    # INERT — it is only reachable from the widget being restored here.
    #
    # This must stay INSIDE this function and AFTER the tv eval: outside it, a
    # dotfiles-reinit would re-run tv's init and hand ^R back. ^T stays tv's.
    #
    # Both forms degrade to a no-op rather than to a broken key: if fzf ever
    # renames the widget/function, ^R silently keeps tv's binding instead of
    # binding nothing. The harness asserts the binding behaviourally, so a
    # rename shows up as a red test rather than as a dead keystroke.
    case "$DOTFILES_SHELL" in
        zsh) bindkey '^R' fzf-history-widget 2>/dev/null ;;
        bash)
            if declare -F __fzf_history__ >/dev/null 2>&1; then
                bind -m emacs-standard -x '"\C-r": __fzf_history__' 2>/dev/null
                bind -m vi-command -x '"\C-r": __fzf_history__' 2>/dev/null
                bind -m vi-insert -x '"\C-r": __fzf_history__' 2>/dev/null
            fi
            ;;
    esac

    # Stamp when these integrations were loaded, so ./doctor can tell a shell
    # that its evals predate the binaries they came from. Exported on purpose:
    # doctor is a child process and inherits it. zsh needs the datetime module
    # for $EPOCHSECONDS; bash >= 5 has it builtin. date(1) is the last resort so
    # the stamp is never silently absent.
    [ "$DOTFILES_SHELL" = zsh ] && zmodload zsh/datetime 2>/dev/null
    DOTFILES_TOOL_INIT_EPOCH=${EPOCHSECONDS:-$(date +%s)}
    export DOTFILES_TOOL_INIT_EPOCH
    return 0
}

# Re-run the integrations in a shell that is already running. Phase 5 of the
# installer replaces these binaries underneath long-lived shells (herdr and tmux
# sessions here live for weeks) and nothing tells the shell its tools moved, so
# the eval'd snippets can be arbitrarily older than the binaries they came from.
#
# One implementation, not two: this is a thin wrapper over dotfiles_tool_init so
# the manual path and the startup path cannot drift. Re-running is safe —
# measured idempotent (iter 44): hook arrays, keybindings and the widget list are
# byte-identical across runs, and the single function starship adds on the second
# call converges there (runs 3-5 add nothing).
dotfiles-reinit() {
    dotfiles_tool_init && printf 'tool integrations reloaded (%s)\n' "$DOTFILES_SHELL"
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
#
# THIS ONLY WORKS BECAUSE dotfiles_tool_init REBINDS ^R TO fzf. From iter 42
# until iter 44 it did nothing whatsoever: tv owned ^R, this variable is read
# only inside fzf-history-widget, and `tv init` reads no FZF_* variable — so the
# fuzzy-matching annoyance this was written to fix was still there and believed
# fixed. Do not decide ^R belongs to tv without deleting this line as well.
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
