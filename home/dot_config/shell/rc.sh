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

# Startup is quiet by design. `dotfiles-doctor` reports what is missing and the
# exact installer that fixes it; DOTFILES_SHELL_VERBOSE=1 prints that report at
# every shell start instead.
if [ -n "${DOTFILES_SHELL_VERBOSE:-}" ]; then
    dotfiles-doctor
fi

return 0 2>/dev/null || true
