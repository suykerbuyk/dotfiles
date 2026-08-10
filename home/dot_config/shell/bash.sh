# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# bash.sh — bash-only settings. Anything portable belongs in common.sh.

# --- history ------------------------------------------------------------------
HISTCONTROL=ignoredups:erasedups
HISTIGNORE="&:ls:[bf]g:exit:pwd:clear"
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend
shopt -s checkwinsize

# --- less ---------------------------------------------------------------------
# lesspipe is a Debian-ism; absent on Arch, hence the guard.
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# --- prompt -------------------------------------------------------------------
# starship owns the prompt when it is installed (common.sh runs `starship init`).
# This is the fallback for a host that does not have it yet.
if ! df_have starship; then
    if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
        debian_chroot="$(cat /etc/debian_chroot)"
    fi

    if [ -x /usr/bin/tput ] && tput setaf 1 >/dev/null 2>&1; then
        PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w \$\[\033[00m\] '
    else
        PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
    fi

    # xterm: put user@host:dir in the window title.
    case "$TERM" in
        xterm* | rxvt*)
            PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
            ;;
    esac
fi

# --- aliases (bash-specific) --------------------------------------------------
# `alert` reads the history list, so it cannot be shared with zsh as-is.
# Use like:  sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

[ -r "$HOME/.bash_aliases" ] && . "$HOME/.bash_aliases"

# --- completion ---------------------------------------------------------------
# nvm's completion script uses the `complete` builtin, so it is bash-only.
[ -n "${NVM_DIR:-}" ] && [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

if ! shopt -oq posix; then
    if [ -r /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -r /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

return 0 2>/dev/null || true
