# zsh.sh — zsh-only settings. Anything portable belongs in common.sh.
#
# compinit is deliberately NOT here: it runs at the very end of rc.sh, after
# local.d/ has had its chance to extend $fpath (the grok completions do exactly
# that). Initialising completions before that point silently drops them.

# --- history ------------------------------------------------------------------
HISTFILE="$HOME/.history"
HISTSIZE=10000
SAVEHIST=50000
setopt inc_append_history

# --- keybindings --------------------------------------------------------------
# vi mode. bash intentionally keeps its default emacs bindings — switching it
# would be a behavior change, not a portability fix, so it is left alone.
#
# Dropped in the merge: a redundant `set -o vi` (bindkey -v already does this)
# and `plugins=(vimode)`, which is an oh-my-zsh idiom and did nothing here —
# oh-my-zsh is not installed.
bindkey -v

return 0 2>/dev/null || true
