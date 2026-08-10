# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# lib.sh — helpers shared by bash and zsh. Sourced, never executed.
#
# This is the bottom of the env layer: env.sh sources it before touching PATH, so
# it must be safe in ANY shell, including a dash ~/.profile. POSIX constructs
# only — no bash arrays, no zsh glob qualifiers, and no hyphen in a function name
# (dash rejects `foo-bar()` as a syntax error; that is why `dotfiles-doctor` lives
# in doctor.sh, which only the rc layer sources).

# df_have <cmd> — true if <cmd> is on PATH. Namespaced (not the bare `have`)
# because bash-completion ships its own deprecated `have` and runs `unset -f have`
# when it loads; a bare `have` helper would be silently destroyed the moment
# bash.sh sources bash-completion, then error out at every later call site.
df_have() { command -v "$1" >/dev/null 2>&1; }

# path_prepend <dir> — put <dir> at the front of PATH, if it exists and is not
# already there. The dedupe is the point: without it, re-sourcing an rc file
# stacks duplicate entries (~/.grok/bin used to appear in PATH twice).
path_prepend() {
    [ -d "$1" ] || return 0
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
    esac
    PATH="$1:${PATH}"
    export PATH
}

# source_dir <dir> — source every readable *.sh in <dir>, sorted.
source_dir() {
    [ -d "$1" ] || return 0
    # zsh aborts on a glob that matches nothing ("no matches found"); bash leaves
    # the pattern unexpanded and the -r test below skips it. null_glob makes zsh
    # behave like bash here. local_options confines it to this function.
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt local_options null_glob
    fi
    for _f in "$1"/*.sh; do
        [ -r "$_f" ] || continue
        . "$_f"
    done
    unset _f
    return 0
}
