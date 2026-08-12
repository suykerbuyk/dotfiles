#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# test-update-user-home-dir.sh — integration tests for the chezmoi bootstrap.
#
# SAFE: runs entirely in an isolated sandbox HOME + XDG dirs (mktemp), never
# touches the real ~ or the repo working tree. Run from the dotfiles checkout:
#
#   ./test-update-user-home-dir.sh            # structural + light network (jq/chezmoi)
#   ./test-update-user-home-dir.sh --go       # also exercise the 150 MB Go fetch
#   ./test-update-user-home-dir.sh --rust     # also exercise the rustup toolchain fetch
#   ./test-update-user-home-dir.sh --podman   # also exercise the 32 MB podman static fetch
#   ./test-update-user-home-dir.sh --ghostty  # also exercise the 48 MB ghostty AppImage fetch
#   ./test-update-user-home-dir.sh --herdr    # also exercise the 21 MB herdr binary fetch
#   RUN_GO_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_RUST_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_PODMAN_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_GHOSTTY_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_HERDR_FETCH=1 ./test-update-user-home-dir.sh
#   ./test-update-user-home-dir.sh --no-net   # structural only (needs a chezmoi on PATH)
#
# ninja is a small, fast release-zip fetcher, so it runs in the default
# network group (no opt-in flag); only the heavy go/rust toolchains are gated.
#
# Exit code is non-zero if any assertion fails.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"
LIB="home/dot_local/bin/fetch.bins/executable__lib.sh"
[[ -f "$LIB" ]] || { echo "Error: run from the dotfiles project root." >&2; exit 1; }
SRC="$REPO/home"

RUN_GO="${RUN_GO_FETCH:-0}"
RUN_RUST="${RUN_RUST_FETCH:-0}"
RUN_PODMAN="${RUN_PODMAN_FETCH:-0}"
RUN_GHOSTTY="${RUN_GHOSTTY_FETCH:-0}"
RUN_HERDR="${RUN_HERDR_FETCH:-0}"
NET=1
for a in "$@"; do
    case "$a" in
        --go) RUN_GO=1 ;;
        --rust) RUN_RUST=1 ;;
        --podman) RUN_PODMAN=1 ;;
        --ghostty) RUN_GHOSTTY=1 ;;
        --herdr) RUN_HERDR=1 ;;
        --no-net) NET=0 ;;
        # Print the header block, skipping the SPDX banner above it.
        --help|-h) awk '/^# SPDX-License-Identifier:/{s=1;next}
                        s==1 && /^[[:space:]]*$/{next}
                        s==1 && /^#/{s=2}
                        s==2 && /^#/{sub(/^#[[:space:]]?/,"");print;next}
                        s==2{exit}' "$0"; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

# ---- assertion framework ---------------------------------------------------
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
sec()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
assert()      { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
assert_file() { [[ -e "$2" ]] && ok "$1" || bad "$1 (missing: $2)"; }

# ---- isolated sandbox ------------------------------------------------------
CHEZMOI_ON_PATH="$(command -v chezmoi 2>/dev/null || true)"   # capture before HOME moves
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB"
export XDG_CONFIG_HOME="$SB/.config" XDG_CACHE_HOME="$SB/.cache" XDG_DATA_HOME="$SB/.local/share"
unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS   # simulate headless -> Phase 4 must skip
BIN_DIR="$SB/.local/bin"; APP_DIR="$SB/.local/apps"

echo "sandbox HOME=$SB"
echo "repo=$REPO   go-fetch=$([[ $RUN_GO == 1 ]] && echo on || echo off)   rust-fetch=$([[ $RUN_RUST == 1 ]] && echo on || echo off)   podman-fetch=$([[ $RUN_PODMAN == 1 ]] && echo on || echo off)   ghostty-fetch=$([[ $RUN_GHOSTTY == 1 ]] && echo on || echo off)   herdr-fetch=$([[ $RUN_HERDR == 1 ]] && echo on || echo off)   network=$([[ $NET == 1 ]] && echo on || echo off)"

# ---- locate a chezmoi binary (fetch into sandbox if needed) ----------------
sec "setup: chezmoi binary"
CHEZMOI=""
if [[ -n "$CHEZMOI_ON_PATH" && -x "$CHEZMOI_ON_PATH" ]]; then
    CHEZMOI="$CHEZMOI_ON_PATH"; ok "chezmoi available: $("$CHEZMOI" --version | head -1)"
elif [[ $NET == 1 ]]; then
    ( set +e; . "$LIB" >/dev/null 2>&1; fb_init; fetch_chezmoi ) >/dev/null 2>&1
    if [[ -x "$BIN_DIR/chezmoi" ]]; then CHEZMOI="$BIN_DIR/chezmoi"; ok "fetched chezmoi into sandbox"; else bad "could not obtain chezmoi"; fi
else
    skip "no chezmoi on PATH and --no-net: structural tests will be skipped"
fi
chz() { "$CHEZMOI" --source "$SRC" --destination "$SB" --no-tty "$@"; }

# ---- decode a chezmoi source name back to its target path ------------------
decode_component() {
    local c="$1"
    while true; do
        case "$c" in
            private_*)    c="${c#private_}" ;;
            empty_*)      c="${c#empty_}" ;;
            executable_*) c="${c#executable_}" ;;
            symlink_*)    c="${c#symlink_}" ;;
            *) break ;;
        esac
    done
    [[ "$c" == dot_* ]] && c=".${c#dot_}"
    printf '%s' "$c"
}
decode_path() {  # encoded rel (under home/) -> target rel (under ~)
    local rel="$1" out="" comp
    IFS='/' read -ra parts <<< "$rel"
    for comp in "${parts[@]}"; do out="${out}${out:+/}$(decode_component "$comp")"; done
    printf '%s' "$out"
}

