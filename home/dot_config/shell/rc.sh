# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# rc.sh — the INTERACTIVE entry point. ~/.bashrc and ~/.zshrc are thin stubs that
# source this file once they have decided the shell is interactive.
#
# There are two layers, and the split is load-bearing:
#
#   env layer   lib.sh → env.sh → env.d/        PATH and exported vars. Reached by
#                                               EVERY shell (~/.zshenv, ~/.profile,
#                                               ~/.bashrc above its gate), because a
#                                               `make` recipe and a git hook need
#                                               PATH just as much as a terminal does.
#
#   rc layer    this file, and everything below Aliases, prompt, completions,
#                                               ~/.keys. Interactive shells only.
#
# Load order within the rc layer:
#
#   env       sourced defensively — a no-op if a stub already ran it, but it means
#             rc.sh works even for a shell that arrived here some other way
#   common    the shared interactive config
#   <shell>   the small bash- or zsh-specific delta
#   doctor    dotfiles-doctor and its registry (hyphenated function name: rc-only,
#             dash would reject it)
#   bashrc.d  shared drop-ins, sourced by both shells (ssh-agent lives here)
#   local.d   host-local drop-ins, NOT managed by chezmoi — completions and $fpath
#             (host-local PATH belongs in env.d/, which env.sh sources)
#   compinit  zsh completions, LAST, so local.d can add to $fpath before it runs
#   tools     starship/fzf/tv completion inits — AFTER compinit, because tv's
#             snippet calls `compdef`, which only exists once compinit has run
#   greet     dotfiles-doctor, once per login session era (see below)
#
# Every path below is absolute. That is not stylistic: the old ~/.bashrc did
# `source .bashrc-debian` with a relative path, so bash started anywhere other
# than $HOME silently loaded none of this.

# Which shell are we? $BASH_VERSION / $ZSH_VERSION are the reliable signals —
# $SHELL is the *login* shell (wrong inside a nested shell) and $0 varies with
# how the shell was invoked.
if [ -n "${ZSH_VERSION:-}" ]; then
    DOTFILES_SHELL=zsh
elif [ -n "${BASH_VERSION:-}" ]; then
    DOTFILES_SHELL=bash
else
    # Some other shell (dash, ksh…). Nothing here is guaranteed to work; bail out
    # rather than break the shell. (env.sh, by contrast, IS safe under dash — it
    # has to be, since ~/.profile may be dash.)
    return 0 2>/dev/null || exit 0
fi

DOTFILES_SHELL_DIR="$HOME/.config/shell"

. "$DOTFILES_SHELL_DIR/env.sh"
. "$DOTFILES_SHELL_DIR/common.sh"
[ -r "$DOTFILES_SHELL_DIR/$DOTFILES_SHELL.sh" ] && . "$DOTFILES_SHELL_DIR/$DOTFILES_SHELL.sh"
. "$DOTFILES_SHELL_DIR/doctor.sh"

source_dir "$HOME/.config/bashrc.d"
source_dir "$DOTFILES_SHELL_DIR/local.d"

if [ "$DOTFILES_SHELL" = zsh ]; then
    autoload -Uz compinit && compinit -C
fi

# Tool completion integration (starship, fzf, tv) runs HERE, after compinit, so
# that a snippet which calls `compdef` (tv's does, unguarded) finds it defined.
# For bash — which has no compinit — the position is immaterial. See common.sh.
dotfiles_tool_init

# Startup is quiet by design. `dotfiles-doctor` reports what is missing and the
# exact installer that fixes each one. It runs automatically ONCE per login
# session era — the first interactive shell after you log in — then stays quiet
# for every shell after it (new tmux panes, splits, subshells). The stamp lives
# in $XDG_RUNTIME_DIR (/run/user/$UID): systemd-logind creates that tmpfs at your
# first login and destroys it when your last session ends, so "once" resets on a
# full logout and on reboot with no cleanup code of our own. `set -C` (noclobber)
# makes the create atomic, so when several panes open at once exactly one wins
# and prints. DOTFILES_SHELL_VERBOSE=1 forces the report on every shell instead.
#
# (If you have run `loginctl enable-linger`, the runtime dir survives a full
# logout, so the reset then happens only on reboot — still correct, just rarer.)
_dotfiles_greet=
if [ -n "${DOTFILES_SHELL_VERBOSE:-}" ]; then
    _dotfiles_greet=1
elif [ -n "${XDG_RUNTIME_DIR:-}" ] &&
     ( set -C; : > "$XDG_RUNTIME_DIR/dotfiles-shell.greeted" ) 2>/dev/null; then
    _dotfiles_greet=1
fi
[ -n "$_dotfiles_greet" ] && dotfiles-doctor
unset _dotfiles_greet

return 0 2>/dev/null || true
