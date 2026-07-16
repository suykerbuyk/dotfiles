# doctor.sh — dotfiles awareness. RC layer: sourced by rc.sh, interactive only.
#
# Split out of lib.sh, which the env layer sources from a possibly-dash
# ~/.profile. `dotfiles-doctor` has a hyphen in its name, and dash rejects
# `foo-bar()` as a syntax error — so this file must never be reachable from the
# env layer. Nothing here runs at startup; these are function definitions and a
# table, called on demand.
#
# The rc files know how this repo provisions tools, so a missing tool can name its
# own fix instead of just complaining. Each row of the registry is:
#
#     <command>|<fetch.bins stem>|<note>
#
# The stem is the tool's name inside fetch.bins/NN_fetch.<stem>.sh — usually the
# command itself, but not always (`rg` comes from ripgrep.sh, `cargo` from
# rust.sh). An empty stem means this repo does not provision the tool, and the
# note says what it is instead. The installer path is resolved by globbing
# fetch.bins/ rather than hardcoding the NN_ prefix, so renumbering a fetcher does
# not silently rot this table.
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
    printf 'env:    %s (PATH + exports, every shell)\n' "$HOME/.config/shell/env.sh"
    printf 'rc:     %s (interactive only)\n\n' "$HOME/.config/shell/common.sh"

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

    # Secrets: ~/.keys is age-encrypted in the repo and decrypted here by chezmoi.
    # Report the three states so the fix is always one glance away (see dotfiles-keys).
    if [ -r "$HOME/.keys" ]; then
        printf '  %-9s %-5s %s\n' 'keys' 'ok' \
            "$HOME/.keys (mode $(stat -c %a "$HOME/.keys" 2>/dev/null), $(grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$HOME/.keys" 2>/dev/null || echo 0) entries) — edit: dotfiles-keys"
    elif [ -r "$HOME/.config/chezmoi/key.txt" ]; then
        printf '  %-9s %-5s %s\n' 'keys' 'MISS' 'age key present but ~/.keys not applied — run: dotfiles-keys status'
    else
        printf '  %-9s %-5s %s\n' 'keys' 'n/a' 'no age identity — restore it: dotfiles-keys get-key'
    fi

    unset _cmd _stem _note _inst
    return 0
}

return 0 2>/dev/null || true