# ===========================================================================
if [[ -n "$CHEZMOI" ]]; then
    sec "apply: chezmoi source -> sandbox HOME"
    # The source contains an age-encrypted secret (encrypted_private_dot_keys.age).
    # chezmoi needs the encryption METHOD configured just to READ such a source —
    # even though the sandbox has no key, so .chezmoiignore will drop ~/.keys. Render
    # the real template (as the installer does) so apply mirrors a keyless machine.
    mkdir -p "$SB/.config/chezmoi"
    sed -e "s|__SOURCE_DIR__|$SRC|g" -e "s|__HOME__|$SB|g" chezmoi.toml.template > "$SB/.config/chezmoi/chezmoi.toml"
    if chz apply --force; then ok "chezmoi apply --force succeeded"; else bad "chezmoi apply failed"; fi

    sec "parity: every tracked source entry reproduced in ~"
    miss=0; diffc=0; modec=0; symc=0; excl=0; okc=0; leak=0
    while IFS=$'\t' read -r meta path; do
        mode="${meta%% *}"; rel="${path#home/}"
        base="$(basename "$rel")"
        [[ "$base" == .chezmoi* ]] && continue          # chezmoi meta, not applied
        # age-encrypted secrets are applied ONLY when ~/.config/chezmoi/key.txt
        # exists (.chezmoiignore drops them otherwise). The sandbox has no key, so
        # the decrypted target must NOT appear — and never as plaintext, key or no.
        if [[ "$base" == encrypted_* ]]; then
            [[ -e "$SB/.keys" ]] && { echo "    LEAK .keys (secret materialized without a key!)"; leak=$((leak+1)); }
            continue
        fi
        target="$(decode_path "$rel")"; tgt="$SB/$target"
        # exclusions: doc/ is .chezmoiignore'd
        if [[ "$target" == doc/* ]]; then
            [[ -e "$tgt" ]] && { echo "    LEAK $target"; excl=$((excl+1)); } ; continue
        fi
        if [[ "$base" == symlink_* ]]; then
            want="$(git show "HEAD:$path")"
            if [[ -L "$tgt" && "$(readlink "$tgt")" == "$want" ]]; then okc=$((okc+1)); else echo "    SYMLINK $target"; symc=$((symc+1)); fi
        else
            if [[ ! -e "$tgt" ]]; then echo "    MISSING $target"; miss=$((miss+1)); continue; fi
            if ! diff -q <(git show "HEAD:$path") "$tgt" >/dev/null 2>&1; then echo "    CONTENT $target"; diffc=$((diffc+1)); continue; fi
            # executable_ prefix => target must be executable
            if [[ "$base" == *executable_* ]]; then
                [[ -x "$tgt" ]] || { echo "    MODE $target (want exec)"; modec=$((modec+1)); continue; }
            fi
            okc=$((okc+1))
        fi
    done < <(git ls-tree -r HEAD -- home/)
    assert "parity: no missing files"          "[[ $miss  -eq 0 ]]"
    assert "parity: no content diffs"          "[[ $diffc -eq 0 ]]"
    assert "parity: symlinks reproduced"       "[[ $symc  -eq 0 ]]"
    assert "parity: exec bits preserved"       "[[ $modec -eq 0 ]]"
    assert "parity: doc/ excluded from ~"      "[[ $excl  -eq 0 ]]"
    assert "parity: no plaintext secret leak"  "[[ $leak  -eq 0 ]]"
    echo "    ($okc entries verified)"

    sec "attributes: private + empty encodings"
    assert ".ssh is 0700 (private_)"            "[[ \"\$(stat -c '%a' \"$SB/.ssh\" 2>/dev/null)\" == 700 ]]"
    assert_file "empty_ file created (.ssh/hosts/keep.me)" "$SB/.ssh/hosts/keep.me"
    assert "empty_ file is actually empty"      "[[ ! -s \"$SB/.ssh/hosts/keep.me\" ]]"
    assert "broot 'br' launcher excluded"       "[[ ! -e \"$SB/.config/broot/launcher/bash/br\" ]]"

    sec "idempotency"
    chz apply --force >/dev/null 2>&1
    n="$(chz status 2>/dev/null | wc -l)"
    assert "second apply leaves 'chezmoi status' empty" "[[ $n -eq 0 ]]"

    # -----------------------------------------------------------------------
    sec "shell: one source of truth, shared by bash and zsh"
    assert_file "~/.bashrc applied"  "$SB/.bashrc"
    assert_file "~/.zshrc applied"   "$SB/.zshrc"
    for f in rc env lib common bash zsh doctor; do
        assert_file "~/.config/shell/$f.sh applied" "$SB/.config/shell/$f.sh"
    done
    assert "rc files are thin (both source ~/.config/shell/rc.sh)" \
        "grep -q '.config/shell/rc.sh' \"$SB/.bashrc\" && grep -q '.config/shell/rc.sh' \"$SB/.zshrc\""
    # .chezmoiremove must clear the merged-away per-distro variants.
    assert "stale .bashrc-debian removed" "[[ ! -e \"$SB/.bashrc-debian\" ]]"
    assert "stale .bashrc-arch removed"   "[[ ! -e \"$SB/.bashrc-arch\" ]]"

    # -----------------------------------------------------------------------
    # The env layer: the entry points that carry env.sh into shells which never
    # read an rc file. PATH is environment, not interactive state — `make`, git
    # hooks and `ssh host cmd` need it as much as a terminal does.
    sec "shell: env-layer entry points applied"
    assert_file "~/.zshenv applied"           "$SB/.zshenv"
    assert_file "~/.profile applied"          "$SB/.profile"
    assert_file "~/.bash_profile applied"     "$SB/.bash_profile"
    assert_file "environment.d PATH applied"  "$SB/.config/environment.d/10-dotfiles.conf"
    # bash reads ~/.bash_profile INSTEAD of ~/.profile, so it must chain explicitly.
    assert "~/.bash_profile sources ~/.profile" \
        "grep -q 'HOME/.profile' \"$SB/.bash_profile\""
    # The whole fix hinges on this ordering: env.sh must be sourced BEFORE the
    # `case $- in *i*)` gate, or non-interactive bash returns without a PATH.
    envline="$(grep -n 'shell/env.sh'  "$SB/.bashrc" | head -1 | cut -d: -f1)"
    gateline="$(grep -n 'case \$- in' "$SB/.bashrc" | head -1 | cut -d: -f1)"
    assert "~/.bashrc sources env.sh ABOVE its interactivity gate" \
        "[[ -n '$envline' && -n '$gateline' && $envline -lt $gateline ]]"

    # Probes run against the sandbox HOME, deliberately started from /tmp — never
    # $HOME. That cwd is the whole point: the bug this config replaced was
    # `source .bashrc-debian` (a RELATIVE path), which made bash load nothing at
    # all unless it happened to start in $HOME.
    #
    # `env -i` strips the environment to nothing, which is what makes these honest:
    # a shell that merely INHERITED a good PATH from its parent proves nothing.
    probe()    { ( cd /tmp && env -i HOME="$SB" TERM=xterm PATH=/usr/bin:/bin "$1" "$2" "$3" 2>/dev/null | tr -d '\r' | tail -1 ); }
    sh_probe() { probe "$1" -ic "$2"; }
    HAS_LOCALBIN='case ":$PATH:" in *":'"$SB"'/.local/bin:"*) printf HAS ;; *) printf MISSING ;; esac'

    # The headline fix. Before the env/rc split every row here was MISSING except
    # the interactive one — including both LOGIN shells, because ~/.bashrc returns
    # at its gate before PATH is ever set and no other file was managed at all.
    sec "shell: PATH reaches non-interactive and login shells"
    for spec in bash:-ic:interactive \
                bash:-lc:login \
                zsh:-ic:interactive \
                zsh:-lc:login \
                zsh:-c:non-interactive \
                sh:-lc:login; do
        IFS=: read -r s flag kind <<<"$spec"
        if ! command -v "$s" >/dev/null 2>&1; then
            skip "$s $flag probe ($s not installed)"
            continue
        fi
        p="$(probe "$s" "$flag" "$HAS_LOCALBIN")"
        assert "$s $flag ($kind): ~/.local/bin on PATH" "[[ '$p' == HAS ]]"

        d="$(probe "$s" "$flag" 'printf "%s" "$PATH"' | tr ':' '\n' | sort | uniq -d | grep -c . || true)"
        assert "$s $flag ($kind): PATH has no duplicate entries" "[[ '$d' -eq 0 ]]"
    done

    # Documented residual: a bare `bash -c` reads NO startup file — only $BASH_ENV,
    # which we deliberately do not set, because it would fire for every
    # #!/bin/bash script on the box. It works anyway because it INHERITS PATH from
    # a parent that finally has one. Pin that reasoning with a test rather than a
    # comment, so nobody "fixes" it by reaching for BASH_ENV.
    p="$( cd /tmp && env -i HOME="$SB" PATH="$SB/.local/bin:/usr/bin:/bin" bash -c "$HAS_LOCALBIN" 2>/dev/null )"
    assert "bash -c (non-interactive): inherits PATH from its parent" "[[ '$p' == HAS ]]"

    # env.sh, not rc.sh, is what exports GOPATH — so a non-interactive zsh has it.
    g="$(probe zsh -c 'printf "%s" "${GOPATH:-UNSET}"')"
    assert "zsh -c: GOPATH exported by the env layer" "[[ '$g' == '$SB/code/go' ]]"

    # ~/.keys is deliberately rc-layer: API keys stay confined to shells you typed
    # into, and a cron job or git hook must not inherit them.
    printf 'export DOTFILES_TEST_SECRET=leaked\n' > "$SB/.keys"
    k="$(probe zsh -c 'printf "%s" "${DOTFILES_TEST_SECRET:-ABSENT}"')"
    assert "zsh -c: ~/.keys NOT sourced (secrets stay interactive-only)" "[[ '$k' == ABSENT ]]"
    k="$(sh_probe zsh 'printf "%s" "${DOTFILES_TEST_SECRET:-ABSENT}"')"
    assert "zsh -ic: ~/.keys IS sourced" "[[ '$k' == leaked ]]"
    rm -f "$SB/.keys"

    sec "shell: rc layer still intact (regression guard)"
    for s in bash zsh; do
        if ! command -v "$s" >/dev/null 2>&1; then
            skip "$s probes ($s not installed)"
            continue
        fi

        g="$(sh_probe "$s" 'printf "%s" "${GOPATH:-UNSET}"')"
        assert "$s: rc loads from a cwd outside \$HOME" "[[ '$g' == '$SB/code/go' ]]"

        w="$(sh_probe "$s" 'command -v dotfiles-doctor >/dev/null && printf yes || printf no')"
        assert "$s: dotfiles-doctor is defined" "[[ '$w' == yes ]]"

        e="$(sh_probe "$s" 'printf "%s" "${EDITOR:-UNSET}"')"
        assert "$s: EDITOR resolved" "[[ '$e' != UNSET ]]"
    done

    # ~/.zshenv runs for EVERY zsh — including the one scp, sftp and rsync spawn on
    # the remote side. Those parse the stream as protocol, so a single stray
    # character printed from the env layer breaks file transfer outright. This is
    # the highest-consequence assertion in the file.
    sec "shell: startup is silent"
    for s in bash zsh; do
        command -v "$s" >/dev/null 2>&1 || continue
        noise="$( cd /tmp && env -i HOME="$SB" PATH=/usr/bin:/bin "$s" -c true 2>&1 | tr -d '\r\n \t' )"
        assert "$s -c: non-interactive startup emits nothing (scp/rsync safe)" "[[ -z '$noise' ]]"
    done

    # Interactive startup used to print 4 nag lines per zsh start. An interactive
    # shell without a tty emits its own job-control/zle warnings, so this needs a
    # pty to mean anything; skip rather than assert something weaker.
    if command -v script >/dev/null 2>&1; then
        for s in bash zsh; do
            command -v "$s" >/dev/null 2>&1 || continue
            noise="$(cd /tmp && script -qec "env -i HOME=$SB TERM=xterm PATH=/usr/bin:/bin $s -ic true" /dev/null 2>&1 | tr -d '\r\n \t')"
            assert "$s: interactive startup is silent" "[[ -z '$noise' ]]"
        done
    else
        skip "startup-silence probes (no 'script' for a pty)"
    fi

    # A completion snippet that calls `compdef` (television's `tv init` ends with
    # an unguarded `compdef _tv tv`) must be eval'd AFTER compinit, or zsh prints
    # "(eval):N: command not found: compdef" on every login. The tool inits were
    # moved out of common.sh into dotfiles_tool_init, which rc.sh calls after the
    # compinit step. Prove it with a `tv` stub that emits exactly that pattern —
    # no dependency on the real television being installed. (stderr only: the bug
    # surfaced there; interactive-without-a-tty job-control warnings are ignored
    # because the assertion greps for the specific compdef error.)
    if command -v zsh >/dev/null 2>&1; then
        sec "shell: tv-style compdef init is eval'd after compinit"
        faketv="$SB/.local/bin/tv"
        {
            printf '#!/bin/sh\n'
            printf '[ "$1" = init ] && printf "%%s\\n" "#compdef tv" "_tv() { :; }" "compdef _tv tv"\n'
        } > "$faketv"
        chmod +x "$faketv"
        err="$( cd /tmp && env -i HOME="$SB" TERM=xterm PATH=/usr/bin:/bin zsh -ic true 2>&1 >/dev/null | tr -d '\r' )"
        assert "tv init (unguarded compdef) raises no 'command not found'" \
            "! grep -q 'command not found: compdef' <<<\"\$err\""
        rm -f "$faketv"
    fi

    # --- herdr completions + broot `br` ---------------------------------------
    # Both are wired into dotfiles_tool_init as print-to-stdout forms that are
    # eval'd. Structural first (no dependency on either tool being installed),
    # then a functional pass driven by stubs, then the real binaries when present.
    sec "shell: herdr completions and broot 'br'"

    ti="$(sed -n '/^dotfiles_tool_init()/,/^}/p' "$SRC/dot_config/shell/common.sh")"
    assert "herdr completion is wired into dotfiles_tool_init" \
        "grep -q 'herdr completion' <<<\"\$ti\""
    assert "broot br is wired into dotfiles_tool_init" \
        "grep -q 'broot --print-shell-function' <<<\"\$ti\""
    assert "both are guarded by df_have" \
        "[[ \$(grep -c 'df_have herdr\|df_have broot' <<<\"\$ti\") -eq 2 ]]"

    # Every assertion below is NEGATIVE — "this code is gone" — so each one must
    # read code, not prose. Both files carry comments explaining exactly why the
    # removed forms were wrong, and grepping the raw text matches this repo's own
    # rationale and fails forever. Strip comments first.
    code="$(cat "$SRC"/dot_config/shell/*.sh | sed 's/#.*//')"
    dr="$(sed 's/#.*//' lib/doctor-report.sh)"

    # The per-shell launcher path is the bug this replaced: broot NEVER creates a
    # launcher/zsh/ directory, so that read silently no-ops under zsh forever.
    assert "shell layer no longer reads a per-shell broot launcher" \
        "! grep -q 'launcher/\$DOTFILES_SHELL' <<<\"\$code\""
    # --install patches ~/.bashrc AND ~/.zshrc, which are chezmoi-managed stubs.
    assert "nothing in the shell layer runs 'broot --install'" \
        "! grep -q 'broot --install' <<<\"\$code\""
    assert "doctor no longer advises 'broot --install'" \
        "! grep -q 'broot --install' <<<\"\$dr\""
    assert "doctor no longer tests the per-shell br launcher" \
        "! grep -q 'launcher/\${_shell}/br' <<<\"\$dr\""

    # The marker is tracked ON PURPOSE: without it broot's first TUI launch
    # prompts 'Can I install it now? [Y/n]' (defaulting to yes) and patches the
    # managed rc stubs. The bash launcher, by contrast, stays machine-local.
    assert_file "broot install marker is shipped (suppresses the install prompt)" \
        "$SRC/dot_config/broot/launcher/installed-v4"

    # Functional, via stubs shaped like the real emitters — so this holds on a box
    # with neither tool installed. The herdr stub ends in an unguarded `compdef`,
    # exactly as `herdr completion zsh` does, which pins the after-compinit order.
    if command -v zsh >/dev/null 2>&1; then
        fakeherdr="$SB/.local/bin/herdr"
        fakebroot="$SB/.local/bin/broot"
        {
            printf '#!/bin/sh\n'
            printf '[ "$1" = completion ] && printf "%%s\\n" "_herdr() { :; }" "compdef _herdr herdr"\n'
        } > "$fakeherdr"
        {
            printf '#!/bin/sh\n'
            printf '[ "$1" = --print-shell-function ] && printf "%%s\\n" "br() { :; }"\n'
        } > "$fakebroot"
        chmod +x "$fakeherdr" "$fakebroot"

        err="$( cd /tmp && env -i HOME="$SB" TERM=xterm PATH=/usr/bin:/bin zsh -ic true 2>&1 >/dev/null | tr -d '\r' )"
        assert "herdr completion (unguarded compdef) raises no 'command not found'" \
            "! grep -q 'command not found: compdef' <<<\"\$err\""

        b="$(sh_probe zsh 'printf "%s" "$(whence -w br 2>/dev/null || printf UNDEF)"')"
        assert "zsh: br is defined as a function" "[[ '$b' == 'br: function' ]]"
        c="$(sh_probe zsh 'printf "%s" "${_comps[herdr]:-UNSET}"')"
        assert "zsh: herdr completion is registered with compdef" "[[ '$c' == '_herdr' ]]"

        if command -v bash >/dev/null 2>&1; then
            b="$(sh_probe bash 'printf "%s" "$(type -t br 2>/dev/null || printf UNDEF)"')"
            assert "bash: br is defined as a function" "[[ '$b' == function ]]"
        fi

        # Neither eval may break the silence contract (both are 2>/dev/null).
        if command -v script >/dev/null 2>&1; then
            noise="$(cd /tmp && script -qec "env -i HOME=$SB TERM=xterm PATH=/usr/bin:/bin zsh -ic true" /dev/null 2>&1 | tr -d '\r\n \t')"
            assert "startup stays silent with herdr+broot wired" "[[ -z '$noise' ]]"
        fi

        rm -f "$fakeherdr" "$fakebroot"
    else
        skip "herdr/broot stub probes (zsh not installed)"
    fi

    # Contract check against the REAL binaries when this box has them: the
    # subcommand is `completion` (singular) and each snippet self-registers.
    if command -v herdr >/dev/null 2>&1; then
        hb="$(herdr completion bash 2>/dev/null)"
        hz="$(herdr completion zsh 2>/dev/null)"
        assert "real herdr: bash completion self-registers" \
            "[[ \"\$hb\" == *'complete -F _herdr'* ]]"
        assert "real herdr: zsh completion self-registers via compdef" \
            "[[ \"\$hz\" == *'compdef _herdr herdr'* ]]"
    else
        skip "real herdr completion contract (herdr not installed)"
    fi
    if command -v broot >/dev/null 2>&1; then
        for s in bash zsh; do
            bf="$(broot --print-shell-function "$s" 2>/dev/null)"
            assert "real broot: --print-shell-function $s defines br" \
                "[[ \"\$bf\" == *'br {'* || \"\$bf\" == *'br()'* ]]"
        done
    else
        skip "real broot --print-shell-function contract (broot not installed)"
    fi

    # --- herdr adopted at parity with tmux -----------------------------------
    sec "herdr: config managed, at parity with tmux"

    HCFG="$SRC/dot_config/herdr/config.toml"
    assert_file "herdr config.toml is a managed source file" "$HCFG"
    hc="$(cat "$HCFG" 2>/dev/null)"

    # ~/.config/herdr/ also holds herdr.sock, session.json and the logs. The
    # exact_ attribute would make chezmoi DELETE those unmanaged entries — live
    # sockets and session state, out from under a running server.
    assert "herdr source dir is NOT exact_ (would delete live sockets/state)" \
        "[[ ! -e '$SRC/dot_config/exact_herdr' ]]"
    assert "no herdr runtime state committed as source" \
        "! ls $SRC/dot_config/herdr/ 2>/dev/null | grep -Eq 'sock|session\.json|\.log$|plugins\.lock'"

    # The shared ctrl+b prefix is the ruling this whole adoption rests on, and it
    # must agree with dot_tmux.conf on both sides.
    assert "herdr prefix is ctrl+b" "grep -q '^prefix = \"ctrl+b\"' <<<\"\$hc\""
    assert "tmux prefix is still C-b (the other half of the parity)" \
        "grep -q '^set-option -g prefix C-b' $SRC/dot_tmux.conf"

    # Parity is ADDITIVE: tmux key first, herdr's native default retained, so a
    # chord the terminal fails to deliver degrades instead of vanishing.
    # detach is the ONE deliberate exception to additive parity. prefix+q is
    # surrendered to goto, so ctrl+b q can never detach again. The NEGATIVE
    # assertion is the load-bearing one: re-adding herdr's native fallback here
    # would silently restore the exact reflex-detach this removed, and the
    # positive assertion alone would not catch it.
    assert "detach binds ONLY tmux's prefix+d" \
        "grep -q '^detach = \"prefix+d\"\$' <<<\"\$hc\""
    assert "detach no longer claims prefix+q" \
        "! grep -q '^detach.*prefix+q' <<<\"\$hc\""
    # tmux's prefix q is display-panes. herdr has no equivalent action at all
    # (its validator rejects display_panes/select_pane_by_number as unknown), so
    # prefix+q is aliased to goto — herdr's NAVIGATE mode — keeping prefix+g.
    assert "goto claims prefix+q, keeping herdr's native prefix+g" \
        "grep -q '^goto = \\[\"prefix+q\", \"prefix+g\"\\]' <<<\"\$hc\""
    # Structural guard independent of which action wins prefix+q: exactly one
    # may claim it. Two actions on one key is how a rebind quietly half-lands.
    assert "exactly one action claims prefix+q" \
        "[[ \$(grep -c '^[^#]*prefix+q' <<<\"\$hc\") -eq 1 ]]"
    assert "cycle_pane_next binds tmux's prefix+space, keeping prefix+tab" \
        "grep -q 'cycle_pane_next = \\[\"prefix+space\", \"prefix+tab\"\\]' <<<\"\$hc\""

    # tmux's prefix ; is last-pane. herdr ships last_pane bound to "" (present in
    # --default-config, just empty), so this fills a gap rather than rebinding a
    # native — hence a scalar, with no fallback to preserve.
    assert "last_pane binds tmux's prefix+; (tmux last-pane parity)" \
        "grep -q '^last_pane = \"prefix+;\"\$' <<<\"\$hc\""
    # LOAD-BEARING NEGATIVE: herdr's own default-config comment recommends
    # binding last_pane to prefix+tab, which is already cycle_pane_next's
    # fallback here. Taking that suggestion would put two actions on one key,
    # and the positive assertion above would still pass while it happened.
    assert "last_pane does not take herdr's suggested prefix+tab (collides)" \
        "! grep -q '^last_pane.*prefix+tab' <<<\"\$hc\""
    # Structural guard, mirroring the prefix+q one: exactly one action may claim
    # prefix+; no matter which action that turns out to be.
    assert "exactly one action claims prefix+;" \
        "[[ \$(grep -c '^[^#]*prefix+;' <<<\"\$hc\") -eq 1 ]]"

    # The split convention is DELIBERATELY NOT PINNED. The human has not decided
    # which horizontal/vertical convention they want across tmux AND herdr, and
    # intends to run with it before choosing — so asserting a specific key-to-
    # action mapping here would fail the suite on every experiment. That is
    # friction pointed at exactly the thing being evaluated.
    #
    # What IS asserted is convention-agnostic and still catches real breakage:
    # both actions exist, each keeps herdr's native key as its fallback, and the
    # two never collide on one key. Any convention satisfies these; a half-edited
    # swap does not.
    svk="$(sed -n 's/^split_vertical *= *\[\([^,]*\),.*/\1/p' <<<"$hc")"
    shk="$(sed -n 's/^split_horizontal *= *\[\([^,]*\),.*/\1/p' <<<"$hc")"
    assert "split_vertical binds a primary key"   "[[ -n \"\$svk\" ]]"
    assert "split_horizontal binds a primary key" "[[ -n \"\$shk\" ]]"
    assert "the two split actions never collide on one key" "[[ \"\$svk\" != \"\$shk\" ]]"
    assert "split_vertical keeps herdr's native prefix+v fallback" \
        "grep -q '^split_vertical.*prefix+v' <<<\"\$hc\""
    assert "split_horizontal keeps herdr's native prefix+minus fallback" \
        "grep -q '^split_horizontal.*prefix+minus' <<<\"\$hc\""
    assert "natives are not swapped between the two split actions" \
        "! grep -q '^split_vertical.*prefix+minus' <<<\"\$hc\" && ! grep -q '^split_horizontal.*prefix+v' <<<\"\$hc\""
    # The mapping stays flagged as under evaluation until the human rules.
    assert "split convention is marked PROVISIONAL" \
        "grep -q 'PROVISIONAL' <<<\"\$hc\""

    # The live machine dismissed onboarding; a managed config that lost this
    # would re-prompt on every other machine.
    assert "onboarding stays dismissed" "grep -q '^onboarding = false' <<<\"\$hc\""
    # Terminal layer pins Catppuccin Mocha in kitty AND ghostty.
    assert "theme matches the terminal layer (catppuccin)" \
        "grep -q '^name = \"catppuccin\"' <<<\"\$hc\""

    # Real validator: catches an unknown action or an undeliverable key name,
    # including inside the arrays. Both failures are silent at runtime.
    #
    # `herdr config check` reports "config: ok" for a MISSING config file too, so
    # the check alone is a false green — it would keep passing if the file
    # stopped being applied. Assert the applied file exists first; that is what
    # makes the validation below mean anything.
    assert_file "config.toml is applied to ~/.config/herdr/" "$SB/.config/herdr/config.toml"
    if command -v herdr >/dev/null 2>&1; then
        hchk="$(env HOME="$SB" XDG_CONFIG_HOME="$SB/.config" herdr config check 2>&1)"
        assert "herdr config check passes on the applied config" \
            "[[ \"\$hchk\" == *'config: ok'* ]]"
    else
        skip "herdr config check (herdr not installed)"
    fi

    assert_file "multiplexer parity is documented" "$SRC/doc/multiplexers.md"

    # --- hrdr: the herdr session picker (tm's counterpart) --------------------
    sec "hrdr: herdr session picker"

    HRDR="$SRC/dot_local/bin/executable_hrdr"
    assert_file "hrdr source present" "$HRDR"
    assert "hrdr is valid POSIX sh"  "sh -n $HRDR"
    # executable_ attribute must survive apply, or the picker is not runnable.
    assert "hrdr applied to ~/.local/bin and executable" "[[ -x '$SB/.local/bin/hrdr' ]]"
    assert "hrdr carries the SPDX banner" \
        "grep -q 'SPDX-License-Identifier: MIT OR Apache-2.0' $HRDR"

    # Read COMMENT-STRIPPED source for every claim below. The script's header
    # documents at length WHY it has no layouts and no \$USER- prefix, so a raw
    # grep for those forms matches the rationale that explains their absence and
    # fails permanently — the iter-38 negative-assertion trap.
    hs="$(sed 's/#.*//' "$HRDR")"

    # herdr's --session both creates and attaches, so there is no has-session
    # probe to keep in sync (unlike tm). Pin the call that does the work.
    assert "hrdr creates/attaches via '--session'" \
        "grep -q 'run_herdr --session' <<<\"\$hs\""

    # --- verbose tracing ------------------------------------------------------
    # STRUCTURAL: every herdr call must route through the two helpers, or `-v`
    # silently stops covering whichever call site bypassed them. Exactly two
    # bare `herdr <args>` invocations may exist — the ones inside run_herdr and
    # run_herdr_quiet themselves.
    assert "hrdr routes ALL herdr calls through the run_herdr helpers" \
        "[[ \$(grep -cE '^[[:space:]]*herdr ' <<<\"\$hs\") -eq 2 ]]"
    # The trace and the exec must come from the SAME \"\$@\", or the trace prints
    # one command while another runs — the one bug that makes a verbose mode
    # worse than none, because it actively misinforms.
    #
    # COUNTED, not merely present: each helper must trace its own \"\$@\", so the
    # count is exactly 2. An earlier version of this assertion only checked the
    # string existed SOMEWHERE, and a mutation making run_herdr trace
    # `session list` while running `--session scratch` PASSED it — the other
    # helper still carried the string. Verified by mutation: breaking either
    # helper's trace takes the count to 1 and turns this red.
    assert "both run_herdr helpers trace their own \"\$@\" (no drift)" \
        "[[ \$(grep -c 'trace_herdr \"\\\$@\"' <<<\"\$hs\") -eq 2 ]]"
    assert "both helpers exec herdr with that same \"\$@\"" \
        "[[ \$(grep -cE '^[[:space:]]*herdr \"\\\$@\"' <<<\"\$hs\") -eq 2 ]]"
    assert "hrdr honours HRDR_VERBOSE" "grep -q 'HRDR_VERBOSE' <<<\"\$hs\""
    assert "hrdr accepts a -v/--verbose flag" "grep -q '\\-v | --verbose' <<<\"\$hs\""
    # Traces go to stderr so `hrdr ls | …` keeps a clean stdout.
    assert "hrdr traces to stderr, not stdout" \
        "grep -q \"printf '+ herdr %s\\\\\\\\n' \\\"\\\$\\*\\\" >&2\" <<<\"\$hs\""
    # LOAD-BEARING: the list path silences herdr's own stderr. Redirecting the
    # whole call (run_herdr ... 2>/dev/null) would swallow the trace too —
    # exactly where a user asking "what is it running?" would look. The quiet
    # helper redirects only the command, so no call site may add its own.
    assert "hrdr's list path does not swallow its own trace" \
        "! grep -qE 'run_herdr(_quiet)? [^|]*2>/dev/null' <<<\"\$hs\""
    # jq is a hard dependency (fetcher slot 1 / installer phase 1); the plain
    # table is space-aligned and would mis-parse silently.
    assert "hrdr requires jq explicitly" \
        "grep -q 'command -v jq' <<<\"\$hs\""
    assert "hrdr parses the --json session list" \
        "grep -q 'session list --json' <<<\"\$hs\""

    # LOAD-BEARING NEGATIVE 1 — the safety ruling. herdr's pane commands take no
    # --session/--socket selector and the CLI reaches the RUNNING server
    # regardless of \$HOME, so a layout routine could split panes in a session
    # the user did not create. hrdr must never call one.
    assert "hrdr issues NO pane-split/layout calls" \
        "! grep -Eq 'pane (split|swap|move|resize)' <<<\"\$hs\""
    # LOAD-BEARING NEGATIVE 2 — the naming ruling. A \$USER- prefix would shadow
    # existing unprefixed sessions (default, qa-deb13-01-qng) with new ones.
    assert "hrdr does NOT prefix session names with \$USER" \
        "! grep -Eq 'whoami|UNAME=|\\\$USER-' <<<\"\$hs\""

    # herdr refuses to nest and has no switch-client equivalent (each named
    # session is its own server). Without the guard the user gets herdr's raw
    # nesting error, which never mentions detaching.
    assert "hrdr guards against running inside a herdr pane" \
        "grep -q 'HERDR_PANE_ID' <<<\"\$hs\""

    # The picker ATTACHES ONLY. Each destructive verb may appear exactly once —
    # in the explicit subcommand dispatch — so wiring either into the menu (or
    # adding a second call site) turns this red.
    assert "hrdr: 'session stop' has exactly one call site" \
        "[[ \$(grep -c 'session stop' <<<\"\$hs\") -eq 1 ]]"
    assert "hrdr: 'session delete' has exactly one call site" \
        "[[ \$(grep -c 'session delete' <<<\"\$hs\") -eq 1 ]]"

    # dotfiles-doctor greets ONCE per login session era: the first interactive
    # shell prints it, later shells (tmux panes) stay quiet. The one-shot is a
    # stamp in $XDG_RUNTIME_DIR, created atomically under `set -C`. The harness
    # unsets XDG_RUNTIME_DIR globally (line ~54), so this test supplies its own.
    if command -v zsh >/dev/null 2>&1; then
        sec "shell: dotfiles-doctor greets once per login session era"
        rt="$SB/run.greet"; rm -rf "$rt"; mkdir -p "$rt"
        greet() { ( cd /tmp && env -i HOME="$SB" TERM=xterm XDG_RUNTIME_DIR="$rt" PATH=/usr/bin:/bin zsh -ic true 2>/dev/null | tr -d '\r' ); }
        first="$(greet)"; second="$(greet)"
        assert "first interactive shell runs dotfiles-doctor"        "grep -q '^env:' <<<\"\$first\""
        assert "greet stamp created in \$XDG_RUNTIME_DIR"            "[[ -e '$rt/dotfiles-shell.greeted' ]]"
        assert "second interactive shell is quiet (one-shot spent)"  "[[ -z \"\$(tr -d '\r\n \t' <<<\"\$second\")\" ]]"
        v="$( cd /tmp && env -i HOME="$SB" TERM=xterm XDG_RUNTIME_DIR="$rt" DOTFILES_SHELL_VERBOSE=1 PATH=/usr/bin:/bin zsh -ic true 2>/dev/null | tr -d '\r' )"
        assert "DOTFILES_SHELL_VERBOSE forces the report despite the stamp" "grep -q '^env:' <<<\"\$v\""
        rm -rf "$rt"
    fi
else
    skip "apply/parity/idempotency (no chezmoi binary)"
fi

# ===========================================================================
sec "installer --dry-run: all phases, no side effects"
before="$(git -C "$REPO" status --porcelain)"
out="$(HOME="$SB" ./update-user-home-dir.sh --dry-run 2>&1)"; rc=$?
after="$(git -C "$REPO" status --porcelain)"
assert "dry-run exits 0"                     "[[ $rc -eq 0 ]]"
assert "dry-run reaches Phase 1 (jq FIRST)"  "grep -q 'Phase 1: jq' <<<\"\$out\""
assert "dry-run reaches Phase 2 (chezmoi)"   "grep -q 'Phase 2: chezmoi binary' <<<\"\$out\""
assert "dry-run reaches Phase 3 (secrets)"   "grep -q 'Phase 3: secrets bootstrap' <<<\"\$out\""
assert "dry-run reaches Phase 4 (apply)"     "grep -q 'Phase 4: chezmoi apply' <<<\"\$out\""
assert "dry-run reaches Phase 5 (fetchers)"  "grep -q 'Phase 5: tool fetchers' <<<\"\$out\""
assert "dry-run reaches Phase 6 (ssh-agent)" "grep -q 'Phase 6: ssh-agent' <<<\"\$out\""
assert "dry-run shows the secrets nudge"     "grep -q 'Secrets (~/.keys)' <<<\"\$out\""
# jq before chezmoi, and secrets (age) before apply — the two bootstrap orderings
# the fresh-machine fixes depend on. Compare line positions in the ordered output.
_pos() { grep -n "$1" <<<"$out" | head -1 | cut -d: -f1; }
assert "jq phase precedes chezmoi phase"      "[[ \$(_pos 'Phase 1: jq') -lt \$(_pos 'Phase 2: chezmoi binary') ]]"
assert "age/secrets phase precedes apply"     "[[ \$(_pos 'Phase 3: secrets') -lt \$(_pos 'Phase 4: chezmoi apply') ]]"
assert "Phase 6 skips without a session bus" "grep -q 'skipped: no user session bus' <<<\"\$out\""
assert "no repo contamination from dry-run"  "[[ \"\$before\" == \"\$after\" ]]"

# ===========================================================================
sec "bootstrap: jq is fetched FIRST and jq-free (fresh-machine fix)"
# jq is the ONE tool that must bootstrap without jq — every other fetcher, and
# chezmoi's own fetch, parse GitHub release JSON with it. Assert fetch_jq exists
# and uses the jq-free tag helper, never the jq-dependent gh_* helpers.
jqbody="$( . "$LIB" >/dev/null 2>&1; declare -f fetch_jq )"
assert "fetch_jq is defined in _lib.sh"           "[[ -n \"\$jqbody\" ]]"
assert "fetch_jq uses gh_latest_tag_nojq"         "grep -q 'gh_latest_tag_nojq' <<<\"\$jqbody\""
assert "fetch_jq avoids the jq-dependent gh_ helpers" "! grep -Eq 'gh_asset_url|gh_latest_tag[^_]' <<<\"\$jqbody\""
# fb_init must put ~/.local/bin on PATH, or a just-fetched jq is invisible to the
# bare \`jq\` calls in every later fetcher within the same installer run.
pth="$( . "$LIB" >/dev/null 2>&1; PATH=/usr/bin:/bin; fb_init >/dev/null 2>&1; printf '%s' "$PATH" )"
assert "fb_init prepends \$BIN_DIR to PATH"        "case \":\$pth:\" in *\":$BIN_DIR:\"*) true ;; *) false ;; esac"
# The installer bootstraps jq in Phase 1 and skips 01_fetch.jq.sh in the loop.
assert "installer skips 01_fetch.jq.sh in fetcher loop" "grep -q '01_fetch.jq.sh ]] && continue' update-user-home-dir.sh"

# ===========================================================================
sec "secrets: age encryption is wired public-repo-safe"
AGEBLOB="home/encrypted_private_dot_keys.age"
# The encrypted secrets blob (working tree = what gets committed) is CIPHERTEXT.
assert "encrypted secrets blob present"            "[[ -f $AGEBLOB ]]"
assert "blob is age ciphertext (armored header)"   "head -1 $AGEBLOB 2>/dev/null | grep -q 'BEGIN AGE ENCRYPTED FILE'"
assert "blob leaks no var names / key material"    "! grep -qiE 'API_KEY|ANTHROPIC|OPENAI|GEMINI|XAI|HF_TOKEN|sk-' $AGEBLOB"
# The private identity must never be tracked, and must be ignored at any depth.
assert "age identity (key.txt) is gitignored"      "git check-ignore key.txt >/dev/null"
assert "no key.txt tracked anywhere"               "! git ls-files | grep -q 'key.txt'"
# Config template: PUBLIC recipient committed, machine-specific bits as placeholders.
assert "chezmoi.toml.template present"              "[[ -f chezmoi.toml.template ]]"
assert "template carries a public age recipient"    "grep -qE 'recipient = \"age1[0-9a-z]+\"' chezmoi.toml.template"
assert "template keeps __SOURCE_DIR__ placeholder"  "grep -q '__SOURCE_DIR__' chezmoi.toml.template"
assert "template sets encryption = age"             "grep -q 'encryption = \"age\"' chezmoi.toml.template"
# fetch_age bootstrap helper installs BOTH age and age-keygen.
agebody="$( . "$LIB" >/dev/null 2>&1; declare -f fetch_age )"
assert "fetch_age defined in _lib.sh"               "[[ -n \"\$agebody\" ]]"
assert "fetch_age installs age AND age-keygen"      "grep -q 'age-keygen' <<<\"\$agebody\""
# Installer wiring: secrets phase exists, is before apply, and the loop skips age.
assert "installer has the secrets (age) phase"      "grep -q 'Phase 3: secrets bootstrap (age)' update-user-home-dir.sh"
assert "installer skips 14_fetch.age.sh in loop"    "grep -q '14_fetch.age.sh ]] && continue' update-user-home-dir.sh"
assert "config rendered before the apply phase"     "[[ \$(grep -n 'chezmoi.toml.template' update-user-home-dir.sh | head -1 | cut -d: -f1) -lt \$(grep -n 'Phase 4: chezmoi apply' update-user-home-dir.sh | cut -d: -f1) ]]"
# Keyless machines apply cleanly: .chezmoiignore drops .keys when no identity.
assert ".chezmoiignore guards .keys on missing key" "grep -q 'key.txt' home/.chezmoiignore"
# Keys/doctor: implementation at repo root; chezmoi entries are trampolines.
assert "root keys CLI present"                      "[[ -x keys ]]"
assert "root keys CLI is valid bash"                "bash -n keys"
assert "root doctor CLI present"                    "[[ -x doctor ]]"
assert "root doctor CLI is valid sh"                "sh -n doctor"
assert "root apply CLI present"                     "[[ -x apply ]]"
assert "root status CLI present"                    "[[ -x status ]]"
assert "root help CLI present"                      "[[ -x help ]]"
assert "Makefile help facade present"               "[[ -f Makefile ]]"
assert "doctor registry single-sourced in lib/"     "[[ -f lib/doctor-registry.sh ]]"
assert "dotfiles-keys trampoline present"           "[[ -f home/dot_local/bin/executable_dotfiles-keys ]]"
assert "dotfiles-keys trampoline is valid sh"       "sh -n home/dot_local/bin/executable_dotfiles-keys"
assert "dotfiles-keys trampoline stays thin"        "[[ \$(wc -l < home/dot_local/bin/executable_dotfiles-keys) -le 50 ]]"
assert "dotfiles-keys trampoline execs ./keys"      "grep -q root/keys home/dot_local/bin/executable_dotfiles-keys"
assert "dotfiles-doctor trampoline present"         "[[ -f home/dot_local/bin/executable_dotfiles-doctor ]]"
assert "dotfiles-doctor trampoline is valid sh"     "sh -n home/dot_local/bin/executable_dotfiles-doctor"
assert "dotfiles-doctor trampoline stays thin"      "[[ \$(wc -l < home/dot_local/bin/executable_dotfiles-doctor) -le 50 ]]"
assert "dotfiles-doctor trampoline execs ./doctor"  "grep -q root/doctor home/dot_local/bin/executable_dotfiles-doctor"

# ===========================================================================
# Structural checks for the podman fetcher — source-only (grep/bash -n), so they
# run in every group. The real fetch is 32 MB and network-gated behind --podman
# (below), and MUST NOT run in the default group.
sec "structural: podman fetcher wiring (no network)"
PODMAN_FETCHER="home/dot_local/bin/fetch.bins/executable_12_fetch.podman.sh"
assert "podman fetcher present"                     "[[ -f $PODMAN_FETCHER ]]"
assert "podman fetcher is valid bash"               "bash -n $PODMAN_FETCHER"
assert "podman fetcher sources _lib.sh"             "grep -q '_lib.sh' $PODMAN_FETCHER"
assert "podman fetcher uses whole-tree extract"     "grep -q 'strip-components=1' $PODMAN_FETCHER"
assert "podman fetcher sets conmon_path (spike-critical)" "grep -q 'conmon_path' $PODMAN_FETCHER"
assert "podman fetcher generates containers.conf"   "grep -q 'containers.conf' $PODMAN_FETCHER"
assert "podman fetcher generates storage.conf"      "grep -q 'storage.conf' $PODMAN_FETCHER"
# The fetcher NAMES runroot in a comment ("OMIT runroot"), so assert it writes no
# runroot KEY (a `runroot = ...` TOML assignment), not that the word is absent.
assert "podman fetcher writes no runroot key"       "! grep -qE 'runroot[[:space:]]*=' $PODMAN_FETCHER"
assert "podman fetcher emits podman-rootless-setup" "grep -q 'podman-rootless-setup' $PODMAN_FETCHER"
# The generated setup script must itself be valid bash. Extract the quoted-heredoc
# body (between the `<<'SETUP_EOF'` open line and the bare `SETUP_EOF` close) and
# bash -n it, so a typo in the generated helper fails here, not at the user's sudo.
SETUP_TMP="$(mktemp)"
awk "/<<'SETUP_EOF'/{f=1; next} /^SETUP_EOF\$/{f=0} f" "$PODMAN_FETCHER" > "$SETUP_TMP"
assert "generated podman-rootless-setup is valid bash" "[[ -s $SETUP_TMP ]] && bash -n $SETUP_TMP"
rm -f "$SETUP_TMP"
# Doctor registry + protoc fold-in (protoc was removed in iter 27).
assert "doctor registry lists podman"               "grep -q 'podman|podman|' lib/doctor-registry.sh"
assert "protoc fully removed from doctor registry"  "! grep -q protoc lib/doctor-registry.sh"
assert "shell doctor.sh is thin wrapper only"       "grep -q 'dotfiles-doctor()' home/dot_config/shell/doctor.sh && ! grep -q 'df_doctor_registry' home/dot_config/shell/doctor.sh"
assert "protoc fully removed from installer"         "! grep -q protoc update-user-home-dir.sh"
# Installer uninstall special-case for podman (versioned dir + generated helper).
assert "installer uninstall handles podman versioned dir" "grep -q 'podman-\*' update-user-home-dir.sh"
assert "installer uninstall removes podman-rootless-setup" "grep -q 'podman-rootless-setup' update-user-home-dir.sh"

# ===========================================================================
# Structural checks for the ghostty AppImage fetcher (slot 16) — source only,
# run in every group. Ghostty is the ONLY AppImage in fetch.bins/, so several
# invariants here have no other fetcher to lean on: it must gate on a display
# (48 MB GUI download), must NOT route through install_bin (whose hardcoded
# ~/.local/apps/<name> destination cannot carry a version, which is what makes
# the no-redownload fast path possible), must carry a no-FUSE fallback, and must
# install the bundled xterm-ghostty terminfo — without which ghostty's default
# TERM is unresolvable outside the AppImage (the ssh breakage).
sec "structural: ghostty AppImage fetcher (slot 16, no network)"
GH_FETCHER="home/dot_local/bin/fetch.bins/executable_16_fetch.ghostty.sh"
assert "ghostty fetcher present"                    "[[ -f $GH_FETCHER ]]"
assert "ghostty fetcher is valid bash"              "bash -n $GH_FETCHER"
assert "ghostty fetcher sources _lib.sh"            "grep -q '_lib.sh' $GH_FETCHER"
assert "ghostty fetcher gates on a display"         "grep -q 'require_display_or_skip' $GH_FETCHER"
assert "ghostty fetcher never CALLS install_bin"    "! grep -qE '^[[:space:]]*install_bin[[:space:]]' $GH_FETCHER"
assert "ghostty fetcher installs a versioned image" "grep -q 'BIN_NAME}-\${VERSION}.AppImage' $GH_FETCHER"
assert "ghostty fetcher has a no-redownload path"   "grep -q 'already installed' $GH_FETCHER"
assert "ghostty fetcher prunes old versions"        "grep -q 'pruned old version' $GH_FETCHER"
assert "ghostty fetcher carries a no-FUSE fallback" "grep -q 'APPIMAGE_EXTRACT_AND_RUN' $GH_FETCHER"
assert "ghostty fetcher probes for FUSE"            "grep -q '/dev/fuse' $GH_FETCHER"
# Pattern extraction keeps this to ~4 KB; a bare --appimage-extract unpacks 153 MB.
assert "ghostty fetcher extracts BY PATTERN"        "grep -qF -e '--appimage-extract \"\$pattern\"' $GH_FETCHER"
assert "ghostty fetcher installs xterm-ghostty"     "grep -q '.terminfo/x/xterm-ghostty' $GH_FETCHER"
assert "ghostty fetcher rewrites desktop Exec"      "grep -q 's|^Exec=' $GH_FETCHER"
assert "ghostty fetcher rewrites desktop TryExec"   "grep -q 's|^TryExec=' $GH_FETCHER"
assert "ghostty fetcher verifies before symlink"    "grep -q 'verification failed' $GH_FETCHER"
assert "doctor registry lists ghostty"              "grep -q 'ghostty|ghostty|' lib/doctor-registry.sh"
# Uninstall lockstep: a bare remove_bin would strand the versioned image, the
# desktop entry, the icon and the terminfo entry.
assert "installer uninstall handles ghostty image"  "grep -q 'ghostty-\*.AppImage' update-user-home-dir.sh"
assert "installer uninstall removes ghostty desktop" "grep -q 'com.mitchellh.ghostty.desktop' update-user-home-dir.sh"
assert "installer uninstall removes ghostty terminfo" "grep -q 'terminfo/x/xterm-ghostty' update-user-home-dir.sh"
# Regression: tree-sitter shipped as slot 15 in iter 30 but was never added to
# the removal loop, so --uninstall --force stranded it. Every fetcher must map
# to the loop, a special case, or the rust block.
assert "installer uninstall covers tree-sitter"     "grep -qE '^[[:space:]]*for b in .*tree-sitter' update-user-home-dir.sh"

# The ghostty config is chezmoi-managed (NOT a uruntime portable sidecar), so a
# fresh machine reproduces it. It must stay coherent with the repo-wide theme
# and must NOT force TERM: the default xterm-ghostty is what the fetcher's
# terminfo install exists to support.
GH_CONF="home/dot_config/ghostty/config"
assert "ghostty config tracked in chezmoi source"   "[[ -f $GH_CONF ]]"
assert "ghostty config sets the catppuccin theme"   "grep -qi '^theme = Catppuccin Mocha' $GH_CONF"
assert "ghostty config pins an installed Nerd Font" "grep -q '^font-family = CaskaydiaCove Nerd Font' $GH_CONF"
assert "ghostty config leaves TERM at the default"  "! grep -qE '^term[[:space:]]*=' $GH_CONF"
assert "ghostty config propagates ssh terminfo"     "grep -q 'ssh-terminfo' $GH_CONF"

# alacritty was retired (no longer used, and the binary is not installed). Its
# source dir is gone; the already-applied copies are cleaned off every machine
# via .chezmoiignore's sibling, .chezmoiremove. rofi's `terminal:` used to point
# at it — a dangling reference to a missing binary — and now matches what
# hyprland/sway already spawn.
assert "alacritty source dir removed"               "[[ ! -d home/dot_config/alacritty ]]"
# Scope: the chezmoi source + README, i.e. everything that reaches a machine or
# describes it. .chezmoiremove is excluded because retiring the applied copies
# REQUIRES naming them, and this harness is excluded because these very asserts
# name it too — a bare repo-wide grep would match its own source text.
assert "no alacritty refs in source or README"      "! grep -rin --exclude=.chezmoiremove alacritty home README.md"
assert ".chezmoiremove retires applied alacritty"   "grep -q '^.config/alacritty\$' home/.chezmoiremove"
assert "rofi terminal is an installed emulator"     "grep -qE '^[[:space:]]*terminal: \"(kitty|ghostty)\";' home/dot_config/rofi/config.rasi"

# kitty takes the LAST occurrence of a setting, so a second active font_family
# silently overrides the first. kitty.conf carried a trailing
# `font_family monospace` that beat the line above it, so the terminal rendered
# in the fontconfig default no matter what the earlier line said. Assert exactly
# ONE active line for each — a COUNT, because the failure mode is a duplicate
# that greps clean when you look for the value you expect to find.
KCONF="home/dot_config/kitty/kitty.conf"
assert "kitty: exactly one active font_family"      "[[ \$(grep -cE '^font_family' $KCONF) -eq 1 ]]"
assert "kitty: exactly one active font_size"        "[[ \$(grep -cE '^font_size' $KCONF) -eq 1 ]]"
assert "kitty: font is CaskaydiaCove Mono"          "grep -qE '^font_family[[:space:]]+CaskaydiaCove Nerd Font Mono\$' $KCONF"
# Terminal font size is unified at 10 across both emulators (iter 34). Picked by
# dialing kitty down live with ctrl+shift+minus (2 presses off the 14 default,
# -2.0 each) and pinning the result — runtime resizes are per-session and are
# never written back to the config, so without this the value resets on restart.
assert "kitty: font_size unified at 10"             "grep -qE '^font_size[[:space:]]+10(\.0)?\$' $KCONF"
assert "ghostty: font-size unified at 10"           "grep -qE '^font-size = 10\$' $GH_CONF"
# The dormant variants were deleted: nothing ever selected them, and um690 was a
# near-duplicate of kitty.conf that still carried the stale jetbrains font.
assert "dormant kitty variants removed"             "[[ ! -e home/dot_config/kitty/kitty.um690.conf && ! -e home/dot_config/kitty/kitty.typecraft.conf ]]"

# Ruling (iter 36): kitty is the DEFAULT terminal, ghostty is OPT-IN. Both stay
# managed, but every automated spawn point names kitty. These assert that ruling
# so a partial switch cannot land — promoting ghostty means moving all four
# together, and a half-move is how two terminal configs start drifting.
assert "hyprland \$terminal is kitty"                "grep -qE '^\\\$terminal = kitty\$' home/dot_config/hypr/hyprland.conf"
assert "hyprland autostarts kitty"                  "grep -qE '^exec-once = .*\\bkitty\\b' home/dot_config/hypr/hyprland.conf"
assert "sway \$term is kitty"                        "grep -qE '^set \\\$term kitty\$' home/dot_config/sway/config"
assert "rofi terminal is kitty"                     "grep -qE '^[[:space:]]*terminal: \"kitty\";\$' home/dot_config/rofi/config.rasi"
assert ".chezmoiremove retires kitty variants"      "grep -q '^.config/kitty/kitty.um690.conf\$' home/.chezmoiremove"
# kitty.conf still includes the theme file, so it must survive the variant purge.
assert "kitty theme include still resolves"         "grep -q '^include current-theme.conf\$' $KCONF && [[ -f home/dot_config/kitty/current-theme.conf ]]"

# ===========================================================================
# Structural checks for the nvim runtime fix + tree-sitter CLI fetcher — source
# only, run in every group. The nvim fetcher must NEVER route through
# install_bin: its copy step detaches the binary from the release tree, nvim
# then can't find its runtime (VIMRUNTIME falls back to compile-time
# /usr/local paths) and startup floods with E5113/E484.
sec "structural: nvim in-place symlink + tree-sitter fetcher wiring (no network)"
NVIM_FETCHER="home/dot_local/bin/fetch.bins/executable_07_fetch.nvim.sh"
assert "nvim fetcher is valid bash"                 "bash -n $NVIM_FETCHER"
assert "nvim fetcher never CALLS install_bin"       "! grep -qE '^[[:space:]]*install_bin[[:space:]]' $NVIM_FETCHER"
assert "nvim fetcher symlinks into versioned tree"  "grep -q 'ln -sfn \"\$NVIM_BIN\"' $NVIM_FETCHER"
assert "nvim fetcher removes legacy detached copy"  "grep -q 'rm -f \"\${APP_DIR}/\${BIN_NAME}\"' $NVIM_FETCHER"
TS_FETCHER="home/dot_local/bin/fetch.bins/executable_15_fetch.tree-sitter.sh"
assert "tree-sitter fetcher present"                "[[ -f $TS_FETCHER ]]"
assert "tree-sitter fetcher is valid bash"          "bash -n $TS_FETCHER"
assert "tree-sitter fetcher sources _lib.sh"        "grep -q '_lib.sh' $TS_FETCHER"
assert "tree-sitter fetcher gunzips the bare .gz"   "grep -q 'gunzip' $TS_FETCHER"
assert "doctor registry lists tree-sitter"          "grep -q 'tree-sitter|tree-sitter|' lib/doctor-registry.sh"

# herdr (slot 17) is the ONLY fetcher whose asset needs no extraction at all —
# the release ships a bare, uncompressed binary — so the invariants worth pinning
# are about SELECTION, which is where a bare-binary fetcher can silently go wrong.
# Two traps, both proven by the tools already here:
#   1. fb_arch can NEVER emit `aarch64` (its sed hardcodes s/aarch64/arm64/), so a
#      fetcher whose assets use raw uname tokens must not call it. Calling it would
#      pass on x86_64 and 404 on every arm64 box — invisible on this machine.
#   2. The release also ships herdr-macos-x86_64, so `contains($arch)` would match
#      a macOS binary on a linux host. The selector must be an EXACT name match.
HD_FETCHER="home/dot_local/bin/fetch.bins/executable_17_fetch.herdr.sh"
assert "herdr fetcher present"                      "[[ -f $HD_FETCHER ]]"
assert "herdr fetcher is valid bash"                "bash -n $HD_FETCHER"
assert "herdr fetcher sources _lib.sh"              "grep -q '_lib.sh' $HD_FETCHER"
# Comment-aware: the fetcher's header DOCUMENTS why fb_arch is unusable, so a bare
# grep matches the explanation. Skip comment lines. awk, not `grep -v | grep -q`:
# under this harness's pipefail a short-circuiting grep -q SIGPIPEs the producer.
assert "herdr fetcher never CALLS fb_arch"          "awk '/^[[:space:]]*#/{next} /fb_arch/{f=1} END{exit f?1:0}' $HD_FETCHER"
assert "herdr fetcher uses raw uname -m"            "grep -qE 'ARCH=\"\\\$\\(uname -m\\)\"' $HD_FETCHER"
assert "herdr fetcher matches the asset EXACTLY"    "grep -qF '. == (\"herdr-linux-\" + \$arch)' $HD_FETCHER"
assert "herdr fetcher goes through install_bin"     "grep -qE '^[[:space:]]*install_bin[[:space:]]' $HD_FETCHER"
assert "herdr fetcher has no extraction step"       "! grep -qE '(tar -x|gunzip|fb_unzip|appimage-extract)' $HD_FETCHER"
assert "doctor registry lists herdr"                "grep -q 'herdr|herdr|' lib/doctor-registry.sh"
# Same lockstep regression tree-sitter shipped with in iter 30: a fetcher that is
# absent from the removal loop is stranded by --uninstall --force.
assert "installer uninstall covers herdr"           "grep -qE '^[[:space:]]*for b in .*\\bherdr\\b' update-user-home-dir.sh"
# nvim-treesitter main-branch migration: the old configs-module API must be
# gone from the config source, and the duplicate custom spec stays deleted
# (its go/rust parsers are folded into the kickstart spec).
TS_SPEC="home/dot_config/nvim-kickstart-modular/lua/kickstart/plugins/treesitter.lua"
assert "treesitter spec pins branch = 'main'"       "grep -q \"branch = 'main'\" $TS_SPEC"
assert "treesitter spec installs go+rust parsers"   "grep -q \"'go',\" $TS_SPEC && grep -q \"'rust',\" $TS_SPEC"
assert "no nvim-treesitter.configs left in config"  "! grep -rq 'nvim-treesitter.configs' home/dot_config/nvim-kickstart-modular/"
assert "duplicate custom treesitter spec removed"   "[[ ! -e home/dot_config/nvim-kickstart-modular/lua/custom/plugins/treesitter.lua ]]"

# lazy-lock.json is tracked so fresh machines `Lazy! restore` to a verified
# plugin set instead of floating to latest. It must stay valid JSON with a
# pinned lazy.nvim entry (jq is a phase-1 install, present on any working box).
LAZY_LOCK="home/dot_config/nvim-kickstart-modular/lazy-lock.json"
assert "lazy-lock.json tracked in nvim source"      "[[ -f $LAZY_LOCK ]]"
assert "lazy-lock.json is valid JSON"               "jq empty $LAZY_LOCK"
assert "lazy-lock.json pins lazy.nvim itself"       "jq -e '.[\"lazy.nvim\"].commit' $LAZY_LOCK >/dev/null"

# Format-on-save consolidation: conform is the ONLY formatter driver. none-ls
# must stay diagnostics-only (its old vim.lsp.buf.format autocmd re-formatted
# every buffer conform had just formatted), no GoFormat autocmd may return
# (go.nvim's goimports() is an async gopls action that can write after the
# save), and python must keep ruff_organize_imports or import sorting is lost.
NVIM_LUA="home/dot_config/nvim-kickstart-modular/lua"
assert "conform python keeps import sorting"        "grep -q 'ruff_organize_imports' $NVIM_LUA/custom/plugins/conform.lua"
assert "none-ls has no formatting sources"          "! grep -qE 'builtins\.formatting|LspFormatting' $NVIM_LUA/custom/plugins/none-ls.lua"
assert "no GoFormat autocmd in config"              "! grep -rq \"nvim_create_augroup('GoFormat'\" $NVIM_LUA/"
assert "duplicate kickstart conform spec removed"   "[[ ! -e $NVIM_LUA/kickstart/plugins/conform.lua ]]"
assert "fzf-lua dependency removed"                 "! grep -rq 'ibhagwan/fzf-lua' $NVIM_LUA/"
assert "mason-null-ls removed"                      "! grep -rq 'mason-null-ls' $NVIM_LUA/"
assert "unused host providers disabled"             "grep -q 'loaded_node_provider = 0' home/dot_config/nvim-kickstart-modular/init.lua"

# ===========================================================================
if [[ $NET == 1 ]]; then
    sec "network: fetch_chezmoi + a real fetcher (jq) + remove_bin"
    ( set +e; . "$LIB" >/dev/null 2>&1; fb_init; fetch_chezmoi >/dev/null 2>&1 )
    assert "fetch_chezmoi installed a working binary" "\"$BIN_DIR/chezmoi\" --version >/dev/null 2>&1"
    # fetch.bins were applied into ~ during the apply group; run jq from there
    if [[ -x "$SB/.local/bin/fetch.bins/01_fetch.jq.sh" ]]; then
        "$SB/.local/bin/fetch.bins/01_fetch.jq.sh" >/dev/null 2>&1
        assert "jq fetched + runnable from applied ~" "\"$BIN_DIR/jq\" --version >/dev/null 2>&1"
        ( set +e; . "$LIB" >/dev/null 2>&1; remove_bin jq >/dev/null 2>&1 )
        assert "remove_bin removed jq symlink"        "[[ ! -e \"$BIN_DIR/jq\" ]]"
    else
        skip "jq fetcher not present (apply group did not run)"
    fi

    # The fresh-machine proof: fetch_jq must install a working jq WITHOUT ever
    # shelling out to jq. Poison bare `jq` inside the subshell — any accidental
    # `jq` call (e.g. via the jq-dependent gh_ helpers) returns 127 and aborts
    # the fetch — while install_bin's path invocation of the downloaded binary
    # ("$src" --version) is unaffected. If the install still succeeds, the
    # bootstrap is genuinely jq-free.
    sec "network: jq bootstraps with bare \`jq\` poisoned (no jq dependency)"
    ( set +e; . "$LIB" >/dev/null 2>&1
      jq() { echo "FAIL: fetch_jq shelled out to jq" >&2; return 127; }
      remove_bin jq >/dev/null 2>&1
      fb_init; fetch_jq >/dev/null 2>&1 )
    assert "fetch_jq installed a working jq with jq poisoned" "\"$BIN_DIR/jq\" --version >/dev/null 2>&1"

    # age is a bootstrap tool (chezmoi decrypts ~/.keys with it during apply).
    # Prove fetch_age installs BOTH binaries, then drive a full encrypt -> apply
    # -> 0600 round-trip with a THROWAWAY key. (The committed blob is encrypted to
    # the real key, which the sandbox never has, so we mint our own here.)
    sec "network: age bootstrap + chezmoi encrypt/apply round-trip"
    ( set +e; . "$LIB" >/dev/null 2>&1; remove_bin age >/dev/null 2>&1; remove_bin age-keygen >/dev/null 2>&1; fb_init; fetch_age >/dev/null 2>&1 )
    assert "fetch_age installed a working age"     "\"$BIN_DIR/age\" --version >/dev/null 2>&1"
    assert "fetch_age installed age-keygen"        "[[ -x \"$BIN_DIR/age-keygen\" ]]"
    if [[ -x "$BIN_DIR/age" && -x "$CHEZMOI" ]]; then
        RT="$(mktemp -d)"; mkdir -p "$RT/src" "$RT/dst/.config/chezmoi"
        rcpt="$("$BIN_DIR/age-keygen" -o "$RT/dst/.config/chezmoi/key.txt" 2>&1 | grep -oE 'age1[0-9a-z]+')"
        chmod 600 "$RT/dst/.config/chezmoi/key.txt"
        # Config must live at HOME/.config/chezmoi (not passed via --config, whose
        # directory chezmoi treats as "protected" and refuses to add files beneath).
        printf 'encryption = "age"\n[age]\n  identity = "%s/dst/.config/chezmoi/key.txt"\n  recipient = "%s"\n' "$RT" "$rcpt" > "$RT/dst/.config/chezmoi/chezmoi.toml"
        printf 'export RT_SECRET=hunter2\n' > "$RT/dst/.keys"; chmod 600 "$RT/dst/.keys"
        cz() { HOME="$RT/dst" XDG_CONFIG_HOME="$RT/dst/.config" PATH="$BIN_DIR:$PATH" "$CHEZMOI" --source "$RT/src" --destination "$RT/dst" --no-tty "$@"; }
        cz add --encrypt "$RT/dst/.keys" >/dev/null 2>&1
        assert "round-trip: source blob is ciphertext"     "head -1 \"$RT/src/encrypted_private_dot_keys.age\" 2>/dev/null | grep -q 'BEGIN AGE ENCRYPTED FILE'"
        assert "round-trip: blob hides the secret value"   "[[ -s \"$RT/src/encrypted_private_dot_keys.age\" ]] && ! grep -q 'hunter2' \"$RT/src/encrypted_private_dot_keys.age\""
        rm -f "$RT/dst/.keys"
        cz apply --force "$RT/dst/.keys" >/dev/null 2>&1
        assert "round-trip: apply re-materialized ~/.keys" "[[ -r \"$RT/dst/.keys\" ]]"
        assert "round-trip: applied secret is mode 0600"   "[[ \"\$(stat -c %a \"$RT/dst/.keys\" 2>/dev/null)\" == 600 ]]"
        assert "round-trip: decrypted content is correct"  "grep -q 'RT_SECRET=hunter2' \"$RT/dst/.keys\""
        rm -rf "$RT"
    else
        skip "chezmoi+age round-trip (age or chezmoi unavailable)"
    fi

    # ninja is a small, fast release-zip fetcher -> default group.
    sec "network: zip-based fetchers (ninja)"
    if [[ -x "$SB/.local/bin/fetch.bins/11_fetch.ninja.sh" ]]; then
        "$SB/.local/bin/fetch.bins/11_fetch.ninja.sh" >/dev/null 2>&1
        assert "ninja installed + runnable"      "\"$BIN_DIR/ninja\" --version >/dev/null 2>&1"
        assert "ninja symlink -> ~/.local/apps"  "[[ \"\$(readlink -f \"$BIN_DIR/ninja\")\" == \"$APP_DIR\"/* ]]"
    else
        skip "ninja fetcher not present (apply group did not run)"
    fi

    # starship is a small static musl tarball -> default group. It is the prompt
    # for BOTH shells now, so a broken fetch degrades bash and zsh alike.
    sec "network: starship fetcher (shared prompt)"
    if [[ -x "$SB/.local/bin/fetch.bins/13_fetch.starship.sh" ]]; then
        "$SB/.local/bin/fetch.bins/13_fetch.starship.sh" >/dev/null 2>&1
        assert "starship installed + runnable"     "\"$BIN_DIR/starship\" --version >/dev/null 2>&1"
        assert "starship symlink -> ~/.local/apps" "[[ \"\$(readlink -f \"$BIN_DIR/starship\")\" == \"$APP_DIR\"/* ]]"
        # The merged rc calls `starship init <shell>` for both shells. That prints
        # only a bootstrap line that evals --print-full-init, so assert against
        # the full init — the code that actually installs the prompt hook.
        assert "starship init bash emits prompt hook" "\"$BIN_DIR/starship\" init bash --print-full-init | grep -q starship_precmd"
        assert "starship init zsh emits prompt hook"  "\"$BIN_DIR/starship\" init zsh  --print-full-init | grep -q starship_precmd"
    else
        skip "starship fetcher not present (apply group did not run)"
    fi
else
    skip "network tests (--no-net)"
fi

# ===========================================================================
if [[ -n "$CHEZMOI" && -x "$BIN_DIR/chezmoi" ]]; then
    sec "uninstall: preview lists managed files, removes nothing"
    up="$(HOME="$SB" ./update-user-home-dir.sh --uninstall 2>&1)"
    assert "uninstall preview lists 'would remove'" "grep -q 'would remove' <<<\"\$up\""
    assert "uninstall preview did NOT delete .zshrc" "[[ -e \"$SB/.zshrc\" ]]"
else
    skip "uninstall preview (needs chezmoi in sandbox BIN_DIR)"
fi

# ===========================================================================
if [[ $RUN_GO == 1 ]]; then
    sec "go fetcher (150 MB) — GOROOT resolves via in-place symlink"
    if [[ -x "$SB/.local/bin/fetch.bins/04_fetch.go.sh" ]]; then
        "$SB/.local/bin/fetch.bins/04_fetch.go.sh" >/dev/null 2>&1
        assert "go installed + runnable"        "\"$BIN_DIR/go\" version >/dev/null 2>&1"
        assert "GOROOT resolves (go env works)" "\"$BIN_DIR/go\" env GOROOT >/dev/null 2>&1"
    else
        skip "go fetcher not present (apply group did not run)"
    fi
else
    skip "go fetcher (pass --go or RUN_GO_FETCH=1 to enable)"
fi

# ===========================================================================
if [[ $RUN_RUST == 1 ]]; then
    sec "rust fetcher — rustup installs into ~/.cargo (standard layout)"
    if [[ -x "$SB/.local/bin/fetch.bins/10_fetch.rust.sh" ]]; then
        "$SB/.local/bin/fetch.bins/10_fetch.rust.sh" >/dev/null 2>&1
        assert "cargo installed + runnable"      "\"$SB/.cargo/bin/cargo\" --version >/dev/null 2>&1"
        assert "rustc installed + runnable"      "\"$SB/.cargo/bin/rustc\" --version >/dev/null 2>&1"
        assert "toolchains under ~/.rustup"      "[[ -d \"$SB/.rustup/toolchains\" ]]"
        # --no-modify-path: rustup must not scribble into shell profiles (chezmoi owns them)
        assert "no rustup PATH edit in .profile" "! grep -qs '\\.cargo/env' \"$SB/.profile\" \"$SB/.bash_profile\" \"$SB/.bashrc\" 2>/dev/null"
    else
        skip "rust fetcher not present (apply group did not run)"
    fi
else
    skip "rust fetcher (pass --rust or RUN_RUST_FETCH=1 to enable)"
fi

# ===========================================================================
if [[ $RUN_PODMAN == 1 ]]; then
    sec "podman fetcher (32 MB static) — whole-tree install + host-local config"
    if [[ -x "$SB/.local/bin/fetch.bins/12_fetch.podman.sh" ]]; then
        "$SB/.local/bin/fetch.bins/12_fetch.podman.sh" >/dev/null 2>&1
        # Headless-safe: XDG_RUNTIME_DIR is unset (line ~54) and the fetcher only
        # runs `podman --version` (never info/run), so no userns/runtime needed.
        assert "podman installed + --version works" "\"$BIN_DIR/podman\" --version >/dev/null 2>&1"
        assert "podman symlink -> ~/.local/apps"    "[[ \"\$(readlink -f \"$BIN_DIR/podman\")\" == \"$APP_DIR\"/* ]]"
        # XDG_CONFIG_HOME=$SB/.config, so the generated config lands here.
        CCONF="$SB/.config/containers/containers.conf"
        SCONF="$SB/.config/containers/storage.conf"
        assert "containers.conf generated with conmon_path" "[[ -f \"$CCONF\" ]] && grep -q conmon_path \"$CCONF\""
        assert "storage.conf generated and omits runroot"   "[[ -f \"$SCONF\" ]] && ! grep -q runroot \"$SCONF\""
        assert "podman-rootless-setup generated + executable + valid bash" \
            "[[ -x \"$BIN_DIR/podman-rootless-setup\" ]] && bash -n \"$BIN_DIR/podman-rootless-setup\""
    else
        skip "podman fetcher not present (apply group did not run)"
    fi
else
    skip "podman fetcher (pass --podman or RUN_PODMAN_FETCH=1 to enable)"
fi

# ===========================================================================
if [[ $RUN_GHOSTTY == 1 ]]; then
    sec "ghostty fetcher (48 MB AppImage) — versioned install + terminfo + desktop"
    if [[ -x "$SB/.local/bin/fetch.bins/16_fetch.ghostty.sh" ]]; then
        # The fetcher gates on a display (GUI tool); the sandbox unsets
        # XDG_RUNTIME_DIR/DBUS to simulate headless, so fake a session for the
        # duration of this group or require_display_or_skip exits 0 immediately.
        XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0 \
            "$SB/.local/bin/fetch.bins/16_fetch.ghostty.sh" >/dev/null 2>&1
        assert "ghostty installed + --version works"  "\"$BIN_DIR/ghostty\" --version >/dev/null 2>&1"
        # The symlink must resolve to a VERSIONED image, not a bare ~/.local/apps/ghostty
        # (that would mean it fell back to the install_bin shape and lost the fast path).
        assert "ghostty symlink -> versioned AppImage" \
            "[[ \"\$(readlink -f \"$BIN_DIR/ghostty\")\" == \"$APP_DIR\"/ghostty-*.AppImage ]]"
        # terminfo is what makes ghostty's default TERM resolvable outside the image.
        assert "xterm-ghostty terminfo installed"     "[[ -f \"$SB/.terminfo/x/xterm-ghostty\" ]]"
        assert "xterm-ghostty terminfo is readable"   "TERMINFO=\"$SB/.terminfo\" infocmp xterm-ghostty >/dev/null 2>&1"
        GH_DESK="$SB/.local/share/applications/com.mitchellh.ghostty.desktop"
        assert "ghostty desktop entry installed"      "[[ -f \"$GH_DESK\" ]]"
        # The shipped entry's Exec points at the CI build path (/__w/...), which
        # exists nowhere. If that survives, the launcher icon is dead.
        assert "desktop Exec no longer the CI path"   "! grep -q '/__w/' \"$GH_DESK\""
        assert "desktop Exec points at the symlink"   "grep -qE '^Exec=.*$BIN_DIR/ghostty' \"$GH_DESK\""
        # No bundled D-Bus service exists, so activation must be off or the icon
        # can silently fail to launch.
        assert "desktop DBusActivatable forced false" "! grep -qE '^DBusActivatable=true' \"$GH_DESK\""
        assert "ghostty icon installed"               "[[ -f \"$SB/.local/share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png\" ]]"
        # Second run must take the fast path: no re-download of 48 MB. Capture the
        # output instead of piping into `grep -q`: under `set -o pipefail`, grep -q
        # exits at the first match, the still-writing fetcher takes SIGPIPE, and the
        # pipeline reports failure even though the match succeeded.
        assert "re-run takes the no-download fast path" \
            "[[ \"\$(XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0 \"$SB/.local/bin/fetch.bins/16_fetch.ghostty.sh\" 2>&1)\" == *'already installed'* ]]"
    else
        skip "ghostty fetcher not present (apply group did not run)"
    fi
else
    skip "ghostty fetcher (pass --ghostty or RUN_GHOSTTY_FETCH=1 to enable)"
fi

# ===========================================================================
if [[ $RUN_HERDR == 1 ]]; then
    sec "herdr fetcher (21 MB bare binary) — no extraction step at all"
    if [[ -x "$SB/.local/bin/fetch.bins/17_fetch.herdr.sh" ]]; then
        "$SB/.local/bin/fetch.bins/17_fetch.herdr.sh" >/dev/null 2>&1
        # Headless-safe: herdr is a TUI, but --version neither opens a terminal
        # nor starts the server, so this needs no display and no pty.
        assert "herdr installed + --version works" "\"$BIN_DIR/herdr\" --version >/dev/null 2>&1"
        assert "herdr symlink -> ~/.local/apps"    "[[ \"\$(readlink -f \"$BIN_DIR/herdr\")\" == \"$APP_DIR\"/* ]]"
        # The whole point of the bare-binary path: what lands on PATH must be the
        # real ELF executable, not a tarball or a .gz that never got unpacked.
        assert "installed herdr is an ELF binary"  "head -c4 \"\$(readlink -f \"$BIN_DIR/herdr\")\" | grep -q ELF"
    else
        skip "herdr fetcher not present (apply group did not run)"
    fi
else
    skip "herdr fetcher (pass --herdr or RUN_HERDR_FETCH=1 to enable)"
fi

# ---- licensing -------------------------------------------------------------
# Dual MIT/Apache-2.0. The repo-root LICENSE is canonical and carries BOTH texts;
# there must be no split LICENSE-MIT / LICENSE-APACHE alongside it.
sec "structural: dual licensing"
assert "LICENSE present at repo root"          "[[ -f $REPO/LICENSE ]]"
assert "LICENSE carries the MIT text"          "grep -q 'Permission is hereby granted, free of charge' $REPO/LICENSE"
assert "LICENSE carries the Apache-2.0 text"   "grep -q 'Apache License' $REPO/LICENSE && grep -q 'Version 2.0, January 2004' $REPO/LICENSE"
assert "LICENSE names the copyright holder"    "grep -q 'John Suykerbuyk and SykeTech LTD' $REPO/LICENSE"
assert "no split LICENSE-MIT/-APACHE files"    "[[ ! -e $REPO/LICENSE-MIT && ! -e $REPO/LICENSE-APACHE ]]"
# The vendored kickstart.nvim tree keeps UPSTREAM's copyright. A SykeTech banner
# in there would assert copyright we do not hold and relicense their MIT as dual.
assert "vendored nvim keeps its own LICENSE"   "[[ -f $REPO/home/dot_config/nvim-kickstart-modular/LICENSE.md ]]"
assert "no SykeTech banner in vendored nvim"   "! grep -rql 'SykeTech LTD' $REPO/home/dot_config/nvim-kickstart-modular"
# Several scripts print their own header comment block as --help. The SPDX banner
# sits ABOVE that block, so a naive line-anchored extractor prints the banner and
# stops — which is exactly what happened when the banners first landed: two of
# these three emitted ONLY the copyright and no usage text at all.
for h in test-update-user-home-dir.sh \
         home/dot_local/bin/executable_setup-ssh-agent.sh \
         home/dot_local/bin/executable_agent-bootstrap.sh; do
    out="$(bash "$REPO/$h" --help 2>/dev/null)"
    assert "--help non-empty: $(basename "$h")"      "[[ \$(printf '%s' \"\$out\" | wc -l) -ge 3 ]]"
    assert "--help omits the banner: $(basename "$h")" "! printf '%s' \"\$out\" | grep -q 'SPDX-License-Identifier'"
done

# ---- summary ---------------------------------------------------------------
sec "summary"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && { echo "  ✅ all assertions passed"; exit 0; } || { echo "  ❌ failures above"; exit 1; }
