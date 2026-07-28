#!/usr/bin/env bash
# test-update-user-home-dir.sh — integration tests for the chezmoi bootstrap.
#
# SAFE: runs entirely in an isolated sandbox HOME + XDG dirs (mktemp), never
# touches the real ~ or the repo working tree. Run from the dotfiles checkout:
#
#   ./test-update-user-home-dir.sh            # structural + light network (jq/chezmoi)
#   ./test-update-user-home-dir.sh --go       # also exercise the 150 MB Go fetch
#   ./test-update-user-home-dir.sh --rust     # also exercise the rustup toolchain fetch
#   ./test-update-user-home-dir.sh --podman   # also exercise the 32 MB podman static fetch
#   RUN_GO_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_RUST_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_PODMAN_FETCH=1 ./test-update-user-home-dir.sh
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
NET=1
for a in "$@"; do
    case "$a" in
        --go) RUN_GO=1 ;;
        --rust) RUN_RUST=1 ;;
        --podman) RUN_PODMAN=1 ;;
        --no-net) NET=0 ;;
        --help|-h) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//p}' "$0"; exit 0 ;;
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
echo "repo=$REPO   go-fetch=$([[ $RUN_GO == 1 ]] && echo on || echo off)   rust-fetch=$([[ $RUN_RUST == 1 ]] && echo on || echo off)   podman-fetch=$([[ $RUN_PODMAN == 1 ]] && echo on || echo off)   network=$([[ $NET == 1 ]] && echo on || echo off)"

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

# ---- summary ---------------------------------------------------------------
sec "summary"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && { echo "  ✅ all assertions passed"; exit 0; } || { echo "  ❌ failures above"; exit 1; }
