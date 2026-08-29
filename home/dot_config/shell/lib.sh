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

# df_os — the OS name, lowercased: linux, freebsd, darwin, ...
#
# Memoized in DF_OS so `uname` is forked at most ONCE per shell, and only when
# something actually asks. The laziness is not a micro-optimization: this
# helper is duplicated into the bottom of the env layer, which is sourced by
# every `zsh -c`, and the standing rule there is that a fork is a tax on every
# shell in every loop. Defining a function costs nothing; deriving eagerly
# would bill everyone for an answer most shells never need.
#
# DF_OS is deliberately NOT exported, for the same reason DOTFILES_ENV_LOADED
# is not: a child shell re-derives its own answer rather than trusting an
# inherited flag.
#
# The case arms cover the platforms this repo targets without a second fork;
# the tr fallback keeps an unlisted OS correct rather than empty.
df_os_init() {
    [ -z "${DF_OS:-}" ] || return 0
    case $(uname -s) in
    Linux) DF_OS=linux ;;
    FreeBSD) DF_OS=freebsd ;;
    Darwin) DF_OS=darwin ;;
    *) DF_OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
    esac
}

df_os() { df_os_init; printf '%s\n' "${DF_OS}"; }

# df_is_linux / df_is_freebsd — silent predicates, exit status only.
#
# Prefer these to an inline `[ "$(uname -s)" = Linux ]`: that idiom forks on
# every call, and this repo had spelled the same question three different ways
# in three files before they were consolidated here.
df_is_linux() { df_os_init; [ "${DF_OS}" = linux ]; }
df_is_freebsd() { df_os_init; [ "${DF_OS}" = freebsd ]; }

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
