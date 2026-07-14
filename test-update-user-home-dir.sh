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
else
    skip "apply/parity/idempotency (no chezmoi binary)"
fi

# ===========================================================================
sec "installer --dry-run: all phases, no side effects"
before="$(git -C "$REPO" status --porcelain)"
out="$(HOME="$SB" ./update-user-home-dir.sh --dry-run 2>&1)"; rc=$?
after="$(git -C "$REPO" status --porcelain)"
assert "dry-run exits 0"                     "[[ $rc -eq 0 ]]"
assert "dry-run reaches Phase 1"             "grep -q 'Phase 1: chezmoi binary' <<<\"\$out\""
assert "dry-run reaches Phase 2 (apply)"     "grep -q 'Phase 2: chezmoi apply' <<<\"\$out\""
assert "dry-run reaches Phase 3 (fetchers)"  "grep -q 'Phase 3: tool fetchers' <<<\"\$out\""
assert "dry-run reaches Phase 4 (ssh-agent)" "grep -q 'Phase 4: ssh-agent' <<<\"\$out\""
assert "Phase 4 skips without a session bus" "grep -q 'skipped: no user session bus' <<<\"\$out\""
assert "no repo contamination from dry-run"  "[[ \"\$before\" == \"\$after\" ]]"

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
