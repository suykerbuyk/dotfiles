# rc.sh — the one entry point. ~/.bashrc and ~/.zshrc are thin stubs that source
# this file and do nothing else.
#
# Load order is load-bearing:
#
#   lib       helpers (have / path_prepend / source_dir) that everything below uses
#   common    the shared source of truth
#   <shell>   the small bash- or zsh-specific delta
#   bashrc.d  shared drop-ins, sourced by both shells (ssh-agent lives here)
#   local.d   host-local drop-ins, NOT managed by chezmoi — may extend PATH/fpath
#   compinit  zsh completions, LAST, so local.d can add to $fpath before it runs
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
    # rather than break the shell.
    return 0 2>/dev/null || exit 0
fi

DOTFILES_SHELL_DIR="$HOME/.config/shell"

. "$DOTFILES_SHELL_DIR/lib.sh"
. "$DOTFILES_SHELL_DIR/common.sh"
[ -r "$DOTFILES_SHELL_DIR/$DOTFILES_SHELL.sh" ] && . "$DOTFILES_SHELL_DIR/$DOTFILES_SHELL.sh"

source_dir "$HOME/.config/bashrc.d"
source_dir "$DOTFILES_SHELL_DIR/local.d"

if [ "$DOTFILES_SHELL" = zsh ]; then
    autoload -Uz compinit && compinit -C
fi

# Startup is quiet by design. `dotfiles-doctor` reports what is missing and the
# exact installer that fixes it; DOTFILES_SHELL_VERBOSE=1 prints that report at
# every shell start instead.
if [ -n "${DOTFILES_SHELL_VERBOSE:-}" ]; then
    dotfiles-doctor
fi

return 0 2>/dev/null || true
