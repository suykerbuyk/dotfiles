# lib.sh — helpers shared by bash and zsh. Sourced, never executed.
#
# Everything in this file must behave identically under both shells: POSIX
# constructs only, no bash arrays, no zsh glob qualifiers. (`local` is fine —
# both shells have it.)

# have <cmd> — true if <cmd> is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

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

# --- dotfiles awareness -------------------------------------------------------
#
# The rc files know how this repo provisions tools, so a missing tool can name
# its own fix instead of just complaining. Each row is:
#
#     <command>|<fetch.bins stem>|<note>
#
# The stem is the tool's name inside fetch.bins/NN_fetch.<stem>.sh — usually the
# command itself, but not always (`rg` comes from ripgrep.sh, `cargo` from
# rust.sh). An empty stem means this repo does not provision the tool, and the
# note says what it is instead. The installer path is resolved by globbing
# fetch.bins/ rather than hardcoding the NN_ prefix, so renumbering a fetcher
# does not silently rot this table.
DOTFILES_FETCH_BINS="$HOME/.local/bin/fetch.bins"

_dotfiles_registry() {
    printf '%s\n' \
        'starship|starship|' \
        'fzf|fzf|' \
        'broot|broot|' \
        'nvim|nvim|' \
        'rg|ripgrep|' \
        'jq|jq|' \
        'go|go|' \
        'cargo|rust|' \
        'ninja|ninja|' \
        'protoc|protoc|' \
        'zed|zed|' \
        'chezmoi|chezmoi|' \
        'tv|| not provisioned by fetch.bins' \
        'keychain|| superseded by ~/.config/bashrc.d/10-ssh-agent.sh'
}

# dotfiles_installer_for <stem> — absolute path of the matching fetch.bins
# installer, or non-zero if there is none.
dotfiles_installer_for() {
    [ -n "$1" ] || return 1
    [ -d "$DOTFILES_FETCH_BINS" ] || return 1
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt local_options null_glob
    fi
    for _f in "$DOTFILES_FETCH_BINS"/*_fetch."$1".sh; do
        if [ -r "$_f" ]; then
            printf '%s\n' "$_f"
            unset _f
            return 0
        fi
    done
    unset _f
    return 1
}

# dotfiles-doctor — report every tool's status and, for the missing ones, the
# exact command that installs it. This is what replaced the per-tool nagging the
# rc files used to print on every single shell start.
dotfiles-doctor() {
    printf 'shell:  %s\n' "${DOTFILES_SHELL:-unknown}"
    printf 'config: %s (source of truth, shared by bash and zsh)\n\n' "$HOME/.config/shell"

    _dotfiles_registry | while IFS='|' read -r _cmd _stem _note; do
        if have "$_cmd"; then
            printf '  %-9s %-5s %s\n' "$_cmd" 'ok' "$(command -v "$_cmd")"
        elif [ -n "$_note" ]; then
            printf '  %-9s %-5s %s\n' "$_cmd" 'n/a' "$_note"
        elif _inst="$(dotfiles_installer_for "$_stem")"; then
            printf '  %-9s %-5s → run %s\n' "$_cmd" 'MISS' "$_inst"
        else
            printf '  %-9s %-5s (no installer in %s)\n' "$_cmd" 'MISS' "$DOTFILES_FETCH_BINS"
        fi
    done

    # broot is a special case worth calling out: the binary is not sufficient.
    # The `br` shell function comes from a launcher script that `broot --install`
    # generates per shell. Reporting "broot is not installed" when only the shim
    # is missing (which is what the old zshrc did) sends you looking in the wrong
    # place entirely.
    if have broot && [ ! -r "$HOME/.config/broot/launcher/${DOTFILES_SHELL}/br" ]; then
        printf '  %-9s %-5s binary present, but the `br` shim is missing → run: broot --install\n' 'broot' 'note'
    fi

    if [ ! -d "$HOME/.local/apps/nvm" ]; then
        if _inst="$(dotfiles_installer_for nvm)"; then
            printf '  %-9s %-5s → run %s\n' 'nvm' 'MISS' "$_inst"
        fi
    else
        printf '  %-9s %-5s %s\n' 'nvm' 'ok' "$HOME/.local/apps/nvm"
    fi

    if [ -d /opt/rocm/bin ]; then
        printf '  %-9s %-5s /opt/rocm\n' 'rocm' 'ok'
    else
        printf '  %-9s %-5s system package, not provisioned by this repo (/opt/rocm)\n' 'rocm' 'n/a'
    fi

    unset _cmd _stem _note _inst
    return 0
}
