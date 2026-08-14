# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# zsh.sh — zsh-only settings. Anything portable belongs in common.sh.
#
# compinit is deliberately NOT here: it runs at the very end of rc.sh, after
# local.d/ has had its chance to extend $fpath (the grok completions do exactly
# that). Initialising completions before that point silently drops them.

# --- history ------------------------------------------------------------------
# HISTSIZE (in-memory) must be >= SAVEHIST (on-disk). Every dedupe option below
# operates on the IN-MEMORY list, so a SAVEHIST larger than HISTSIZE names a
# target one session's memory can never reach. These were 10000/50000 — an
# inversion — until iter 42.
HISTFILE="$HOME/.history"
HISTSIZE=50000
SAVEHIST=50000

# Write each command as it is entered. NOT share_history (which implies this and
# also imports other sessions' commands live): with many concurrent herdr/tmux
# panes, up-arrow surfacing a command typed seconds ago in an unrelated pane is a
# behaviour change nobody asked for. Deliberate, revisit only on request.
setopt inc_append_history

# Collapse superfluous whitespace BEFORE storing. This is the measured win, not a
# tidiness preference: the most-used command here existed as two byte-variants
# differing only by a trailing space (62 occurrences vs 21). fzf's ^R widget
# dedupes on the exact string, so both survived and rendered identically — 83
# occurrences producing two rows that look like one. This collapses them to one.
setopt hist_reduce_blanks

# Drop a command only when it repeats the one immediately before it. Deliberately
# the WEAK form — see hist_ignore_all_dups below.
setopt hist_ignore_dups

# Dedupe when writing the file, keeping the NEWEST of each duplicate. The recent
# window is therefore never disturbed, which matters here: the standing workflow
# is turning the last 10-20 entries into a repeatable script (`fc -ln -20`).
# Only older history develops gaps.
setopt hist_save_no_dups

# When the in-memory list is full, discard duplicates before uniques.
setopt hist_expire_dups_first

# A command typed with a leading space is not recorded. Also the standard way to
# keep a one-off secret out of history — relevant given the tsh/op work.
setopt hist_ignore_space

# Dedupe what line-editor SEARCHES surface. Inert while fzf owns ^R, because
# fzf's own widget already dedupes internally (`if (!seen[cmd]++)`), and it does
# not govern plain up-arrow either way. It earns its keep on a machine WITHOUT
# fzf: dotfiles_tool_init only evals fzf's bindings `if df_have fzf`, so there
# the native zsh search widgets are what you get.
setopt hist_find_no_dups

# NOT hist_ignore_all_dups. It removes the OLDER copy of any repeat anywhere in
# the list, which would destroy the chronology the last-20-into-a-script workflow
# reads. Ruled out deliberately; do not add it as an "improvement".

# --- keybindings --------------------------------------------------------------
# vi mode. bash intentionally keeps its default emacs bindings — switching it
# would be a behavior change, not a portability fix, so it is left alone.
#
# Dropped in the merge: a redundant `set -o vi` (bindkey -v already does this)
# and `plugins=(vimode)`, which is an oh-my-zsh idiom and did nothing here —
# oh-my-zsh is not installed.
bindkey -v

# --- completions ($fpath site-functions) --------------------------------------
# fetch.bins/ slots 18-21 (fd, bat, xh) extract completion files from their
# release tarballs, and delta generates its own; all four land in this directory
# under their zsh AUTOLOAD names (_fd, _bat, _delta, _xh). See _lib.sh's
# fb_install_completions.
#
# The directory is deliberately NOT chezmoi-managed. The fetchers run on every
# machine, so the files reproduce themselves; committing them would instead pin
# a completion to a version the installed binary may not match. This is also why
# it is not local.d/ — that route is host-local by definition, and these should
# reproduce everywhere.
#
# ORDER IS LOAD-BEARING. rc.sh runs `compinit` LAST, after local.d/ has had its
# chance to extend $fpath. This line must therefore run BEFORE compinit, which
# living in zsh.sh guarantees (rc.sh sources it early, at step 3 of 8). Adding a
# directory to $fpath AFTER compinit has run does nothing at all — silently.
# For the same reason this does NOT belong in the post-compinit
# dotfiles_tool_init block: that block exists for snippets calling `compdef`,
# which is a different mechanism.
#
# Guarded on existence so a machine that has not run the fetchers yet does not
# collect a dangling $fpath entry.
#
# NOTE: rc.sh runs `compinit -C`, which reuses the cached ~/.zcompdump instead of
# rescanning $fpath. A newly-installed completion may therefore not appear until
# the dump is rebuilt:  rm -f ~/.zcompdump && exec zsh
_dotfiles_site_functions="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions"
if [ -d "$_dotfiles_site_functions" ]; then
    fpath=("$_dotfiles_site_functions" $fpath)
fi
unset _dotfiles_site_functions

return 0 2>/dev/null || true
