#!/usr/bin/env bash
# test-update-user-home-dir.sh — integration tests for the chezmoi bootstrap.
#
# SAFE: runs entirely in an isolated sandbox HOME + XDG dirs (mktemp), never
# touches the real ~ or the repo working tree. Run from the dotfiles checkout:
#
#   ./test-update-user-home-dir.sh            # structural + light network (jq/chezmoi)
#   ./test-update-user-home-dir.sh --go       # also exercise the 150 MB Go fetch
#   ./test-update-user-home-dir.sh --rust     # also exercise the rustup toolchain fetch
#   RUN_GO_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_RUST_FETCH=1 ./test-update-user-home-dir.sh
#   ./test-update-user-home-dir.sh --no-net   # structural only (needs a chezmoi on PATH)
#
# ninja + protoc are small, fast release-zip fetchers, so they run in the default
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
NET=1
for a in "$@"; do
    case "$a" in
        --go) RUN_GO=1 ;;
        --rust) RUN_RUST=1 ;;
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
echo "repo=$REPO   go-fetch=$([[ $RUN_GO == 1 ]] && echo on || echo off)   rust-fetch=$([[ $RUN_RUST == 1 ]] && echo on || echo off)   network=$([[ $NET == 1 ]] && echo on || echo off)"

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
    if chz apply --force; then ok "chezmoi apply --force succeeded"; else bad "chezmoi apply failed"; fi

    sec "parity: every tracked source entry reproduced in ~"
    miss=0; diffc=0; modec=0; symc=0; excl=0; okc=0
    while IFS=$'\t' read -r meta path; do
        mode="${meta%% *}"; rel="${path#home/}"
        base="$(basename "$rel")"
        [[ "$base" == .chezmoi* ]] && continue          # chezmoi meta, not applied
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
assert "dry-run reaches Phase 3 (apply)"     "grep -q 'Phase 3: chezmoi apply' <<<\"\$out\""
assert "dry-run reaches Phase 4 (fetchers)"  "grep -q 'Phase 4: tool fetchers' <<<\"\$out\""
assert "dry-run reaches Phase 5 (ssh-agent)" "grep -q 'Phase 5: ssh-agent' <<<\"\$out\""
# jq must be bootstrapped BEFORE chezmoi — the whole fresh-machine fix. Compare
# the line positions in the ordered output, not just that both appear.
assert "jq phase precedes chezmoi phase"     "[[ \$(grep -n 'Phase 1: jq' <<<\"\$out\" | cut -d: -f1) -lt \$(grep -n 'Phase 2: chezmoi binary' <<<\"\$out\" | cut -d: -f1) ]]"
assert "Phase 5 skips without a session bus" "grep -q 'skipped: no user session bus' <<<\"\$out\""
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

    # ninja + protoc are small, fast release-zip fetchers -> default group.
    sec "network: zip-based fetchers (ninja, protoc)"
    if [[ -x "$SB/.local/bin/fetch.bins/11_fetch.ninja.sh" ]]; then
        "$SB/.local/bin/fetch.bins/11_fetch.ninja.sh" >/dev/null 2>&1
        assert "ninja installed + runnable"      "\"$BIN_DIR/ninja\" --version >/dev/null 2>&1"
        assert "ninja symlink -> ~/.local/apps"  "[[ \"\$(readlink -f \"$BIN_DIR/ninja\")\" == \"$APP_DIR\"/* ]]"
    else
        skip "ninja fetcher not present (apply group did not run)"
    fi
    if [[ -x "$SB/.local/bin/fetch.bins/12_fetch.protoc.sh" ]]; then
        "$SB/.local/bin/fetch.bins/12_fetch.protoc.sh" >/dev/null 2>&1
        assert "protoc installed + runnable"      "\"$BIN_DIR/protoc\" --version >/dev/null 2>&1"
        assert "protoc symlink -> ~/.local/apps"  "[[ \"\$(readlink -f \"$BIN_DIR/protoc\")\" == \"$APP_DIR\"/* ]]"
        # well-known types must resolve relative to the binary (../include)
        assert "protoc well-known include/ present" "[[ -f \"\$(dirname \"\$(dirname \"\$(readlink -f \"$BIN_DIR/protoc\")\")\")/include/google/protobuf/timestamp.proto\" ]]"
    else
        skip "protoc fetcher not present (apply group did not run)"
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

# ---- summary ---------------------------------------------------------------
sec "summary"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && { echo "  ✅ all assertions passed"; exit 0; } || { echo "  ❌ failures above"; exit 1; }
