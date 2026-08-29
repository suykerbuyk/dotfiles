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
#   ./test-update-user-home-dir.sh --bins     # also exercise slots 18-21 (fd/bat/delta/xh, ~13 MB)
#   RUN_GO_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_RUST_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_PODMAN_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_GHOSTTY_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_HERDR_FETCH=1 ./test-update-user-home-dir.sh
#   RUN_BINS_FETCH=1 ./test-update-user-home-dir.sh
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
RUN_BINS="${RUN_BINS_FETCH:-0}"
NET=1
for a in "$@"; do
    case "$a" in
        --go) RUN_GO=1 ;;
        --rust) RUN_RUST=1 ;;
        --podman) RUN_PODMAN=1 ;;
        --ghostty) RUN_GHOSTTY=1 ;;
        --herdr) RUN_HERDR=1 ;;
        --bins) RUN_BINS=1 ;;
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
# Every failure is also accumulated, because printing it inline is not the same
# as being able to READ it: a full run emits 520 lines and the one 513/4 anomaly
# lost its FAIL list to scrollback. Recovering it by grep does not work either —
# `grep FAIL` matches PASS lines whose description contains the word (the POSIX
# positive control is literally "doctor.sh FAILS the POSIX parse"), and the ANSI
# colouring means it needs -a. So the summary re-prints them verbatim.
FAILED=()
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
# $2 is the evaluated assertion expression, with the captured value ALREADY
# interpolated. Printing it is what turns "which property broke" into "why":
# 18 asserts in this file compare a live-probed value inside a single-quoted
# `eval`, so a stray quote in the data yields `[[ 'ab'c' == HAS ]]` — a shell
# syntax error reported as an ordinary FAIL. The expr line shows that instantly.
# Ends in an explicit `return 0`: a trailing `[[ ]] && printf` would hand the
# test's status back to callers, and assert_file chains bad() through `||`.
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"
         [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
         return 0; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
sec()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
# Assertions are evaluated with pipefail OFF, then it is restored immediately.
# `producer | grep -q PATTERN` is a SIGPIPE RACE under `set -o pipefail`: grep -q
# exits at the FIRST match, the producer takes SIGPIPE and exits 141 if it has not
# finished writing by then, and pipefail promotes that 141 into a failed assertion
# on input that is perfectly correct. 16 assertions in this file have that shape,
# and the exposure is worst where the match is EARLY in a large file — the one that
# actually fired greps a 10 KB file whose match is on line 23 of 248.
# Measured: 1 spurious FAIL in 46 clean runs, total assertion count unchanged. That
# is the signature of the unreproduced 513/4 run (513+4 == 514+3 == 517: the set was
# identical and exactly one verdict flipped) and is the best explanation on record
# for it. An assertion's verdict is its FINAL predicate — never whether an upstream
# producer got to finish writing into a pipe nobody is reading any more.
# $? is captured on its own line, before anything else can overwrite it.
assert() {
    local _rc
    set +o pipefail
    eval "$2"
    _rc=$?
    set -o pipefail
    if [[ $_rc -eq 0 ]]; then ok "$1"; else bad "$1" "expr: $2"; fi
}
assert_file() { [[ -e "$2" ]] && ok "$1" || bad "$1 (missing: $2)"; }

# ---- value assertions ------------------------------------------------------
# assert() splices its expression into `eval`, which is right for expressions built
# from literals and WRONG for a value captured from a probe: the value is pasted in
# as SOURCE CODE, so one stray quote makes the shell parse `[[ 'ab'c' == HAS ]]` and
# the assertion dies of a syntax error that is indistinguishable from a real verdict.
# Proved by planting a quote in GOPATH — `unexpected EOF while looking for matching
# '`, reported as an ordinary FAIL against a config that was otherwise fine.
# These take the value as an ARGUMENT, so it stays data at every step and can never
# be parsed. Use them for anything a shell, a probe or a binary printed; keep
# assert() for expressions over literals, files and command exit status.
# They also report the value on failure, which the eval form could not: `[[ '' == HAS ]]`
# tells you the comparison failed and never what the probe actually said.
assert_eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got [$2]  want [$3]"; fi; }
assert_ne()    { if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1" "got [$2]  want anything but [$3]"; fi; }
# $3 unquoted on purpose in the two below: that is what makes it a pattern.
assert_glob()  { if [[ "$2" == $3   ]]; then ok "$1"; else bad "$1" "got [$2]  want glob [$3]"; fi; }
assert_re()    { if [[ "$2" =~ $3   ]]; then ok "$1"; else bad "$1" "got [$2]  want regex [$3]"; fi; }
assert_empty() { if [[ -z "$2"      ]]; then ok "$1"; else bad "$1" "got [$2]  want empty"; fi; }

# Comment-stripped view of a source file, for NEGATIVE and COUNTING asserts.
# Those must never read raw source: this repo documents at length WHY a rejected
# form was rejected, so a raw grep matches the file's own rationale and the
# assert either passes forever or fails forever. (Three asserts in this very
# section were written raw first and all three failed on their own comments.)
# Strips whole-line comments and trailing ones alike. `${VAR#prefix}` expansions
# get mangled as collateral, which is harmless for counting tokens but is why
# this is not used for positive exact-match asserts.
nocomment() { sed 's/#.*//' "$1"; }

# ---- discover a real POSIX shell -------------------------------------------
# `sh -n` is NOT a POSIX syntax check. Wherever /bin/sh is a symlink to bash
# (Arch, Fedora, most rpm distros) `sh` is just bash wearing a thin hat: it
# still accepts `a=(1 2 3)` and still accepts `foo-bar() { :; }`, a hyphenated
# function name that dash rejects outright with "Bad function name". This repo
# shipped that exact defect once while four asserts labelled "valid POSIX sh"
# stayed green through the whole thing. A checker that cannot fail is not a
# checker, so find a shell that can.
#
# Probe candidates in order and accept the first that PROVES it is not bash or
# zsh under an assumed name: run it and print $BASH_VERSION$ZSH_VERSION. A
# genuine POSIX shell has neither variable set and prints an EMPTY line; bash
# and zsh both leak their version even when invoked as `sh`.
#
# `sh` stays on the list (last) rather than being banned outright, because the
# answer is per-MACHINE, not per-distro: on Debian /bin/sh IS dash and must be
# accepted, on Arch it is bash and must be rejected. The probe decides; nothing
# here hardcodes a guess about which box the suite is running on.
POSIX_SH=""
for _cand in dash ash mksh posh yash sh; do
    command -v "$_cand" >/dev/null 2>&1 || continue
    [[ -z "$("$_cand" -c 'echo "${BASH_VERSION:-}${ZSH_VERSION:-}"' 2>/dev/null)" ]] || continue
    POSIX_SH="$(command -v "$_cand")"
    break
done
unset _cand

# ---- isolated sandbox ------------------------------------------------------
CHEZMOI_ON_PATH="$(command -v chezmoi 2>/dev/null || true)"   # capture before HOME moves
SB="$(mktemp -d)"
# Raw probe evidence lives OUTSIDE $SB deliberately: the parity walk and the
# plaintext-leak sweep both traverse the sandbox HOME, so a transcript in there
# would be test scaffolding masquerading as applied state. Kept only when the
# run has failures (see the summary); a green run takes it away.
EVID="$(mktemp -d)"
EVID_LOG="$EVID/probe-transcript.txt"
KEEP_EVID=0
trap 'rm -rf "$SB"; [[ $KEEP_EVID == 1 ]] || rm -rf "$EVID"' EXIT
export HOME="$SB"
export XDG_CONFIG_HOME="$SB/.config" XDG_CACHE_HOME="$SB/.cache" XDG_DATA_HOME="$SB/.local/share"
# The delta fetcher (slot 20) wires itself into git with `git config --global`.
# Overriding HOME is NOT enough on its own: GIT_CONFIG_GLOBAL takes precedence
# over $HOME/.gitconfig, so a developer who has it exported would have the REAL
# file rewritten by a test run. Pin it into the sandbox — the same class of
# hazard as a CLI reaching a running server regardless of $HOME.
export GIT_CONFIG_GLOBAL="$SB/.gitconfig"
unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS   # simulate headless -> Phase 4 must skip
BIN_DIR="$SB/.local/bin"; APP_DIR="$SB/.local/apps"

echo "sandbox HOME=$SB"
echo "repo=$REPO   go-fetch=$([[ $RUN_GO == 1 ]] && echo on || echo off)   rust-fetch=$([[ $RUN_RUST == 1 ]] && echo on || echo off)   podman-fetch=$([[ $RUN_PODMAN == 1 ]] && echo on || echo off)   ghostty-fetch=$([[ $RUN_GHOSTTY == 1 ]] && echo on || echo off)   herdr-fetch=$([[ $RUN_HERDR == 1 ]] && echo on || echo off)   bins-fetch=$([[ $RUN_BINS == 1 ]] && echo on || echo off)   network=$([[ $NET == 1 ]] && echo on || echo off)"

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

# ===========================================================================
# The POSIX `-n` checks read repo source and need no sandbox and no chezmoi, so
# this section sits at TOP LEVEL — deliberately outside the `if [[ -n
# "$CHEZMOI" ]]` block below. It also carries no opt-in flag: every gated group
# in this harness gates a network fetch (150 MB Go, 48 MB ghostty), and a
# handful of `-n` parses costs milliseconds, so the gating criterion does not
# apply. These run in the default structural group, i.e. under --no-net.
sec "POSIX shell contract"
if [[ -n "$POSIX_SH" ]]; then
    ok "POSIX shell found for -n checks: $POSIX_SH"

    # POSITIVE CONTROL — a file that must FAIL the checker.
    #
    # home/dot_config/shell/doctor.sh:16 defines `dotfiles-doctor()`. A
    # hyphenated function name is a hard syntax error in dash ("Bad function
    # name"), and that name is permanent and intentional: the interactive
    # command is spelled with a hyphen, so the function must be too.
    #
    # That makes it a planted mutation nobody had to plant and nobody can
    # accidentally revert. No scratch file, no temp fixture, no maintenance. If
    # this assert ever goes GREEN, the checker lost its teeth — POSIX_SH fell
    # back to something that is really bash — and every other `-n` assert in
    # this suite is a false green again. Pair it with the presence check: a
    # deleted doctor.sh also fails to parse, which would pass for the wrong
    # reason.
    #
    # It pins the layer boundary too. doctor.sh is rc-layer-only (sourced by
    # rc.sh) precisely BECAUSE dash cannot parse it; the env layer must stay
    # POSIX-parseable, so a file that fails here may never migrate into it.
    # This assert is what makes that rule enforced rather than merely written.
    assert_file "positive control source present" "home/dot_config/shell/doctor.sh"
    assert "positive control: doctor.sh FAILS the POSIX parse (hyphenated fn)" \
        "! \"\$POSIX_SH\" -n home/dot_config/shell/doctor.sh 2>/dev/null"

    # ---- SET A: the declared surface, discovered mechanically ---------------
    # A hardcoded list of filenames is a list that goes stale the day someone
    # adds a script, and nothing tells them — the same class of silent-drift
    # failure this whole section exists to kill. So do not keep one: a
    # `#!/bin/sh` line IS the file's declaration that it is POSIX, so let the
    # shebang be the enrolment criterion and let the scan find them.
    #
    # `git ls-files` rather than `find`: only TRACKED files are the repo's
    # contract. A scratch copy, an editor backup or a half-written script in
    # the working tree is nobody's promise and must not turn the suite red.
    #
    # Consequence, and the point: a new `#!/bin/sh` script added to this repo
    # is covered from its first commit, with no edit to this file.
    POSIX_SHEBANG_RE='^#![[:space:]]*(/bin/sh|/usr/bin/env[[:space:]]+sh)([[:space:]]|$)'
    POSIX_FILES=()
    while IFS= read -r _f; do
        [[ -f "$_f" ]] || continue
        # `|| [[ -n "$_line" ]]` because read returns NON-ZERO at EOF even when it
        # populated $_line — a file whose last (here, only) line has no trailing
        # newline. A bare `|| continue` drops such a file from the scan silently,
        # which is this section's own vacuous-coverage failure arriving one file
        # at a time, below the floor's resolution. No such file exists today.
        IFS= read -r _line < "$_f" || [[ -n "$_line" ]] || continue
        [[ "$_line" =~ $POSIX_SHEBANG_RE ]] || continue
        POSIX_FILES+=("$_f")
    done < <(git ls-files)
    POSIX_SCANNED=${#POSIX_FILES[@]}

    # FLOOR on the scan, because a discovery loop that matches NOTHING prints no
    # failures and reads as a clean green — a vacuous pass, which is the exact
    # shape of bug this section was written to eliminate. A broken regex, a
    # missing git, a `cd` that landed elsewhere: all of them look identical to
    # "everything is fine" without this.
    #
    # `-ge`, deliberately not `-eq`: the floor asserts the scan still WORKS, not
    # that the repo is frozen at 14 files. Adding a POSIX script must not turn
    # the suite red for no reason — it must simply get checked.
    assert "POSIX shebang scan is not vacuous (>= 14 files, found $POSIX_SCANNED)" \
        "[[ \$POSIX_SCANNED -ge 14 ]]"

    # ---- SET B: sourced files, which have no shebang to declare with --------
    # A sourced file never gets a shebang, so set A cannot see it — yet it is
    # reached by a POSIX shell all the same and is bound by the same contract.
    # These are enumerated by hand because there is nothing mechanical to read;
    # each entry says WHO reaches it, which is what makes it a contract.
    POSIX_FILES+=(
        home/dot_profile                    # ~/.profile itself: the POSIX entry
                                            # point. Read by login sh/dash and by
                                            # display managers; dash on Debian.
        home/dot_config/shell/env.sh        # sourced by ~/.profile (and .zshenv,
                                            # .bashrc, rc.sh) — the env layer, so
                                            # it runs under that dash .profile.
        home/dot_config/shell/lib.sh        # sourced by env.sh before it touches
                                            # PATH, i.e. the bottom of the env
                                            # layer: whatever reaches env.sh
                                            # reaches this first.
        lib/df-common.sh                    # sourced by the repo-root CLIs via
                                            # `. "$(dirname "$0")/lib/df-common.sh"`;
                                            # doctor/apply/status are #!/usr/bin/env sh.
        lib/doctor-registry.sh              # sourced by ./doctor (POSIX sh) and,
                                            # indirectly, by the interactive greet.
        lib/doctor-report.sh                # sourced by ./doctor (POSIX sh).
    )

    # DELIBERATELY ABSENT from set B: home/dot_config/shell/doctor.sh.
    # It is sourced too, but only by rc.sh — the rc layer, which is bash/zsh
    # only — and it is NOT POSIX on purpose: it defines the hyphenated
    # `dotfiles-doctor()` that dash rejects outright. It is the positive control
    # asserted above to FAIL this very parse. Adding it here would break the
    # suite AND destroy the only thing proving the checker has teeth, so if you
    # came here to "fix the omission": this is the fix, it is already applied.

    # One assert per file, named by path, so a failure says WHICH file and the
    # shell's own parse error lands on stderr right beside it.
    for _f in "${POSIX_FILES[@]}"; do
        assert "valid POSIX sh: $_f" "\"\$POSIX_SH\" -n '$_f'"
    done
    unset _f _line

    # ---- SOURCE + EXECUTE: the classes `-n` structurally cannot see ---------
    # `-n` is a PARSE check, and that is very nearly all it is. Measured with
    # this machine's dash against the bashisms most likely to be typed into the
    # env layer by someone who only ever tested in bash:
    #
    #   local x=1                    PARSE-OK    run: non-zero exit
    #   if [[ -n "$HOME" ]]; …; fi   PARSE-OK    run: exit 0, "[[: not found" on STDERR
    #   ${HOME/johns/bob}            PARSE-OK    run: non-zero exit
    #   $((RANDOM))                  PARSE-OK    run: exit 0, silently yields 0
    #   echo -e "a\tb"               PARSE-OK    run: exit 0, prints "-e a<TAB>b"
    #   a=(1 2 3)                    PARSE-FAIL  run: non-zero exit
    #
    # ONE of six is caught by parsing. Three of the other five succeed with exit
    # 0 and changed behaviour — the silent kind, which is the kind that ships and
    # the kind nobody notices for a year.
    #
    # So the check that does the real work is to SOURCE the file under a real
    # POSIX shell and assert all THREE of: exit 0, empty stdout, empty stderr.
    # Each catches a different class and every one of them has holes on its own,
    # which is why these are three separate asserts rather than one `&&` — a
    # failure has to say WHICH class broke, and a combined assert cannot.
    #
    # Empty STDOUT is not tidiness. ~/.zshenv sources env.sh for every zsh,
    # including the one behind `ssh host cmd`, and a single stray byte on stdout
    # corrupts the binary stream that scp, sftp and rsync are speaking over it.
    # Empty STDERR is what catches `[[ ]]` under dash, which is otherwise an
    # exit-0, clean-stdout, completely invisible failure.

    # A DEDICATED temp tree, NOT the harness's $SB. env.sh:40 runs
    # `mkdir -p "$GOPATH/bin"`, so merely SOURCING it creates $HOME/code/go/bin.
    # $SB is the chezmoi-applied sandbox that the parity section below walks
    # entry by entry, and a directory this section invented is a thing that
    # exists in ~ with no source-tree entry behind it. Keep the two apart.
    #
    # The EXIT trap is EXTENDED, not replaced: $SB still has to be removed.
    POSIX_TMP="$(mktemp -d)"
    trap 'rm -rf "$SB" "$POSIX_TMP"' EXIT
    POSIX_HOME="$POSIX_TMP/home"

    # env.sh:36 sources lib.sh from "$HOME/.config/shell/lib.sh" — the APPLIED
    # location, not a repo-relative path. With nothing there, env.sh takes the
    # `[ -r … ] || return 0` at line 35 and everything below asserts that six
    # lines of variable assignment are quiet: a vacuous pass wearing a green
    # coat. Copy both files from the repo SOURCE so what gets exercised is the
    # tree as committed, not whatever chezmoi last applied.
    mkdir -p "$POSIX_HOME/.config/shell"
    cp home/dot_config/shell/env.sh home/dot_config/shell/lib.sh "$POSIX_HOME/.config/shell/"

    # posix_run <script> — run <script> under $POSIX_SH with the dedicated HOME,
    # capturing exit code, stdout and stderr SEPARATELY (line counts too, for the
    # "exactly one line" assert further down). Separate capture is the whole
    # point: 2>&1 would merge the three classes back into one and undo the
    # diagnostic split described above.
    #
    # ASSERT EMPTINESS ON THE FILE (`[[ ! -s ]]`), NEVER ON $POSIX_OUT. Command
    # substitution strips ALL trailing newlines, so `out` holding exactly "\n"
    # — a bare `echo`, which is a REAL scp/sftp/rsync break and the precise
    # thing the stdout assert is named for — comes back as the empty string and
    # the assert passes. Measured: a 1-byte file, `[[ -z "$(cat f)" ]]` true,
    # `[[ ! -s f ]]` false. The variables below are DIAGNOSTICS ONLY (posix_show
    # and the wc -l counts); they must not carry an emptiness verdict.
    POSIX_RC=0; POSIX_OUT=""; POSIX_ERR=""; POSIX_OUT_N=0; POSIX_ERR_N=0
    posix_run() {
        HOME="$POSIX_HOME" "$POSIX_SH" -c "$1" >"$POSIX_TMP/out" 2>"$POSIX_TMP/err"
        POSIX_RC=$?
        POSIX_OUT="$(cat "$POSIX_TMP/out")"; POSIX_ERR="$(cat "$POSIX_TMP/err")"
        POSIX_OUT_N="$(wc -l < "$POSIX_TMP/out" | tr -d ' ')"
        POSIX_ERR_N="$(wc -l < "$POSIX_TMP/err" | tr -d ' ')"
    }
    # Print what actually leaked, so a red stdout/stderr assert does not cost a
    # second run to find out what the byte was.
    # Keyed on FILE SIZE for the same reason the asserts are: a newline-only leak
    # now correctly fails the emptiness assert, and keying the diagnostic off
    # $POSIX_OUT would have stayed silent at exactly that moment — a red assert
    # with no explanation. Byte counts are printed because the whole class of leak
    # this catches is invisible between brackets.
    posix_show() {
        [[ -s "$POSIX_TMP/out" || -s "$POSIX_TMP/err" ]] || return 0
        printf '    stdout (%s B): [%s]\n    stderr (%s B): [%s]\n' \
            "$(wc -c < "$POSIX_TMP/out" | tr -d ' ')" "$POSIX_OUT" \
            "$(wc -c < "$POSIX_TMP/err" | tr -d ' ')" "$POSIX_ERR"
        return 0
    }

    # ---- 4a: env.sh, sourced for real --------------------------------------
    # `unset DOTFILES_ENV_LOADED` first. env.sh:29 returns immediately when it is
    # set, so an inherited value turns every assert here into a test of the guard
    # and nothing else. That is safe TODAY only because env.sh:27-28 deliberately
    # does NOT export it — one `export` away, this whole block silently measures
    # air. Unsetting makes the test independent of that decision.
    posix_run 'unset DOTFILES_ENV_LOADED; . "$HOME/.config/shell/env.sh"'
    assert "env.sh sourced under $POSIX_SH: exit 0"      "[[ $POSIX_RC -eq 0 ]]"
    assert "env.sh sourced under $POSIX_SH: empty stdout (scp/sftp/rsync)" "[[ ! -s \"$POSIX_TMP/out\" ]]"
    assert "env.sh sourced under $POSIX_SH: empty stderr (catches [[ ]])"  "[[ ! -s \"$POSIX_TMP/err\" ]]"
    posix_show

    # ---- 4a-bis: DOTFILES_ENV_LOADED is set, and deliberately NOT exported --
    # env.sh:27-28 says the flag is not exported so that a child shell re-derives
    # from its OWN $HOME instead of trusting an inherited one. Nothing asserted
    # it. That matters more than it reads: every source-check above begins with
    # `unset DOTFILES_ENV_LOADED`, which protects the TEST but proves nothing
    # about the GUARD — one `export` on line 30 and env.sh:29 returns early in
    # every child of an interactive shell, so all of 4a measures six lines of
    # variable assignment being quiet. Green, and vacuous.
    #
    # Assert the PAIR, because either half alone is a false green:
    #   parent  — the sourcing process must HAVE it, or the guard never armed
    #             and "the child cannot see it" is true for the wrong reason.
    #   child   — a separate process must NOT see it. This is the actual claim.
    #
    # And a NON-VACUITY control, because a probe that inherits nothing at all
    # passes the child assert perfectly: GOPATH is exported by env.sh:39, in the
    # same file, by the same source. Match its EXACT sandbox value — this
    # machine already exports GOPATH=$HOME/code/go from the developer's own
    # shell, so "GOPATH is set" would pass with env.sh never having run. The
    # $POSIX_HOME path proves the source got past the lib.sh early return at
    # env.sh:35 and reached line 39.
    #
    # DOTFILES_TOOL_INIT_EPOCH is NOT the control to use here despite also being
    # a deliberate export: it is set by dotfiles_tool_init in common.sh, which is
    # rc layer — bash/zsh only — and is never set under a POSIX shell at all.
    #
    # A DEDICATED posix_run, not a reuse of 4a's: this one is SUPPOSED to print.
    # Folding the probe into a run whose whole purpose is asserting empty stdout
    # would destroy the assert it shares a run with.
    POSIX_PROBE="$POSIX_TMP/export-probe.sh"
    cat > "$POSIX_PROBE" <<'PROBE'
printf 'child=[%s]\n' "${DOTFILES_ENV_LOADED:-}"
printf 'child_gopath=[%s]\n' "${GOPATH:-}"
PROBE
    # $POSIX_SH and $POSIX_PROBE interpolate now; $HOME and the flag are DEFERRED
    # to the POSIX shell — same quoting split as $POSIX_RECONCILE below, and for
    # the same reason: HOME is $POSIX_HOME only inside posix_run.
    POSIX_EXPORT_PROBE="unset DOTFILES_ENV_LOADED
. \"\$HOME/.config/shell/env.sh\"
printf 'parent=[%s]\\n' \"\${DOTFILES_ENV_LOADED:-}\"
\"$POSIX_SH\" \"$POSIX_PROBE\""

    posix_run "$POSIX_EXPORT_PROBE"
    assert "DOTFILES_ENV_LOADED: the sourcing process HAS it (guard armed)" \
        "[[ \"\$POSIX_OUT\" == *'parent=[1]'* ]]"
    assert "DOTFILES_ENV_LOADED: a CHILD does NOT see it (deliberate non-export)" \
        "[[ \"\$POSIX_OUT\" == *'child=[]'* ]]"
    assert "export probe non-vacuity: that same child sees GOPATH=$POSIX_HOME/code/go" \
        "[[ \"\$POSIX_OUT\" == *\"child_gopath=[$POSIX_HOME/code/go]\"* ]]"
    assert "export probe: exit 0"       "[[ $POSIX_RC -eq 0 ]]"
    assert "export probe: empty stderr" "[[ ! -s \"$POSIX_TMP/err\" ]]"

    # The re-entry guard, asserted POSITIVELY. env.sh is reached from four places
    # and .bashrc/rc.sh can both fire in one shell, so a second source is a real
    # code path, not a hypothetical. Asserting it stays silent and exit 0 is also
    # what keeps the deliberate non-export of DOTFILES_ENV_LOADED load-bearing
    # rather than an accident nobody would notice losing.
    posix_run 'unset DOTFILES_ENV_LOADED; . "$HOME/.config/shell/env.sh"; . "$HOME/.config/shell/env.sh"'
    assert "env.sh sourced TWICE in one shell: exit 0"      "[[ $POSIX_RC -eq 0 ]]"
    assert "env.sh sourced TWICE in one shell: empty stdout" "[[ ! -s \"$POSIX_TMP/out\" ]]"
    assert "env.sh sourced TWICE in one shell: empty stderr" "[[ ! -s \"$POSIX_TMP/err\" ]]"
    posix_show

    # ---- 4b: the other two sourced files, standalone ------------------------
    # Each on its own, not via env.sh: lib.sh is reached by anything that reaches
    # env.sh, and df-common.sh is sourced directly by the #!/usr/bin/env sh CLIs
    # at the repo root. Neither may emit a byte merely by being sourced — they
    # define functions and nothing else, and this is what pins that.
    for _pf in home/dot_config/shell/lib.sh lib/df-common.sh; do
        posix_run ". \"$REPO/$_pf\""
        assert "sourced standalone under $POSIX_SH, exit 0: $_pf"      "[[ $POSIX_RC -eq 0 ]]"
        assert "sourced standalone under $POSIX_SH, empty stdout: $_pf" "[[ ! -s \"$POSIX_TMP/out\" ]]"
        assert "sourced standalone under $POSIX_SH, empty stderr: $_pf" "[[ ! -s \"$POSIX_TMP/err\" ]]"
        posix_show
    done
    unset _pf

    # ---- 4c: df_delta_gitconfig_reconcile, actually executed ----------------
    # The one function here with real side effects on a user's machine — it
    # rewrites the GLOBAL git config — so it gets a behavioural test rather than
    # an inspection. Read its header in lib/df-common.sh: every assert below
    # corresponds to a sentence in it.
    #
    # DELIBERATE TWIN — do not "de-duplicate" this against the bash-side tests in
    # sec "structural + behavioural: delta git-key reconcile". That section dots
    # df-common.sh into THIS harness and calls the function in bash; this one
    # runs it under $POSIX_SH. The overlapping asserts (five keys removed, one
    # notice line, siblings survive) are the same CLAIM checked in two different
    # SHELLS, which is the entire point of this section — the function shipped
    # verified-by-inspection precisely because no POSIX shell was available to
    # run it. The set -e, second-run and partial-state asserts below exist only
    # here. Change one twin, check the other.

    # A stub `delta` that EXISTS, is executable, and FAILS when run. That is
    # "present but not runnable", which is the exact state the function exists
    # for and the reason its predicate is `delta --version` (operability) and not
    # `command -v delta` (presence). A real delta on this machine's PATH would
    # make the function correctly return early, so the stub must come FIRST on
    # PATH. Exit 127 mimics the realistic cases: wrong glibc, dangling symlink,
    # cross-arch ELF.
    POSIX_STUB="$POSIX_TMP/stub"
    mkdir -p "$POSIX_STUB"
    printf '#!/bin/sh\nexit 127\n' > "$POSIX_STUB/delta"
    chmod +x "$POSIX_STUB/delta"
    # Non-vacuity: if the stub were missing or non-executable, `delta --version`
    # would fail for the WRONG reason and 4c would pass without testing anything.
    assert "reconcile fixture: stub delta is present and executable" "[[ -x \"$POSIX_STUB/delta\" ]]"
    assert "reconcile fixture: stub delta is NOT runnable (exit != 0)" "! \"$POSIX_STUB/delta\" --version >/dev/null 2>&1"

    # A DEDICATED throwaway GIT_CONFIG_GLOBAL. Not $SB/.gitconfig, which the
    # delta fetcher's own tests read; and emphatically not the developer's real
    # ~/.gitconfig, which is what this function would rewrite if the override
    # were forgotten. HOME is already redirected to $POSIX_HOME by posix_run, so
    # even a git old enough to ignore GIT_CONFIG_GLOBAL lands in the temp tree.
    POSIX_GITCFG="$POSIX_TMP/gitconfig"
    # The reconcile call itself, run under `set -e` — both real call sites do
    # (./doctor and update-user-home-dir.sh --uninstall), and the function's
    # guarded git calls exist precisely so that `set -e` cannot kill them.
    POSIX_RECONCILE="set -e
PATH=\"$POSIX_STUB:\$PATH\"; export PATH
GIT_CONFIG_GLOBAL=\"$POSIX_GITCFG\"; export GIT_CONFIG_GLOBAL
. \"$REPO/lib/df-common.sh\"
df_delta_gitconfig_reconcile"

    # Seed the five keys the function owns, PLUS two unrelated ones in [core]
    # and [interactive] — the sections it must not remove wholesale.
    rm -f "$POSIX_GITCFG"
    git config --file "$POSIX_GITCFG" core.pager            'delta'
    git config --file "$POSIX_GITCFG" interactive.diffFilter 'delta --color-only'
    git config --file "$POSIX_GITCFG" delta.navigate         true
    git config --file "$POSIX_GITCFG" delta.side-by-side     true
    git config --file "$POSIX_GITCFG" delta.line-numbers     true
    git config --file "$POSIX_GITCFG" core.excludesfile      '~/.gitignore_global'
    git config --file "$POSIX_GITCFG" interactive.singleKey  true

    posix_run "$POSIX_RECONCILE"
    _dgleft=0
    for _dgk in core.pager interactive.diffFilter delta.navigate delta.side-by-side delta.line-numbers; do
        if git config --file "$POSIX_GITCFG" --get "$_dgk" >/dev/null 2>&1; then
            echo "    STILL SET $_dgk"; _dgleft=$((_dgleft+1))
        fi
    done
    assert "reconcile: all five delta keys removed (left $_dgleft)" "[[ $_dgleft -eq 0 ]]"
    # EXACTLY one line. Silently rewriting a user's global git config is worse
    # than saying so, so zero is wrong; two would be noise on every login.
    assert "reconcile: prints exactly one notice line (got $POSIX_OUT_N)" "[[ $POSIX_OUT_N -eq 1 ]]"
    assert "reconcile: exit 0 under set -e"          "[[ $POSIX_RC -eq 0 ]]"
    assert "reconcile: nothing on stderr"            "[[ ! -s \"$POSIX_TMP/err\" ]]"
    # Only [delta] goes wholesale. [core] and [interactive] hold settings that
    # are the user's, not ours, and a --remove-section there would eat them.
    assert "reconcile: leaves unrelated core.excludesfile alone" \
        "[[ \"\$(git config --file '$POSIX_GITCFG' --get core.excludesfile 2>/dev/null)\" == '~/.gitignore_global' ]]"
    assert "reconcile: leaves unrelated interactive.singleKey alone" \
        "[[ \"\$(git config --file '$POSIX_GITCFG' --get interactive.singleKey 2>/dev/null)\" == 'true' ]]"

    # Idempotence. rc.sh runs this once per login session era, so the SECOND run
    # is the common case, on every machine that never had delta. Nothing of ours
    # left to remove => completely silent, exit 0. A notice printed every login
    # about work not done is the failure mode being pinned here.
    posix_run "$POSIX_RECONCILE"
    assert "reconcile: second run exits 0"        "[[ $POSIX_RC -eq 0 ]]"
    assert "reconcile: second run is silent (stdout)" "[[ ! -s \"$POSIX_TMP/out\" ]]"
    assert "reconcile: second run is silent (stderr)" "[[ ! -s \"$POSIX_TMP/err\" ]]"
    posix_show

    # PARTIAL state, which is where `set -e` actually bites. Seed ONLY core.pager:
    # the function then finds _dg_had=1 and proceeds, but `git config --unset
    # interactive.diffFilter` exits 5 on the absent key and `--remove-section
    # delta` exits 128 on the absent section. Under `set -e` either one kills the
    # caller mid-login unless the `|| true` guards hold. The full-seed run above
    # cannot detect their removal; this run is the only thing that can.
    rm -f "$POSIX_GITCFG"
    git config --file "$POSIX_GITCFG" core.pager       'delta'
    git config --file "$POSIX_GITCFG" core.excludesfile '~/.gitignore_global'
    posix_run "$POSIX_RECONCILE"
    assert "reconcile: partial state survives set -e (unset=5, remove-section=128)" "[[ $POSIX_RC -eq 0 ]]"
    assert "reconcile: partial state still prints one line (got $POSIX_OUT_N)"      "[[ $POSIX_OUT_N -eq 1 ]]"
    assert "reconcile: partial state removes core.pager" \
        "! git config --file '$POSIX_GITCFG' --get core.pager >/dev/null 2>&1"
    assert "reconcile: partial state keeps core.excludesfile" \
        "[[ -n \"\$(git config --file '$POSIX_GITCFG' --get core.excludesfile 2>/dev/null)\" ]]"
    # No posix_show here: this run is SUPPOSED to print the notice, so dumping it
    # would be noise on a green run. posix_show is for the runs that must be mute.
    unset _dgk _dgleft
else
    # FAIL, never skip. A machine with no real POSIX shell cannot execute the
    # POSIX contract at all: every `-n` assert silently degrades to whatever
    # bash-as-sh happens to tolerate. That is the precise state this section
    # exists to eliminate, so it must be RED and stay red until someone
    # installs one (`pacman -S dash`, `apt install dash`).
    bad "no POSIX shell available (tried dash ash mksh posh yash sh) — install dash"
    skip "positive control: doctor.sh must FAIL the POSIX parse (no shell to run it)"
    skip "declared POSIX surface (shebang scan + sourced files) unchecked — no shell to run it"
    # The source/execute checks are the ones that actually catch a bashism, so
    # declare their absence explicitly rather than letting the coverage vanish
    # without a trace. The `bad` above already carries the redness; these say
    # WHAT is missing. Naming all three classes matters: without a POSIX shell
    # there is nothing to observe an exit code, a stray stdout byte or a
    # "[[: not found" on stderr with.
    skip "env.sh sourced under a POSIX shell (exit 0 / empty stdout / empty stderr) — no shell to run it"
    skip "lib.sh + lib/df-common.sh sourced standalone — no shell to run it"
    skip "df_delta_gitconfig_reconcile executed against a throwaway gitconfig — no shell to run it"
fi

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
    # The emitted VALUE is unchanged — still the last \r-stripped stdout line —
    # but the raw streams are now kept instead of thrown away. The old form was
    # `2>/dev/null | tr -d '\r' | tail -1`, which discarded stderr entirely and
    # every stdout line but the last BEFORE the assert ran, so a probe-backed
    # failure could report which property broke and never why. `tail -1` is also
    # a flake amplifier in its own right: one extra line of shell startup chatter
    # silently changes which line is compared.
    _probe_evid() {
        { printf '=== probe: %s %s\n--- script: %s\n' "$1" "$2" "$3"
          printf -- '--- raw stdout (%s bytes):\n' "$(wc -c <"$EVID/probe.out")"
          sed 's/^/    /' "$EVID/probe.out"
          printf -- '\n--- raw stderr (%s bytes):\n' "$(wc -c <"$EVID/probe.err")"
          sed 's/^/    /' "$EVID/probe.err"
          printf '\n'
        } >>"$EVID_LOG"
    }
    probe() {
        ( cd /tmp && env -i HOME="$SB" TERM=xterm PATH=/usr/bin:/bin "$1" "$2" "$3" ) \
            >"$EVID/probe.out" 2>"$EVID/probe.err"
        _probe_evid "$@"
        tr -d '\r' <"$EVID/probe.out" | tail -1
    }
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
        assert_eq "$s $flag ($kind): ~/.local/bin on PATH" "$p" HAS

        d="$(probe "$s" "$flag" 'printf "%s" "$PATH"' | tr ':' '\n' | sort | uniq -d | grep -c . || true)"
        assert_eq "$s $flag ($kind): PATH has no duplicate entries" "$d" 0
    done

    # Documented residual: a bare `bash -c` reads NO startup file — only $BASH_ENV,
    # which we deliberately do not set, because it would fire for every
    # #!/bin/bash script on the box. It works anyway because it INHERITS PATH from
    # a parent that finally has one. Never "fix" that by reaching for BASH_ENV.
    #
    # That residual has a SECOND precondition the old single assertion left
    # implicit and got wrong: STDIN. bash runs ~/.bashrc for a non-interactive -c
    # shell when it believes a remote shell daemon started it, which it decides by
    # asking whether fd 0 is a socket (bash's isnetconn(), plus $SSH_CLIENT on
    # builds carrying SSH_SOURCE_BASHRC — this box's does NOT; measured, not
    # assumed). CI, an agent harness and `ssh host cmd` all hand it a socket. So on
    # everything except a developer's terminal the old assertion passed because
    # env.sh had RUN and set PATH itself — the exact opposite of the inheritance it
    # claimed — and both readings print HAS, so it could not tell them apart.
    #
    # Pin stdin, then assert the PAIR. NOPATH deliberately omits ~/.local/bin: the
    # old assertion passed a PATH that already contained it, which makes every
    # reading HAS and measures nothing.
    NOPATH="/usr/bin:/bin"

    # NEGATIVE — the residual itself, and the assertion with the teeth. No startup
    # file ran, so nothing added ~/.local/bin and the shell must report it MISSING.
    # Reach for BASH_ENV, or let something start sourcing rc files unconditionally,
    # and this goes red.
    p="$( cd /tmp && env -i HOME="$SB" PATH="$NOPATH" bash -c "$HAS_LOCALBIN" </dev/null 2>/dev/null )"
    assert_eq "bash -c (stdin not a socket): reads no startup file" "$p" MISSING

    # POSITIVE — the original claim, with its precondition now established rather
    # than assumed.
    p="$( cd /tmp && env -i HOME="$SB" PATH="$SB/.local/bin:/usr/bin:/bin" bash -c "$HAS_LOCALBIN" </dev/null 2>/dev/null )"
    assert_eq "bash -c (non-interactive): inherits PATH from its parent" "$p" HAS

    # The `ssh host cmd` path -- ~/.bashrc sourcing env.sh above the interactivity
    # gate, which is what gets PATH into `ssh host cmd` -- is deliberately NOT
    # asserted here. It was implemented and mutation-proved (a socket on fd 0 via
    # python3), then dropped by human ruling: the trigger is a bash BUILD heuristic
    # this repo does not control, so the assertion would have carried a python3
    # dependency and a per-machine capability probe to avoid reddening correct
    # configs on builds that omit it. The behaviour itself is real and documented in
    # home/doc/shell.md; the structural assertion above ("~/.bashrc sources env.sh
    # ABOVE its interactivity gate") is what guards the ordering it depends on.

    # env.sh, not rc.sh, is what exports GOPATH — so a non-interactive zsh has it.
    g="$(probe zsh -c 'printf "%s" "${GOPATH:-UNSET}"')"
    assert_eq "zsh -c: GOPATH exported by the env layer" "$g" "$SB/code/go"

    # ~/.keys is deliberately rc-layer: API keys stay confined to shells you typed
    # into, and a cron job or git hook must not inherit them.
    printf 'export DOTFILES_TEST_SECRET=leaked\n' > "$SB/.keys"
    k="$(probe zsh -c 'printf "%s" "${DOTFILES_TEST_SECRET:-ABSENT}"')"
    assert_eq "zsh -c: ~/.keys NOT sourced (secrets stay interactive-only)" "$k" ABSENT
    k="$(sh_probe zsh 'printf "%s" "${DOTFILES_TEST_SECRET:-ABSENT}"')"
    assert_eq "zsh -ic: ~/.keys IS sourced" "$k" leaked
    rm -f "$SB/.keys"

    sec "shell: rc layer still intact (regression guard)"
    for s in bash zsh; do
        if ! command -v "$s" >/dev/null 2>&1; then
            skip "$s probes ($s not installed)"
            continue
        fi

        g="$(sh_probe "$s" 'printf "%s" "${GOPATH:-UNSET}"')"
        assert_eq "$s: rc loads from a cwd outside \$HOME" "$g" "$SB/code/go"

        w="$(sh_probe "$s" 'command -v dotfiles-doctor >/dev/null && printf yes || printf no')"
        assert_eq "$s: dotfiles-doctor is defined" "$w" yes

        e="$(sh_probe "$s" 'printf "%s" "${EDITOR:-UNSET}"')"
        assert_ne "$s: EDITOR resolved" "$e" UNSET
    done

    # ~/.zshenv runs for EVERY zsh — including the one scp, sftp and rsync spawn on
    # the remote side. Those parse the stream as protocol, so a single stray
    # character printed from the env layer breaks file transfer outright. This is
    # the highest-consequence assertion in the file.
    sec "shell: startup is silent"
    for s in bash zsh; do
        command -v "$s" >/dev/null 2>&1 || continue
        noise="$( cd /tmp && env -i HOME="$SB" PATH=/usr/bin:/bin "$s" -c true 2>&1 | tr -d '\r\n \t' )"
        assert_empty "$s -c: non-interactive startup emits nothing (scp/rsync safe)" "$noise"
    done

    # Interactive startup used to print 4 nag lines per zsh start. An interactive
    # shell without a tty emits its own job-control/zle warnings, so this needs a
    # pty to mean anything; skip rather than assert something weaker.
    if command -v script >/dev/null 2>&1; then
        for s in bash zsh; do
            command -v "$s" >/dev/null 2>&1 || continue
            noise="$(cd /tmp && script -qec "env -i HOME=$SB TERM=xterm PATH=/usr/bin:/bin $s -ic true" /dev/null 2>&1 | tr -d '\r\n \t')"
            assert_empty "$s: interactive startup is silent" "$noise"
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
        assert_eq "zsh: br is defined as a function" "$b" "br: function"
        c="$(sh_probe zsh 'printf "%s" "${_comps[herdr]:-UNSET}"')"
        assert_eq "zsh: herdr completion is registered with compdef" "$c" _herdr

        if command -v bash >/dev/null 2>&1; then
            b="$(sh_probe bash 'printf "%s" "$(type -t br 2>/dev/null || printf UNDEF)"')"
            assert_eq "bash: br is defined as a function" "$b" function
        fi

        # Neither eval may break the silence contract (both are 2>/dev/null).
        if command -v script >/dev/null 2>&1; then
            noise="$(cd /tmp && script -qec "env -i HOME=$SB TERM=xterm PATH=/usr/bin:/bin zsh -ic true" /dev/null 2>&1 | tr -d '\r\n \t')"
            assert_empty "startup stays silent with herdr+broot wired" "$noise"
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

    # --- ^R ownership + tool-init staleness -----------------------------------
    # `tv init` binds ^R and ^T and runs AFTER fzf's eval inside
    # dotfiles_tool_init, so television silently won ^R for two months (iter 44).
    # That is not cosmetic: fzf's widget dedupes its candidates and is the only
    # one that reads $FZF_CTRL_R_OPTS, so ^R had no dedupe and the '--exact' set
    # in common.sh was INERT. Ruling: ^R belongs to fzf, ^T stays tv's.
    sec "shell: ^R belongs to fzf, ^T to tv"

    ti="$(sed -n '/^dotfiles_tool_init()/,/^}/p' "$SRC/dot_config/shell/common.sh")"
    # Structural. The rebind must live INSIDE the function: outside it, a
    # dotfiles-reinit re-runs tv's init and hands ^R straight back — the exact
    # failure this whole section exists to prevent.
    assert "the ^R rebind lives inside dotfiles_tool_init" \
        "grep -q \"bindkey '\\^R' fzf-history-widget\" <<<\"\$ti\""
    # Ordering is the whole mechanism, so it gets its own assert — but it must
    # read COMMENT-STRIPPED code. The comment above the rebind explains it in
    # terms of "tv init", so a raw grep matches the rationale instead of the
    # eval and the line numbers come back as a multi-line mess. (Written raw
    # first; it failed exactly that way.)
    ti_code="$(sed 's/#.*//' <<<"$ti")"
    assert "the ^R rebind comes AFTER the tv eval" \
        "[[ \$(grep -n 'tv init' <<<\"\$ti_code\" | head -1 | cut -d: -f1) -lt \$(grep -n bindkey <<<\"\$ti_code\" | head -1 | cut -d: -f1) ]]"
    assert "the tool-init stamp is set inside dotfiles_tool_init" \
        "grep -q 'DOTFILES_TOOL_INIT_EPOCH=' <<<\"\$ti\""
    # Exported on purpose: ./doctor is a child process and reads it from the
    # environment. A bare assignment would leave doctor permanently reporting n/a.
    assert "the tool-init stamp is exported" \
        "grep -q 'export DOTFILES_TOOL_INIT_EPOCH' <<<\"\$ti\""

    # One implementation, not two — a second copy of the evals is how the manual
    # and startup paths drift apart.
    reinit="$(sed -n '/^dotfiles-reinit()/,/^}/p' "$SRC/dot_config/shell/common.sh")"
    assert "dotfiles-reinit is defined" "[[ -n \"\$reinit\" ]]"
    assert "dotfiles-reinit routes through dotfiles_tool_init" \
        "grep -q 'dotfiles_tool_init' <<<\"\$reinit\""
    assert "dotfiles-reinit reimplements none of the evals" \
        "[[ \$(grep -c 'eval ' <<<\"\$reinit\") -eq 0 ]]"

    # Behavioural, via stubs shaped like the real emitters, so this reproduces
    # the CONTEST (tv rebinding ^R after fzf) whether or not either tool is
    # installed on the box running the suite.
    if command -v zsh >/dev/null 2>&1; then
        # Shell-aware, because the two shells lose ^R by different mechanisms:
        # zsh via `bindkey`, bash via `bind -x`. The bash fzf stub only DEFINES
        # __fzf_history__ — common.sh's bash branch guards on that function
        # existing and issues the bind itself, which is the behaviour under test.
        cat > "$SB/.local/bin/fzf" <<'FZFSTUB'
#!/bin/sh
case "$1" in
  --zsh)  printf '%s\n' \
            'fzf-history-widget() { :; }' \
            'zle -N fzf-history-widget' \
            "bindkey '^R' fzf-history-widget" ;;
  --bash) printf '%s\n' \
            '__fzf_history__() { :; }' ;;
esac
exit 0
FZFSTUB
        cat > "$SB/.local/bin/tv" <<'TVSTUB'
#!/bin/sh
[ "$1" = init ] || exit 0
case "$2" in
  zsh)  printf '%s\n' \
          'tv-shell-history() { :; }' \
          'tv-smart-autocomplete() { :; }' \
          'zle -N tv-shell-history' \
          'zle -N tv-smart-autocomplete' \
          "bindkey '^R' tv-shell-history" \
          "bindkey '^T' tv-smart-autocomplete" ;;
  bash) printf '%s\n' \
          'tv_shell_history() { :; }' \
          'bind -m emacs-standard -x '"'"'"\C-r": tv_shell_history'"'"' 2>/dev/null' ;;
esac
exit 0
TVSTUB
        chmod +x "$SB/.local/bin/fzf" "$SB/.local/bin/tv"

        r="$(sh_probe zsh 'bindkey "^R"')"
        assert_glob "zsh: ^R is fzf's widget, not tv's" "$r" '*fzf-history-widget*'
        t="$(sh_probe zsh 'bindkey "^T"')"
        assert_glob "zsh: ^T is left to tv" "$t" '*tv-smart-autocomplete*'
        # THE assertion for the inside-the-function rule. If the rebind ever
        # moves out of dotfiles_tool_init this goes red while everything above
        # stays green.
        r2="$(sh_probe zsh 'dotfiles-reinit >/dev/null 2>&1; bindkey "^R"')"
        assert_glob "zsh: ^R survives a dotfiles-reinit" "$r2" '*fzf-history-widget*'

        e="$(sh_probe zsh 'printf "%s" "${DOTFILES_TOOL_INIT_EPOCH:-UNSET}"')"
        assert_re "zsh: tool-init stamp is set and numeric" "$e" '^[0-9]+$'

        # Idempotency, behaviourally — this is what makes dotfiles-reinit safe to
        # recommend at all. Compares the WHOLE keymap plus the hook arrays, not a
        # sampled key: a double-registered precmd would be a worse bug than the
        # staleness this fixes.
        idem="$(sh_probe zsh 'a="$(bindkey; print -l $precmd_functions $preexec_functions)"; dotfiles_tool_init >/dev/null 2>&1; b="$(bindkey; print -l $precmd_functions $preexec_functions)"; [ "$a" = "$b" ] && printf SAME || printf DIFF')"
        assert_eq "zsh: re-running the init changes no binding and no hook" "$idem" SAME

        # bash loses ^R by a different mechanism (bind -x, not bindkey), so it
        # needs its own coverage or that branch of common.sh rots unasserted.
        if command -v bash >/dev/null 2>&1; then
            rb="$(sh_probe bash 'bind -X 2>/dev/null | grep -i "C-r"')"
            assert_glob "bash: ^R is fzf's __fzf_history__, not tv's" \
                "$rb" '*__fzf_history__*'
            rb2="$(sh_probe bash 'dotfiles-reinit >/dev/null 2>&1; bind -X 2>/dev/null | grep -i "C-r"')"
            assert_glob "bash: ^R survives a dotfiles-reinit" \
                "$rb2" '*__fzf_history__*'
            eb="$(sh_probe bash 'printf "%s" "${DOTFILES_TOOL_INIT_EPOCH:-UNSET}"')"
            assert_re "bash: tool-init stamp is set and numeric" "$eb" '^[0-9]+$'
        fi

        rm -f "$SB/.local/bin/fzf" "$SB/.local/bin/tv"
    else
        skip "^R ownership stub probes (zsh not installed)"
    fi

    # doctor's staleness row, functionally, in all three states. A dedicated PATH
    # dir gives a binary whose mtime is definitely 'now'; /usr/bin stays on PATH
    # because the check itself shells out to stat.
    sec "doctor: tool-init staleness"
    TID="$SB/tool-init-probe"; mkdir -p "$TID"; : > "$TID/fzf"; chmod +x "$TID/fzf"
    ti_row() {
        env -i HOME="$SB" PATH="$TID:/usr/bin:/bin" \
            ${1:+DOTFILES_TOOL_INIT_EPOCH="$1"} \
            sh -c '. "$1"; df_doctor_registry() { :; }; df_doctor_report' sh \
            "$REPO/lib/doctor-report.sh" 2>/dev/null | grep '^  tool-init'
    }
    assert "no stamp => n/a (a non-interactive shell has nothing to be stale)" \
        "[[ \"\$(ti_row)\" == *'n/a'* ]]"
    assert "future stamp => ok" \
        "[[ \"\$(ti_row 9999999999)\" == *' ok '* ]]"
    assert "ancient stamp => STALE and names the tool" \
        "[[ \"\$(ti_row 1)\" == *STALE*fzf* ]]"
    assert "the STALE row names the fix" \
        "[[ \"\$(ti_row 1)\" == *dotfiles-reinit* ]]"
    # stat MUST dereference. ~/.local/bin/<tool> are symlinks whose mtime tracks
    # neither the tool nor the upgrade — measured on this box, fzf's link was four
    # months OLDER than its binary while starship's was NEWER than its own. A
    # check without -L reports ok forever and greps perfectly clean.
    assert "the staleness check dereferences symlinks (stat -L)" \
        "grep -q 'stat -Lc' lib/doctor-report.sh"
    rm -rf "$TID"

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
# Regression: GitHub's API returns this JSON minified on one line, not one key
# per line. A bare `grep '"tag_name"'` used to match the WHOLE document (grep
# is line-based) and `awk -F'"' '{print $4}'` grabbed the 4th quoted field of
# the entire blob -- the "url" field's value, itself a full api.github.com URL
# -- instead of the tag. fetch_jq then spliced that bogus "tag" into its own
# download URL, embedding one URL inside another (404). Feed
# gh_latest_tag_nojq a realistic minified fixture (url field first, tag_name
# after) via a stubbed curl, offline, so this is caught without live network.
nojq_tag="$( . "$LIB" >/dev/null 2>&1
    curl() { printf '%s' '{"url":"https://api.github.com/repos/jqlang/jq/releases/342331441","tag_name":"jq-1.8.2","name":"jq 1.8.2"}'; }
    gh_latest_tag_nojq jqlang/jq )"
assert "gh_latest_tag_nojq parses tag_name from minified JSON" "[[ \"\$nojq_tag\" == 'jq-1.8.2' ]]"
assert "gh_latest_tag_nojq does not return the url field"      "[[ \"\$nojq_tag\" != *api.github.com* ]]"
# fb_init must put ~/.local/bin on PATH, or a just-fetched jq is invisible to the
# bare \`jq\` calls in every later fetcher within the same installer run.
pth="$( . "$LIB" >/dev/null 2>&1; PATH=/usr/bin:/bin; fb_init >/dev/null 2>&1; printf '%s' "$PATH" )"
assert "fb_init prepends \$BIN_DIR to PATH"        "case \":\$pth:\" in *\":$BIN_DIR:\"*) true ;; *) false ;; esac"
# The installer bootstraps jq in Phase 1 and skips 01_fetch.jq.sh in the loop.
assert "installer skips 01_fetch.jq.sh in fetcher loop" "grep -q '01_fetch.jq.sh ]] && continue' update-user-home-dir.sh"
# Distro jq is enough; --force used to remove_bin + fetch_jq anyway and
# burn the unauthenticated GitHub API budget. Same trap as tsh/op:
# fb_system_bin, never a bare command -v (fb_init prepends BIN_DIR).
assert "installer defers jq to a system install" \
    "nocomment update-user-home-dir.sh | grep -q 'fb_system_bin jq'"
assert "01_fetch.jq.sh defers via fb_system_bin" \
    "awk '/^[[:space:]]*#/{next} /fb_system_bin/{f=1} END{exit f?0:1}' home/dot_local/bin/fetch.bins/executable_01_fetch.jq.sh"
assert "01_fetch.jq.sh does not key the skip on bare command -v" \
    "awk '/^[[:space:]]*#/{next} /command -v/{f=1} END{exit f?1:0}' home/dot_local/bin/fetch.bins/executable_01_fetch.jq.sh"
assert "01_fetch.jq.sh offers a force override" \
    "grep -qF 'JQ_FETCH_FORCE' home/dot_local/bin/fetch.bins/executable_01_fetch.jq.sh"

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
assert "root apply CLI present"                     "[[ -x apply ]]"
assert "root status CLI present"                    "[[ -x status ]]"
assert "root help CLI present"                      "[[ -x help ]]"
assert "Makefile help facade present"               "[[ -f Makefile ]]"
assert "doctor registry single-sourced in lib/"     "[[ -f lib/doctor-registry.sh ]]"
assert "dotfiles-keys trampoline present"           "[[ -f home/dot_local/bin/executable_dotfiles-keys ]]"
assert "dotfiles-keys trampoline stays thin"        "[[ \$(wc -l < home/dot_local/bin/executable_dotfiles-keys) -le 50 ]]"
assert "dotfiles-keys trampoline execs ./keys"      "grep -q root/keys home/dot_local/bin/executable_dotfiles-keys"
assert "dotfiles-doctor trampoline present"         "[[ -f home/dot_local/bin/executable_dotfiles-doctor ]]"
assert "dotfiles-doctor trampoline stays thin"      "[[ \$(wc -l < home/dot_local/bin/executable_dotfiles-doctor) -le 50 ]]"
assert "dotfiles-doctor trampoline execs ./doctor"  "grep -q root/doctor home/dot_local/bin/executable_dotfiles-doctor"

# ---------------------------------------------------------------------------
# "Not provisioned by this repo" is an EMPTY STEM, never a non-empty note.
# lib/doctor-report.sh keyed the n/a branch on the note, so every provisioned
# row that carried an explanation (tree-sitter, herdr, ghostty, delta) was
# disowned when its tool was absent — and the fetcher path, the one actionable
# thing on the line, was suppressed at exactly the moment it mattered.
#
# Driven against a STUB registry, never the live one. Asserting on real rows
# would couple the result to whichever tools this machine happens to have
# installed, which is how a test starts passing for the wrong reason: on a
# healthy box every real row says `ok` and none of these branches is reached.
sec "doctor: provisioning keys on the stem, not the note"

# One fetcher on disk, so df_doctor_installer_for has a deterministic hit
# (zzstub) and a deterministic miss (zzmissing). The four command names are
# absent from any PATH, so df_have is false for all of them and each row lands
# on a non-'ok' branch.
DRT="$SB/doctor-report-test"
mkdir -p "$DRT/.local/bin/fetch.bins"
: > "$DRT/.local/bin/fetch.bins/99_fetch.zzstub.sh"
DR_OUT="$(HOME="$DRT" DF_ROOT="" sh -c '
    . "$1"
    df_doctor_registry() {
        printf "%s\n" \
            "zzprov|zzstub| provisioned with a note" \
            "zzbare|zzstub|" \
            "zznone|| not provisioned by fetch.bins" \
            "zznoinst|zzmissing| provisioned, no fetcher on disk"
    }
    df_doctor_report' sh "$REPO/lib/doctor-report.sh" 2>/dev/null)"

# THE regression assert: against the old `[ -n "${_note}" ]` this row printed
# `n/a  provisioned with a note` and the fetcher path never appeared at all.
assert "stem AND note, tool absent => MISS + fetcher path" \
    "grep -q 'zzprov .*MISS .*99_fetch.zzstub.sh' <<<\"\$DR_OUT\""
assert "stem, no note, tool absent => MISS + fetcher path" \
    "grep -q 'zzbare .*MISS .*99_fetch.zzstub.sh' <<<\"\$DR_OUT\""
# The tv / keychain behaviour, which must not regress: an empty stem is the
# ONLY thing that yields n/a.
assert "EMPTY stem, tool absent => n/a + note" \
    "grep -q 'zznone .*n/a .*not provisioned by fetch.bins' <<<\"\$DR_OUT\""
assert "empty-stem row never claims MISS" \
    "! grep -q 'zznone .*MISS' <<<\"\$DR_OUT\""
# The note must survive onto the MISS line: without this a note on a
# provisioned row is write-only, and delta's restored note is unobservable.
assert "note reaches the MISS line, parenthesised" \
    "grep -q 'zzprov .*MISS .*(provisioned with a note)' <<<\"\$DR_OUT\""
assert "note reaches the no-installer MISS line too" \
    "grep -q 'zznoinst .*MISS .*no installer in.*(provisioned, no fetcher on disk)' <<<\"\$DR_OUT\""
# delta's note was dropped in iter 42 purely to dodge the bug above. Read it
# out of the registry FUNCTION, not the source text, so the assert cannot pass
# on a commented-out row. Whitespace-only counts as empty.
DELTA_NOTE="$(sh -c '. "$1"; df_doctor_registry' sh "$REPO/lib/doctor-registry.sh" \
    | awk -F'|' '$1=="delta"{print $3}')"
assert "delta carries a non-empty registry note again" \
    "[[ -n \"\${DELTA_NOTE//[[:space:]]/}\" ]]"

# op: presence is not operability on Linux. A user-owned 0755 binary is what
# fetch.bins install_bin leaves behind, and the 1Password app resets the
# socket until it is setgid onepassword-cli. Doctor must report NEED (with
# the two sudo lines) instead of a green ok. Driven against a STUB op on
# PATH so this machine's real perms cannot satisfy the check.
sec "doctor: op without Linux setgid is NEED, not ok"
OPD="$SB/op-sgid-test"
mkdir -p "$OPD/bin" "$OPD/.local/bin/fetch.bins"
printf '#!/bin/sh\nexit 0\n' > "$OPD/bin/op"
chmod 755 "$OPD/bin/op"
: > "$OPD/.local/bin/fetch.bins/23_fetch.op.sh"
DFC="lib/df-common.sh"
assert "df-common defines df_op_linux_sgid_ok" \
    "grep -qE '^df_op_linux_sgid_ok\\(\\)' $DFC"
assert "df-common defines df_op_linux_sgid_fix" \
    "grep -qE '^df_op_linux_sgid_fix\\(\\)' $DFC"
assert "df-common setgid fix names sudo chgrp" \
    "nocomment $DFC | grep -q 'sudo chgrp onepassword-cli'"
assert "df-common setgid fix names sudo chmod g+s" \
    "nocomment $DFC | grep -q 'sudo chmod g+s'"
assert "df-common never invokes sudo" \
    "[[ -z \$(nocomment $DFC | grep -E '^[[:space:]]*sudo[[:space:]]') ]]"
assert "doctor-report keys op health on setgid" \
    "grep -q 'df_op_linux_sgid_ok' lib/doctor-report.sh"
assert "doctor-report never invokes sudo" \
    "[[ -z \$(nocomment lib/doctor-report.sh | grep -E '^[[:space:]]*sudo[[:space:]]') ]]"

PATH="$OPD/bin:$PATH" sh -c '. "$1"; df_op_linux_sgid_ok' sh "$REPO/lib/df-common.sh"
_sgid_rc=$?
assert "df_op_linux_sgid_ok rejects a user-owned 0755 op" "[[ $_sgid_rc -ne 0 ]]"
# setgid bit ALONE is not enough: the app checks the process GID against
# onepassword-cli. chmod g+s as the file owner leaves the group as ours.
chmod g+s "$OPD/bin/op"
PATH="$OPD/bin:$PATH" sh -c '. "$1"; df_op_linux_sgid_ok' sh "$REPO/lib/df-common.sh"
_sgid_rc=$?
assert "df_op_linux_sgid_ok rejects setgid with the wrong group" "[[ $_sgid_rc -ne 0 ]]"
chmod 755 "$OPD/bin/op"

DR_OP="$(PATH="$OPD/bin:$PATH" HOME="$OPD" DF_ROOT="" sh -c '
    . "$1/lib/df-common.sh"
    . "$1/lib/doctor-registry.sh"
    . "$1/lib/doctor-report.sh"
    df_doctor_report
' sh "$REPO" 2>/dev/null)"
assert_re "doctor: op without setgid is NEED" "$DR_OP" 'op[[:space:]]+NEED'
assert "doctor NEED row names sudo chgrp" \
    "grep -q 'sudo chgrp onepassword-cli' <<<\"\$DR_OP\""
assert "doctor NEED row names sudo chmod g+s" \
    "grep -q 'sudo chmod g+s' <<<\"\$DR_OP\""
assert "doctor NEED row does not also say ok for op" \
    "! grep -E '^[[:space:]]*op[[:space:]]+ok' <<<\"\$DR_OP\""
# The ok branch exists and is reachable when the predicate passes. Override
# the function rather than forging onepassword-cli setgid (needs sudo).
DR_OP_OK="$(PATH="$OPD/bin:$PATH" HOME="$OPD" DF_ROOT="" sh -c '
    . "$1/lib/df-common.sh"
    . "$1/lib/doctor-registry.sh"
    . "$1/lib/doctor-report.sh"
    df_op_linux_sgid_ok() { return 0; }
    df_doctor_report
' sh "$REPO" 2>/dev/null)"
assert_re "doctor: op with setgid predicate passing is ok" "$DR_OP_OK" 'op[[:space:]]+ok'

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
assert "ghostty config unbinds ctrl+enter fullscreen" "grep -q '^keybind = ctrl+enter=unbind$' $GH_CONF"

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

# The FTH Teleport login helper was retired — that site is no longer operational,
# so the script authenticated against a cluster that does not exist. Same orphan
# rule as alacritty above, and it bites harder: the applied copy is an EXECUTABLE
# on PATH, so leaving it behind keeps a tab-completable command that shells out to
# `op item get "FTH Teleport"` against a dead proxy.
assert "fth login source removed"                   "[[ ! -f home/dot_local/bin/executable_tsh-login-fth.sh ]]"
# Same exclusion rule as alacritty's: .chezmoiremove must name the path to retire
# it, and this harness names it in these very asserts.
assert "no fth refs in source or README"            "! grep -rin --exclude=.chezmoiremove -e future-tech-holdings -e tsh-login-fth home README.md"
assert ".chezmoiremove retires applied fth script"  "grep -q '^.local/bin/tsh-login-fth.sh\$' home/.chezmoiremove"
# The syketech sibling is LIVE and must survive this retirement. Without this the
# two asserts above would still pass if someone deleted both scripts.
assert "syketech login helper still present"        "[[ -f home/dot_local/bin/executable_tsh-login-syketech.sh ]]"

# --- tsh-login-syketech hardening (iter 46) ---------------------------------
# The helper obtains a PERSISTENT Teleport certificate, and that path keeps a
# password + OTP prompt indefinitely: the enrolled WebAuthn credential is a
# 1Password passkey, reachable only through a browser, while `tsh` is a separate
# WebAuthn client speaking CTAP over libfido2 (measured: `tsh login
# --auth=passwordless` -> "no security keys found"). There is no headless login
# to fall back on either -- `--headless` is a per-command flag on `tsh ls`/`ssh`/
# `scp` only. Only a USB security key would retire these asserts.
#
# The helper answers those prompts by driving `tsh` under a pty, which is why
# there is no multiplexer branch to assert: tmux, herdr and a bare terminal all
# take one identical path. herdr exposes no buffer or clipboard command at all,
# so the old `tmux set-buffer` approach had nothing to port to.
TSHL="home/dot_local/bin/executable_tsh-login-syketech.sh"
# The embedded driver, extracted the same way the script writes it out. The
# `cat` line is TAB-INDENTED, so anchoring this on ^cat matched nothing and the
# extraction came back empty -- and ast.parse("") succeeds, so the parse assert
# passed vacuously. Mutation testing caught it; the non-empty check below is what
# stops it regressing to a vacuous pass again.
tshl_pydriver() { sed -n '/cat >"$driver"/,/^PYDRIVER$/p' "$TSHL" | sed '1d;$d'; }

assert "tsh-login: bash parses"                     "bash -n $TSHL"
if command -v python3 >/dev/null 2>&1; then
    assert "tsh-login: embedded driver was actually extracted" \
        "[[ \$(tshl_pydriver | wc -l) -gt 20 ]]"
    assert "tsh-login: embedded python parses" \
        "tshl_pydriver | python3 -c 'import ast,sys; src=sys.stdin.read(); assert src.strip(); ast.parse(src)'"
else
    skip "tsh-login: embedded python parses (no python3)"
fi
assert "tsh-login: keeps its SPDX banner"           "grep -q '^# SPDX-License-Identifier: MIT OR Apache-2.0$' $TSHL"

# The applied name is chezmoi's to decide, not this script's to assert. A
# hardwired name goes stale silently: the messages keep naming a file that no
# longer exists. NEGATIVE half is comment-stripped -- the rationale comment names
# the script, and a raw grep would match its own explanation.
assert "tsh-login: derives its name from arg0"      "grep -q 'me=\"\${0##\*/}\"' $TSHL"
assert "tsh-login: no hardwired script name"        "[[ -z \$(nocomment $TSHL | grep -F 'tsh-login-syketech:') ]]"

# Scoped to the proxy: a bare `tsh status` exits 0 while logged in to ANY
# cluster, so an unscoped guard would skip the login we actually need.
assert "tsh-login: cert check is proxy-scoped"      "nocomment $TSHL | grep -q 'tsh status --proxy='"
# ORDERING, on comment-stripped source: the point of the cert check is to avoid
# waking `op` (a biometric prompt) when the session is still valid.
assert "tsh-login: cert check precedes any op call" \
    "[[ \$(nocomment $TSHL | grep -n 'tsh status' | head -1 | cut -d: -f1) -lt \$(nocomment $TSHL | grep -n 'op item get' | head -1 | cut -d: -f1) ]]"
assert "tsh-login: op guard precedes any op call" \
    "[[ \$(nocomment $TSHL | grep -n 'command -v op' | head -1 | cut -d: -f1) -lt \$(nocomment $TSHL | grep -n 'op item get' | head -1 | cut -d: -f1) ]]"
assert "tsh-login: guards tsh as well as op"        "nocomment $TSHL | grep -q 'command -v tsh'"
# NEGATIVE: df_have is a SOURCED rc-layer function and this file sources nothing,
# so requiring it would fail a correct script.
assert "tsh-login: does not reach for df_have"      "[[ -z \$(nocomment $TSHL | grep 'df_have') ]]"

# COUNT, not presence: an earlier version fetched the password twice -- once into
# a variable it never read, once inline for a paste buffer -- which a
# "string exists somewhere" assert cannot see.
assert "tsh-login: exactly one op call per secret"  "[[ \$(nocomment $TSHL | grep -c 'op item get') -eq 2 ]]"

# THE herdr FIX, asserted as an absence. Any multiplexer- or clipboard-specific
# call is a regression: it would mean one multiplexer got a convenience the other
# could not, and a live secret parked in a shared surface. Comment-stripped,
# because the script explains at length why each of these was removed.
assert "tsh-login: no multiplexer or clipboard branch" \
    "[[ -z \$(nocomment $TSHL | grep -nEi 'tmux|herdr|wl-copy|xclip|xsel|set-buffer|clipboard|HERDR_|\\\$TMUX') ]]"

# python3 is a SOFT dependency, matching how the rest of the repo treats it (one
# of four fb_unzip backends, never required).
assert "tsh-login: python3 is a soft dependency"    "nocomment $TSHL | grep -q 'command -v python3'"
assert "tsh-login: has a no-python3 fallback"       "nocomment $TSHL | grep -q 'python3 not found'"

# Secrets reach the driver on STDIN. Never argv (/proc/PID/cmdline is
# WORLD-readable) and never the environment. The second assert is the one that
# matters: it reads the actual driver invocation and requires no secret on it.
# Written without $pass/$otp in the pattern on purpose: the harness eval()s the
# assert string, so a bare $pass in it expands to nothing under `set -u` and
# takes the assert down with it. Match the printf FORM instead, pinned to the
# driver invocation with -B1.
assert "tsh-login: driver is fed from a pipe, not argv" \
    "nocomment $TSHL | grep -B1 'python3 \"\$driver\"' | grep -q \"printf '%s.n%s.n'\""
# -A2, not a single line: the invocation is line-continued, and an earlier
# version of this assert read only the first line -- a secret appended to the
# continuation sailed straight past it. Mutation testing caught that.
assert "tsh-login: no secret on the driver command line" \
    "[[ -z \$(nocomment $TSHL | grep -A2 'python3 \"\$driver\"' | grep -E '\\\$pass|\\\$otp') ]]"
# The driver used to take its own mktemp file and its own trap. It now lives in
# one scratch dir that a single trap owns, so the op-unusable path -- which
# writes no driver at all -- cannot leave a stray temp behind. Assert BOTH
# halves: a trap on the dir, AND the driver actually inside it. A trap on a dir
# the driver does not live in would clean up nothing and still grep clean.
assert "tsh-login: scratch dir is trapped for removal" \
    "nocomment $TSHL | grep -qE 'trap .rm -rf .\\\$tmpdir.* EXIT INT TERM'"
assert "tsh-login: driver lives inside the trapped dir" \
    "nocomment $TSHL | grep -q 'driver=\"\\\${tmpdir}/'"

# DEGRADE, never refuse. `op` is the PREFERRED secret source, never a
# requirement: this cluster is LOCAL auth (password + TOTP), so a box with no
# usable op can still hold a full certificate -- the human types what op would
# have supplied. The old behaviour exited 1 on a missing op, which turned an
# unanswered biometric prompt into a dead end while the script sat on a working
# interactive path it refused to use.
#
# The predicate is OPERABILITY, not presence: `command -v op` proves only that a
# binary exists, and the failure actually observed was an INSTALLED op returning
# "authorization timeout". Asserted as the elif CHAIN, because a presence check
# that does not also catch a failing fetch is exactly the bug.
assert "tsh-login: degrades to an interactive login, never refuses" \
    "[[ \$(nocomment $TSHL | grep -c 'tsh login --proxy=') -eq 3 ]]"
# COUNT, not presence: `grep -q` here matches EITHER elif, so converting just one
# of the two fetches back to a hard guard sailed straight past it. Mutation
# testing caught that. Both fetches must degrade -- a password that falls back
# while the OTP still exits is half a fix.
assert "tsh-login: a failing op fetch degrades too, not just a missing binary" \
    "[[ \$(nocomment $TSHL | grep -cE 'elif ! (pass|otp)=') -eq 2 ]]"

# Linux setgid diagnostic. The connection-reset failure is a missing GID bit,
# not a bad secret. The helper must NAME the two sudo commands so the human can
# unstick desktop IPC, and must NEVER run them (lifestyle bins stay rootless).
# Comment-stripped: the rationale comments name both commands.
assert "tsh-login: names sudo chgrp onepassword-cli" \
    "nocomment $TSHL | grep -q 'sudo chgrp onepassword-cli'"
assert "tsh-login: names sudo chmod g+s" \
    "nocomment $TSHL | grep -q 'sudo chmod g+s'"
assert "tsh-login: never invokes sudo" \
    "[[ -z \$(nocomment $TSHL | grep -E '^[[:space:]]*sudo[[:space:]]') ]]"
assert "tsh-login: setgid check uses test -g AND the group name" \
    "nocomment $TSHL | grep -q -- '-g \"\$real\"' && nocomment $TSHL | grep -q 'onepassword-cli'"
assert "tsh-login: setgid hint is Linux-only" \
    "nocomment $TSHL | grep -q 'uname -s'"

# --headless produces NO certificate, so substituting it for a login would report
# success and leave `ssh <host>` still broken. It is OFFERED as advice and never
# executed. COUNT-based: an occurrence outside a printf trips it. The first
# assert is the non-vacuity control -- the equality below is satisfied by 0 == 0.
assert "tsh-login: offers --headless as the no-certificate alternative" \
    "[[ \$(nocomment $TSHL | grep -c 'tsh ssh --headless') -ge 1 ]]"
assert "tsh-login: --headless is advice, never executed" \
    "[[ \$(nocomment $TSHL | grep -c 'tsh ssh --headless') -eq \$(nocomment $TSHL | grep 'tsh ssh --headless' | grep -c printf) ]]"

# POSITIVE, and deliberately so. Human ruling 2026-08-15: the OTP is printed on
# stdout. A known exposure -- tmux-pane-log can persist it, and it sits in
# scrollback -- weighed and accepted for convenience. Asserted so that "fixing"
# it trips the suite and reopens the ruling instead of silently changing
# behaviour. It applies to the manual fallback; the pty path types the code and
# never displays it, which is why this assert must NOT require it on both paths.
assert "tsh-login: OTP on stdout is a RULING"       "nocomment $TSHL | grep -q 'One time password'"
# --ttl is MINUTES: 1800 is 30 HOURS, already at Teleport's typical hard cap.
assert "tsh-login: --ttl stays 1800 (30 HOURS)"     "[[ \$(nocomment $TSHL | grep -c -- '--ttl 1800') -eq 3 ]]"

# Enrolling a WebAuthn passkey CHANGED tsh's MFA prompt, mid-task and without
# warning: with one factor it read "Enter an OTP code from a device:", with two
# it reads "Tap any security key or enter a code from a OTP device" -- which does
# not contain "OTP code". A single-literal matcher missed it and the live login
# hung with the code in hand and never sent. Two defences, both asserted.
#
# 1. Make the prompt DETERMINISTIC rather than something to pattern-match.
assert "tsh-login: pins --mfa-mode on all three paths" \
    "[[ \$(nocomment $TSHL | grep -c -- '--mfa-mode=\"\$mfa_mode\"') -eq 3 ]]"
assert "tsh-login: --mfa-mode is overridable"       "nocomment $TSHL | grep -q 'TSH_LOGIN_MFA_MODE'"
# 2. Match a SET of cues anyway -- a silent hang is the expensive failure. This
#    is a COUNT: a lone literal is exactly the bug, so presence proves nothing.
assert "tsh-login: OTP cue is a set, not one literal" \
    "[[ \$(tshl_pydriver | grep -c 'OTP_CUES = ') -eq 1 ]]"
assert "tsh-login: OTP cue set covers both prompt forms" \
    "[[ \$(tshl_pydriver | grep 'OTP_CUES = ' | grep -o 'b\"' | wc -l) -ge 3 ]]"
assert "tsh-login: warns when the OTP prompt is unrecognised" \
    "tshl_pydriver | grep -q 'no OTP prompt recognised'"

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

# ===========================================================================
# Structural checks for slots 18-21 (fd, bat, delta, xh) — source only, run in
# every group. These four are the ripgrep shape, so the invariants worth pinning
# are the four places they DIVERGE from it, every one of which fails invisibly
# from an x86_64 machine or fails silently at runtime:
#   1. fb_arch can never emit `aarch64` (its sed hardcodes s/aarch64/arm64/), and
#      all four use raw uname tokens. Calling it 404s on arm64 only.
#   2. delta has NO aarch64 musl build, so a blanket musl filter resolves to
#      nothing on arm64 only. It must prefer musl and FALL BACK to gnu.
#   3. fd and bat publish .deb assets whose names contain "musl", so the filter
#      must be anchored on the extension, not just the libc token.
#   4. bat's zsh completion ships as bat.zsh, not _bat. Installed under its
#      shipped name it is never autoloaded — no error, just no completions.
sec "structural: fd/bat/delta/xh fetchers (slots 18-21, no network)"
FD_FETCHER="home/dot_local/bin/fetch.bins/executable_18_fetch.fd.sh"
BAT_FETCHER="home/dot_local/bin/fetch.bins/executable_19_fetch.bat.sh"
DELTA_FETCHER="home/dot_local/bin/fetch.bins/executable_20_fetch.delta.sh"
XH_FETCHER="home/dot_local/bin/fetch.bins/executable_21_fetch.xh.sh"
for f in "$FD_FETCHER" "$BAT_FETCHER" "$DELTA_FETCHER" "$XH_FETCHER"; do
    b="$(basename "$f")"
    assert "$b present"            "[[ -f $f ]]"
    assert "$b is executable (0755)" "[[ -x $f ]]"
    assert "$b is valid bash"      "bash -n $f"
    assert "$b sources _lib.sh"    "grep -q '_lib.sh' $f"
    assert "$b carries the SPDX banner" \
        "grep -q 'SPDX-License-Identifier: MIT OR Apache-2.0' $f"
    assert "$b goes through install_bin" "grep -qE '^[[:space:]]*install_bin[[:space:]]' $f"
    # Trap 1 — NEGATIVE, so read comment-stripped source: every one of these
    # files DOCUMENTS in its header why fb_arch is unusable, and a raw grep would
    # match its own rationale and fail permanently. awk, not `grep -v | grep -q`:
    # under this harness's pipefail a short-circuiting grep -q SIGPIPEs the
    # producer and the assert fails even on a match.
    assert "$b never CALLS fb_arch" "awk '/^[[:space:]]*#/{next} /fb_arch/{f=1} END{exit f?1:0}' $f"
    assert "$b uses raw uname -m"   "grep -qE 'ARCH=\"\\\$\\(uname -m\\)\"' $f"
    # Trap 3 — the extension anchor is what actually keeps a .deb out of
    # install_bin. Count: EVERY gh_asset_url filter in the file must carry it,
    # not merely one of them (delta has two).
    # Counted on comment-stripped source; every selector carries exactly one
    # contains($arch), so this compares selectors against anchors 1:1 (delta has
    # two selectors, and BOTH must be anchored).
    nsel=$(nocomment "$f" | grep -c 'contains($arch)')
    nanch=$(nocomment "$f" | grep -c 'endswith(".tar.gz")')
    assert "$b anchors every asset filter on .tar.gz ($nsel sel/$nanch anchored)" \
        "[[ $nsel -ge 1 && $nsel -eq $nanch ]]"
    assert "$b prefers linux-musl over bare musl" "grep -q 'contains(\"linux-musl\")' $f"
    # Completions must be installed under the zsh AUTOLOAD name. The helper owns
    # the rename, so every fetcher must route through it rather than cp'ing.
    assert "$b installs completions via the helper" \
        "grep -qE '^[[:space:]]*fb_install_completions[[:space:]]' $f"
done

# Trap 2 — delta's gnu fallback. Assert the FALLBACK (the branch that reacts to
# an empty musl result), not merely the string "gnu", which would also match the
# header comment explaining the trap.
assert "delta fetcher probes musl, then falls back" \
    "awk '/^[[:space:]]*#/{next} /LIBC=\"gnu\"/{f=1} END{exit f?0:1}' $DELTA_FETCHER"
assert "delta fallback is guarded on an empty musl result" \
    "grep -qF 'if [[ -z \"\$ASSET_URL\" ]]; then' $DELTA_FETCHER"
# The recovery MUST be outside the command substitution. gh_asset_url `exit 1`s,
# and `exit` terminates the subshell, so an inner `$(… || true)` never runs its
# fallback: the substitution still yields status 1 and `set -e` kills the script
# at the assignment. That wrong form greps clean and fails only on an arch with
# no musl build — i.e. never on this machine. Pin the OUTSIDE form specifically.
assert "delta musl probe recovers OUTSIDE the substitution" \
    "grep -qF '|| ASSET_URL=\"\"' $DELTA_FETCHER"
# Scoped to the SELECTOR line (the one carrying contains($arch)). A blanket
# search for `2>/dev/null || true)` is wrong: the _prev_pager probe uses exactly
# that form legitimately, because `git config --get` RETURNS 1 rather than
# calling exit, so its inner `|| true` does run. The distinction is the whole
# point — it is gh_asset_url's `exit` that makes the inner form unsafe.
assert "delta musl probe has no inner '|| true'" \
    "awk '/^[[:space:]]*#/{next} /contains\\(\\\$arch\\)/ && /\\|\\| true\\)/{f=1} END{exit f?1:0}' $DELTA_FETCHER"
assert "delta fetcher selects a linux-gnu asset"  "grep -q 'contains(\"linux-gnu\")' $DELTA_FETCHER"
# delta's tag has no leading "v", so its inner dir uses ${VERSION}; fd/bat/xh
# tags DO carry one, so theirs use ${TAG_NAME}. Getting this backwards makes the
# extracted path wrong and the install fails on the very first run.
assert "delta inner dir uses \${VERSION} (tag has no v)" \
    "grep -qF 'SRC_DIR=\"\${FB_TMP}/\${BIN_NAME}-\${VERSION}-' $DELTA_FETCHER"
for f in "$FD_FETCHER" "$BAT_FETCHER" "$XH_FETCHER"; do
    assert "$(basename "$f") inner dir uses \${TAG_NAME} (tag has a v)" \
        "grep -qF 'SRC_DIR=\"\${FB_TMP}/\${BIN_NAME}-\${TAG_NAME}-' $f"
done
# Trap 4 — bat is the only one of the four whose zsh completion is NOT shipped
# under its autoload name, which is exactly why the helper renames rather than
# copying. Pin both halves: bat hands over the .zsh file, and the helper is what
# writes the _<tool> name.
assert "bat fetcher hands the helper its bat.zsh file" \
    "grep -qF 'autocomplete/bat.zsh' $BAT_FETCHER"
assert "helper installs zsh completions under _<tool>" \
    "grep -qF 'cp \"\$zsrc\" \"\${zdir}/_\${tool}\"' $LIB"
assert "helper removes zsh completions by _<tool>" \
    "grep -qF '\"\${zdir}/_\${tool}\"' $LIB"
# delta ships no completion files at all — it generates them from the binary.
assert "delta generates its own completions"        "grep -q -- '--generate-completion' $DELTA_FETCHER"
assert "delta generates BOTH zsh and bash" \
    "[[ \$(nocomment $DELTA_FETCHER | grep -c -- '--generate-completion') -eq 2 ]]"

assert "doctor registry lists fd"                   "grep -q 'fd|fd|' lib/doctor-registry.sh"
assert "doctor registry lists bat"                  "grep -q 'bat|bat|' lib/doctor-registry.sh"
assert "doctor registry lists delta"                "grep -q 'delta|delta|' lib/doctor-registry.sh"
assert "doctor registry lists xh"                   "grep -q 'xh|xh|' lib/doctor-registry.sh"

# Teardown lockstep (the tree-sitter regression, three more times). fd/bat/xh are
# plain remove_bin tools and belong in the loop; delta does NOT, because it also
# owns global git keys remove_bin knows nothing about. Match the loop LINE
# specifically — "fd" and "bat" are short substrings that occur elsewhere in this
# installer — and confirm delta is handled outside it.
assert "installer uninstall covers fd"              "grep -qE '^[[:space:]]*for b in .*\\bfd\\b' update-user-home-dir.sh"
assert "installer uninstall covers bat"             "grep -qE '^[[:space:]]*for b in .*\\bbat\\b' update-user-home-dir.sh"
assert "installer uninstall covers xh"              "grep -qE '^[[:space:]]*for b in .*\\bxh\\b' update-user-home-dir.sh"
assert "installer uninstall removes delta binary"   "grep -qE '^[[:space:]]*remove_bin delta\$' update-user-home-dir.sh"
assert "installer uninstall removes completions"    "grep -qE '^[[:space:]]*fb_remove_completions fd bat delta xh\$' update-user-home-dir.sh"

# ---------------------------------------------------------------------------
# Slot 22 — Teleport client tools (tsh, tctl).
#
# This fetcher INVERTS four rules the other slots establish, so every assert
# below is pinning a departure a well-meaning reader would otherwise "fix":
#
#   1. fb_arch is CORRECT here. Slots 17-21 all document it as a trap because
#      those projects use raw `uname -m`; Teleport uses amd64/arm64, which is
#      exactly what fb_arch emits. The 18-21 loop asserts fb_arch is NEVER
#      called; this one asserts it IS.
#   2. No GitHub API, at all. cdn.teleport.dev serves the asset, so the tag and
#      asset helpers must not appear — only gh_download, a plain URL fetcher.
#   3. The version comes from the CLUSTER. A hardcoded fallback would quietly
#      stage a skewed client, which is the thing pinning exists to prevent.
#   4. `version` is a SUBCOMMAND. `tsh --version` is a hard error, so the
#      install_bin verify argv must not carry the flag form.
sec "structural: Teleport tsh fetcher (slot 22, no network)"
TSH_FETCHER="home/dot_local/bin/fetch.bins/executable_22_fetch.tsh.sh"
assert "22_fetch.tsh.sh present"                    "[[ -f $TSH_FETCHER ]]"
assert "22_fetch.tsh.sh is executable (0755)"       "[[ -x $TSH_FETCHER ]]"
assert "22_fetch.tsh.sh is valid bash"              "bash -n $TSH_FETCHER"
assert "22_fetch.tsh.sh sources _lib.sh"            "grep -q '_lib.sh' $TSH_FETCHER"
assert "22_fetch.tsh.sh carries the SPDX banner" \
    "grep -q 'SPDX-License-Identifier: MIT OR Apache-2.0' $TSH_FETCHER"
assert "tsh fetcher goes through install_bin" \
    "grep -qE '^[[:space:]]*install_bin[[:space:]]' $TSH_FETCHER"

# Trap 1 — the fb_arch inversion. Assert the CALL, on comment-stripped source:
# the header explains the inversion at length and a raw grep would match its own
# rationale in either direction.
assert "tsh fetcher CALLS fb_arch (Teleport uses amd64/arm64)" \
    "awk '/^[[:space:]]*#/{next} /fb_arch/{f=1} END{exit f?0:1}' $TSH_FETCHER"
assert "tsh fetcher does NOT use raw uname -m" \
    "awk '/^[[:space:]]*#/{next} /uname -m/{f=1} END{exit f?1:0}' $TSH_FETCHER"

# Trap 2 — no GitHub API. Comment-stripped, since the header names all three
# helpers while explaining that they are unused.
for helper in gh_latest_tag gh_latest_tag_nojq gh_asset_url; do
    assert "tsh fetcher never calls $helper" \
        "awk -v h=$helper '/^[[:space:]]*#/{next} \$0 ~ h {f=1} END{exit f?1:0}' $TSH_FETCHER"
done
assert "tsh fetcher downloads via gh_download" \
    "awk '/^[[:space:]]*#/{next} /gh_download/{f=1} END{exit f?0:1}' $TSH_FETCHER"

# Trap 3 — cluster-pinned, and NO hardcoded version fallback. The second assert
# is the load-bearing one: a literal vNN.NN.NN in executable code would be the
# silently-stale client the header forbids. Version-shaped strings are expected
# in the COMMENTS (measured URLs), so this reads stripped source.
assert "tsh fetcher reads the cluster's tools_version" \
    "grep -qF 'auto_update.tools_version' $TSH_FETCHER"
assert "tsh fetcher queries /v1/webapi/find"        "grep -qF '/v1/webapi/find' $TSH_FETCHER"
assert "tsh fetcher hardcodes no version fallback" \
    "awk '/^[[:space:]]*#/{next} /teleport-v[0-9]+\\./{f=1} END{exit f?1:0}' $TSH_FETCHER"

# Trap 4 — `version` is a subcommand. Pin both install_bin call sites: passing
# --version fails the verification gate outright and takes the install with it.
assert "tsh fetcher verifies with the 'version' subcommand" \
    "[[ \$(nocomment $TSH_FETCHER | grep -cE '^[[:space:]]*install_bin .* version\$') -eq 2 ]]"
assert "tsh fetcher never passes --version to install_bin" \
    "awk '/^[[:space:]]*#/{next} /install_bin/ && /--version/{f=1} END{exit f?1:0}' $TSH_FETCHER"

# Defers to a system-wide tsh. fb_system_bin is what makes that safe on run
# 2..n — a bare `command -v` would find our OWN symlink, because fb_init puts
# BIN_DIR on PATH, and the fetcher would skip forever after the first install.
assert "tsh fetcher defers via fb_system_bin" \
    "awk '/^[[:space:]]*#/{next} /fb_system_bin/{f=1} END{exit f?0:1}' $TSH_FETCHER"
assert "tsh fetcher does not key the skip on bare command -v" \
    "awk '/^[[:space:]]*#/{next} /command -v/{f=1} END{exit f?1:0}' $TSH_FETCHER"
assert "tsh fetcher offers a force override"        "grep -qF 'TSH_FETCH_FORCE' $TSH_FETCHER"

# The version fast path must precede the download, or every Phase-5 installer
# run re-pulls ~207 MB only for install_bin to answer "already valid". ORDERING
# assert, so it reads comment-stripped source (the iter-44 `tv init` lesson).
assert "tsh version fast path precedes gh_download" \
    "awk '/^[[:space:]]*#/{next} /already installed and matching/{seen=1} /gh_download/{exit seen?0:1}' $TSH_FETCHER"

# Installs the CLIENT only, and never the vendor's root installer.
assert "tsh fetcher extracts only tsh and tctl" \
    "grep -qF 'teleport/tsh teleport/tctl' $TSH_FETCHER"
assert "tsh fetcher never runs the bundled install script" \
    "awk '/^[[:space:]]*#/{next} /teleport\\/install/{f=1} END{exit f?1:0}' $TSH_FETCHER"

# No completions, deliberately: tsh's --completion-script-zsh emits a bare
# `#compdef` and a function literally named `_`. Shipping that is worse than
# bat's rename trap, so the fetcher must not route through the helper at all.
assert "tsh fetcher installs NO completions" \
    "awk '/^[[:space:]]*#/{next} /fb_install_completions/{f=1} END{exit f?1:0}' $TSH_FETCHER"

assert "doctor registry lists tsh"                  "grep -q 'tsh|tsh|' lib/doctor-registry.sh"
assert "installer uninstall covers tsh"             "grep -qE '^[[:space:]]*for b in .*\\btsh\\b' update-user-home-dir.sh"
assert "installer uninstall covers tctl"            "grep -qE '^[[:space:]]*for b in .*\\btctl\\b' update-user-home-dir.sh"
assert "installer uninstall covers op"              "grep -qE '^[[:space:]]*for b in .*\\bop\\b' update-user-home-dir.sh"

# ===========================================================================
# Structural checks for the 1Password CLI fetcher (slot 23) — source only.
# The load-bearing invariant is Linux setgid onepassword-cli: install_bin
# copies a user-owned 0755 binary, the desktop app then resets CLI IPC, and
# a re-fetch STRIPS any previously-applied bit. The fetcher must check after
# install_bin (including the skip path), print the two sudo commands, and
# never invoke sudo itself.
sec "structural: 1Password op fetcher (slot 23, no network)"
OP_FETCHER="home/dot_local/bin/fetch.bins/executable_23_fetch.op.sh"
assert "23_fetch.op.sh present"                     "[[ -f $OP_FETCHER ]]"
assert "23_fetch.op.sh is valid bash"               "bash -n $OP_FETCHER"
assert "23_fetch.op.sh sources _lib.sh"             "grep -q '_lib.sh' $OP_FETCHER"
assert "23_fetch.op.sh carries the SPDX banner" \
    "grep -q 'SPDX-License-Identifier: MIT OR Apache-2.0' $OP_FETCHER"
assert "op fetcher goes through install_bin" \
    "grep -qE '^[[:space:]]*install_bin[[:space:]]' $OP_FETCHER"
# Defers to a system-wide op (the 1password-cli package). Same trap as
# slot 22: fb_init prepends BIN_DIR, so a bare command -v would find OUR
# OWN symlink after run 1 and skip forever.
assert "op fetcher defers via fb_system_bin" \
    "awk '/^[[:space:]]*#/{next} /fb_system_bin/{f=1} END{exit f?0:1}' $OP_FETCHER"
assert "op fetcher does not key the skip on bare command -v" \
    "awk '/^[[:space:]]*#/{next} /command -v/{f=1} END{exit f?1:0}' $OP_FETCHER"
assert "op fetcher offers a force override"         "grep -qF 'OP_FETCH_FORCE' $OP_FETCHER"
assert "op system deferral precedes the CDN download" \
    "awk '/^[[:space:]]*#/{next} /fb_system_bin/{seen=1} /cache.agilebits.com/{exit seen?0:1}' $OP_FETCHER"
assert "op fast path restores a missing PATH symlink onto APP_DIR payload" \
    "nocomment $OP_FETCHER | grep -q 'ln -sfn \"\${APP_DIR}/\${BIN_NAME}\" \"\${BIN_DIR}/\${BIN_NAME}\"'"
# User-local setgid check is after install_bin (the function is defined
# earlier so the system-deferral path can call it too). Pin the APP_DIR
# call site, not the first mention of the group name.
assert "op fetcher checks user-local setgid after install_bin" \
    "[[ \$(nocomment $OP_FETCHER | grep -n 'install_bin' | tail -1 | cut -d: -f1) -lt \$(nocomment $OP_FETCHER | grep -n 'op_ensure_linux_sgid \"\${APP_DIR}' | tail -1 | cut -d: -f1) ]]"
assert "op fetcher names sudo chgrp onepassword-cli" \
    "nocomment $OP_FETCHER | grep -q 'sudo chgrp onepassword-cli'"
assert "op fetcher names sudo chmod g+s" \
    "nocomment $OP_FETCHER | grep -q 'sudo chmod g+s'"
assert "op fetcher never invokes sudo" \
    "[[ -z \$(nocomment $OP_FETCHER | grep -E '^[[:space:]]*sudo[[:space:]]') ]]"
assert "op fetcher has no op-login leftover" \
    "[[ -z \$(nocomment $OP_FETCHER | grep -F 'op-login') ]]"
assert "op fetcher tries chgrp without sudo first" \
    "nocomment $OP_FETCHER | grep -qE '&&[[:space:]]*chgrp onepassword-cli'"
assert "doctor registry lists op"                   "grep -q 'op|op|' lib/doctor-registry.sh"
assert "no op-login refs in source or docs" \
    "! grep -rin --exclude-dir=.git --exclude=.chezmoiremove -e op-login home lib README.md doctor keys update-user-home-dir.sh"

# fb_system_bin's own contract, asserted on the library. The PATH strip is the
# whole point: without it the helper answers "system-provided" for our own
# symlink and the deferral becomes permanent.
assert "fb_system_bin strips BIN_DIR from the search PATH" \
    "grep -qF 'search=\"\${search//:\${BIN_DIR}:/:}\"' $LIB"
assert "fb_system_bin rejects anything resolving into APP_DIR" \
    "grep -qF '\"\${APP_DIR}\"/*) return 1 ;;' $LIB"
assert "fb_system_bin probes operability, not presence" \
    "grep -qF '\"\$found\" \"\${probe[@]}\" >/dev/null 2>&1 || return 1' $LIB"
# install_bin's printed version line must follow the caller's argv. Hardcoding
# --version made it print a usage error under the label "version:" for any tool
# whose flag differs (tsh, age-keygen).
assert "install_bin restores a missing PATH symlink onto an existing payload" \
    "nocomment $LIB | grep -q 'restored symlink onto existing payload'"
assert "install_bin replaces via staging+mv, not in-place cp" \
    "nocomment $LIB | grep -q 'staging=\"\${final_src}.new.\$\$\"' && nocomment $LIB | grep -q 'mv -f \"\$staging\" \"\$final_src\"'"
assert "install_bin version line reuses the verify argv" \
    "grep -qF 'version_args=(\"\${verify_args[@]}\")' $LIB"

# ---- Part C: delta's git wiring is imperative, not a managed gitconfig ------
# The five keys are set by the fetcher after a successful install. A COUNT, not a
# presence check: "some git config --global call exists" passes a mutation that
# drops four of the five, which is precisely the failure this guards.
assert "delta fetcher sets exactly five git keys" \
    "[[ \$(grep -cE '^[[:space:]]*git config --global ' $DELTA_FETCHER) -eq 5 ]]"
for k in core.pager interactive.diffFilter delta.navigate delta.side-by-side delta.line-numbers; do
    assert "delta fetcher sets $k" "grep -qE '^[[:space:]]*git config --global $k( |\$)' $DELTA_FETCHER"
done
# Ordering is a safety property: core.pager naming an absent delta makes git diff
# die outright (fatal: unable to execute pager, exit 128), so the wiring must come
# AFTER install_bin, which exits non-zero on a failed verification.
# Guarded on git existing: the prime directive is that a minimal no-root box
# still ends up operational, and such a box may have no git. Unguarded, the
# first `git config` call would kill the fetcher under set -e AFTER delta was
# already installed successfully — a spurious failure for a working tool.
assert "delta git wiring is guarded on git existing" \
    "grep -qF 'if command -v git >/dev/null 2>&1; then' $DELTA_FETCHER"
assert "delta wires git only AFTER install_bin" \
    "[[ \$(nocomment $DELTA_FETCHER | grep -n 'install_bin' | tail -1 | cut -d: -f1) -lt \$(nocomment $DELTA_FETCHER | grep -n 'git config --global' | head -1 | cut -d: -f1) ]]"
# Teardown lives in df_delta_gitconfig_reconcile (lib/df-common.sh), NOT inline
# here — see the dedicated reconcile section below for the full rule. What the
# installer must get right is (a) sourcing it, (b) calling it, and (c) the
# ordering relative to remove_bin.
assert "installer sources lib/df-common.sh"   "grep -qE '^\\. \"lib/df-common.sh\"' update-user-home-dir.sh"
assert "uninstall calls the shared reconcile" \
    "grep -qE '^[[:space:]]*df_delta_gitconfig_reconcile\$' update-user-home-dir.sh"
# THE sequencing trap: checking before remove_bin finds OUR OWN binary still on
# PATH, always concludes "keep", and the wiring is never cleaned — a bug that
# looks exactly like the feature working. Comment-stripped, since the comments
# above the call explain the ordering and name both symbols.
assert "uninstall reconciles AFTER remove_bin delta" \
    "[[ \$(nocomment update-user-home-dir.sh | grep -n 'remove_bin delta' | head -1 | cut -d: -f1) -lt \$(nocomment update-user-home-dir.sh | grep -n 'df_delta_gitconfig_reconcile' | head -1 | cut -d: -f1) ]]"
# The installer must NOT carry its own copy of the teardown: a second
# implementation is exactly how the two call sites drift apart.
assert "installer has no inline git teardown of its own" \
    "[[ \$(nocomment update-user-home-dir.sh | grep -cE 'git config --global (--unset|--remove-section)') -eq 0 ]]"
# Ruling (this iter): git config is owned IMPERATIVELY, by the fetcher — there is
# deliberately no chezmoi-managed gitconfig. A managed file would fight the three
# other writers of that file (gh, vp, git itself) and, worse, a hardcoded
# [user] email would silently re-attribute commits on every machine, since this
# user's git identity is per-host by design.
assert "no managed gitconfig source exists" \
    "[[ ! -e home/dot_gitconfig && ! -e home/dot_config/git/config && ! -e home/private_dot_config/git/config ]]"

# ===========================================================================
# df_delta_gitconfig_reconcile — "if delta cannot run, drop the five git keys."
#
# Two call sites (./doctor's once-per-login health check, and uninstall after
# remove_bin) share ONE implementation so they cannot disagree about what
# "available" means. The whole design rests on one distinction, and it is the one
# thing here that is invisible to a casual reading:
#
#   THE PREDICATE IS OPERABILITY, NOT PRESENCE.
#
# delta is the one fetcher with a gnu fallback on arches with no musl build, so
# present-but-not-runnable is a real state for it — wrong glibc, dangling
# symlink, cross-arch ELF. `command -v` succeeds for every one of those and would
# leave core.pager aimed at a binary that cannot execute. The behavioural test
# below with a stub that EXISTS but exits non-zero is what pins this: it fails
# the moment someone "simplifies" the predicate to command -v or df_have.
sec "structural + behavioural: delta git-key reconcile (no network)"
DFC="lib/df-common.sh"
assert "df-common.sh defines df_delta_gitconfig_reconcile" \
    "grep -qE '^df_delta_gitconfig_reconcile\\(\\)' $DFC"
assert "reconcile predicate is 'delta --version'" \
    "grep -qF 'if delta --version >/dev/null 2>&1; then' $DFC"
# NEGATIVE + comment-stripped: the function documents at length WHY command -v
# and df_have are wrong, so a raw grep matches its own rationale and would fail
# permanently. (df_have's own definition is a comment-free line naming neither.)
assert "reconcile never uses 'command -v delta'" \
    "awk '/^[[:space:]]*#/{next} /command -v delta/{f=1} END{exit f?1:0}' $DFC"
assert "reconcile never uses 'df_have delta'" \
    "awk '/^[[:space:]]*#/{next} /df_have delta/{f=1} END{exit f?1:0}' $DFC"
# Exactly ONE implementation, repo-wide. A copied second copy in the installer or
# doctor is the failure this guards. The harness is excluded because these very
# asserts name the predicate too — the alacritty asserts use the same carve-out.
assert "exactly one delta operability predicate in the repo" \
    "[[ \$(grep -rlF 'delta --version >/dev/null' lib doctor update-user-home-dir.sh home | wc -l) -eq 1 ]]"
assert "doctor calls the reconcile" "grep -qE '^df_delta_gitconfig_reconcile\$' doctor"
assert "doctor still sources df-common.sh" "grep -q 'lib/df-common.sh' doctor"
# Surgical: only [delta] is ours end to end. The user keeps unrelated settings in
# [core] and [interactive] (excludesfile, singleKey, …).
assert "reconcile never drops the whole [core] section" \
    "awk '/^[[:space:]]*#/{next} /--remove-section core/{f=1} END{exit f?1:0}' $DFC"
assert "reconcile never drops the whole [interactive] section" \
    "awk '/^[[:space:]]*#/{next} /--remove-section interactive/{f=1} END{exit f?1:0}' $DFC"
# All three teardown calls guarded: --unset on an absent key exits 5 and
# --remove-section on an absent section exits 128, and both call sites run under
# set -e. A count, because one unguarded call is enough to break it.
assert "every reconcile git call is guarded with || true" \
    "[[ \$(grep -cE '^[[:space:]]*git config --global (--unset|--remove-section).*\\|\\| true\$' $DFC) -eq 3 ]]"

# ---- behavioural: stub delta on PATH, sandboxed GIT_CONFIG_GLOBAL -----------
# Every case runs in a subshell with a PATH containing ONLY our stub dir, so the
# result cannot depend on whether the developer's machine happens to have a real
# delta. git is symlinked into each stub dir because the function needs it.
#
# DELIBERATE TWIN — these run the function in BASH (df-common.sh is dotted into
# this harness above). sec "POSIX shell contract" runs the same function under
# $POSIX_SH, and additionally covers set -e, the idempotent second run, and the
# partial-state path where --unset exits 5 and --remove-section exits 128. The
# duplication is the point: this file is sourced by ./doctor (#!/usr/bin/env sh)
# and by ./keys (bash), so both shells are real call sites. Change one twin,
# check the other.
#
# The three-stub table below (ok/broken/none) is richer than the POSIX side,
# which only stubs "broken" — a working delta returning early is shell-agnostic
# and needs asserting once, not twice.
RECON_DIR="$SB/recon"; mkdir -p "$RECON_DIR"/{ok,broken,none}
for d in ok broken none; do ln -sf "$(command -v git)" "$RECON_DIR/$d/git"; done
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "delta 9.9.9"; exit 0; }\nexit 0\n' > "$RECON_DIR/ok/delta"
printf '#!/bin/sh\nexit 1\n' > "$RECON_DIR/broken/delta"   # EXISTS, is executable, cannot run
chmod +x "$RECON_DIR/ok/delta" "$RECON_DIR/broken/delta"
# shellcheck source=lib/df-common.sh
. "$REPO/lib/df-common.sh"

# seed_keys <file> — the five keys plus two SIBLING settings that must survive.
seed_keys() {
    GIT_CONFIG_GLOBAL="$1" git config --global core.pager delta
    GIT_CONFIG_GLOBAL="$1" git config --global interactive.diffFilter 'delta --color-only'
    GIT_CONFIG_GLOBAL="$1" git config --global delta.navigate true
    GIT_CONFIG_GLOBAL="$1" git config --global delta.side-by-side true
    GIT_CONFIG_GLOBAL="$1" git config --global delta.line-numbers true
    GIT_CONFIG_GLOBAL="$1" git config --global core.excludesfile '~/.config/git/ignore'
    GIT_CONFIG_GLOBAL="$1" git config --global interactive.singleKey true
}
nkeys() {  # how many of the five remain
    n=0
    for k in core.pager interactive.diffFilter delta.navigate delta.side-by-side delta.line-numbers; do
        GIT_CONFIG_GLOBAL="$1" git config --global --get "$k" >/dev/null 2>&1 && n=$((n+1))
    done
    printf '%s' "$n"
}
# recon <gitconfig> <stub-dir> -> stdout of the reconcile, AND a byte-exact copy
# of it in $RECON_OUT.
#
# The file is not redundant with the `out*` variables below: the SILENCE asserts
# must read the file, because `out="$(recon …)"` has already thrown the answer
# away by the time any test looks at it. Command substitution strips all trailing
# newlines, so a reconcile that printed exactly "\n" — one stray byte, which is
# what breaks scp/sftp/rsync — arrives as the empty string and `[[ -z "$out" ]]`
# passes. Rewriting the TEST cannot fix that; the capture is where it is lost.
# Keep the variables for the line-COUNTING assert, where the content is what
# matters and the stripping is harmless. Same rule as posix_run's, and for the
# same reason — see sec "POSIX shell contract".
# The `_recon_rc` dance is not ceremony. A function's exit status is its LAST
# command, so ending on `cat` would return cat's status and throw the
# reconcile's away — silently converting `assert "second reconcile exits 0"`
# into a test of whether cat can read a file it just wrote. Measured:
# `( exit 7 ) > f; cat f` returns 0. Capture the status before the cat, return
# it after. (Same failure shape as the newline above: the answer is destroyed
# at capture time, so no rewrite of the ASSERT could have recovered it.)
RECON_OUT="$SB/recon.out"
recon() {
    ( PATH="$RECON_DIR/$2"; GIT_CONFIG_GLOBAL="$1"; export PATH GIT_CONFIG_GLOBAL
      df_delta_gitconfig_reconcile ) > "$RECON_OUT"
    _recon_rc=$?
    cat "$RECON_OUT"
    return "$_recon_rc"
}

# 1. working delta => all five survive
G1="$SB/recon-ok.gitconfig"; : > "$G1"; seed_keys "$G1"
out1="$(recon "$G1" ok)"
assert "working delta: all five keys survive"  "[[ \$(nkeys $G1) -eq 5 ]]"
assert "working delta: reconcile is silent"    "[[ ! -s \"$RECON_OUT\" ]]"

# 2. no delta at all => all five removed
G2="$SB/recon-none.gitconfig"; : > "$G2"; seed_keys "$G2"
out2="$(recon "$G2" none)"
assert "no delta: all five keys removed"       "[[ \$(nkeys $G2) -eq 0 ]]"
assert "no delta: exactly one notice line"     "[[ \$(printf '%s' \"\$out2\" | wc -l) -eq 1 || \$(printf '%s\\n' \"\$out2\" | grep -c . ) -eq 1 ]]"
# Surgical: the user's unrelated settings in the SAME sections must survive.
assert "no delta: core.excludesfile survives"  "[[ -n \"\$(GIT_CONFIG_GLOBAL=$G2 git config --global --get core.excludesfile)\" ]]"
assert "no delta: interactive.singleKey survives" "[[ -n \"\$(GIT_CONFIG_GLOBAL=$G2 git config --global --get interactive.singleKey)\" ]]"

# 3. THE ONE THAT PROVES OPERABILITY != PRESENCE. The stub exists, is executable,
#    and is found by `command -v` — but exits non-zero. A predicate written as
#    `command -v delta` or `df_have delta` passes it and leaves the keys in place,
#    so this assert fails the instant someone makes that "simplification".
G3="$SB/recon-broken.gitconfig"; : > "$G3"; seed_keys "$G3"
assert "sanity: the broken stub IS found by command -v" \
    "( PATH=\"$RECON_DIR/broken\"; command -v delta >/dev/null 2>&1 )"
assert "sanity: the broken stub CANNOT run"    "! ( PATH=\"$RECON_DIR/broken\"; delta --version >/dev/null 2>&1 )"
out3="$(recon "$G3" broken)"
assert "broken delta: all five keys removed (presence would have kept them)" \
    "[[ \$(nkeys $G3) -eq 0 ]]"

# 4. idempotent: a second pass has nothing to do and must say nothing at all.
out4="$(recon "$G2" none)"
assert "second reconcile is completely silent" "[[ ! -s \"$RECON_OUT\" ]]"
assert "second reconcile exits 0"              "( recon $G2 none >/dev/null )"
# ...and on a config that never had the keys at all.
G5="$SB/recon-virgin.gitconfig"; printf '[user]\n\temail = x@y\n' > "$G5"
out5="$(recon "$G5" none)"
assert "virgin config: reconcile is silent"    "[[ ! -s \"$RECON_OUT\" ]]"
assert "virgin config: left untouched"         "grep -q 'x@y' $G5"

# ---- end to end: the REAL uninstall path, in a throwaway HOME ---------------
# Ruling 2 in practice. These run the actual `./update-user-home-dir.sh
# --uninstall --force` rather than a simulation, because the thing most likely to
# break is the ORDERING inside it: reconciling before remove_bin would find our
# own binary still on PATH, always conclude "keep", and never clean the wiring.
#
# A delta-free PATH is built by shadowing every real PATH entry except `delta`.
# Without it, the "no delta anywhere" case would silently depend on whether the
# developer's machine happens to have a system delta installed — the test would
# pass here and mean nothing on the next machine.
NODELTA="$SB/nodelta"; mkdir -p "$NODELTA"
( IFS=:; for d in $PATH; do [ -d "$d" ] || continue
    for f in "$d"/*; do b="${f##*/}"; [ "$b" = delta ] && continue
      [ -e "$NODELTA/$b" ] || ln -s "$f" "$NODELTA/$b" 2>/dev/null; done; done )
assert "shadow PATH really has no delta" "! ( PATH=\"$NODELTA\"; command -v delta >/dev/null 2>&1 )"
assert "shadow PATH still provides git"  "( PATH=\"$NODELTA\"; command -v git >/dev/null 2>&1 )"

# uninstall_case <path> — fresh HOME with a fake installed delta + seeded keys.
# EVERY XDG var is redirected into the throwaway HOME: the installer's uninstall
# does `rm -rf $XDG_CONFIG_HOME/chezmoi` and fb_remove_completions works off
# $XDG_DATA_HOME, so inheriting the outer sandbox's values would wipe state the
# rest of this suite depends on.
uninstall_case() {
    UC_HOME="$(mktemp -d)"
    mkdir -p "$UC_HOME/.local/bin" "$UC_HOME/.local/apps"
    printf '#!/bin/sh\nexit 0\n' > "$UC_HOME/.local/bin/delta"; chmod +x "$UC_HOME/.local/bin/delta"
    : > "$UC_HOME/.local/apps/delta"
    UC_GC="$UC_HOME/.gitconfig"; : > "$UC_GC"; seed_keys "$UC_GC"
    HOME="$UC_HOME" \
    XDG_CONFIG_HOME="$UC_HOME/.config" XDG_CACHE_HOME="$UC_HOME/.cache" \
    XDG_DATA_HOME="$UC_HOME/.local/share" GIT_CONFIG_GLOBAL="$UC_GC" PATH="$1" \
        ./update-user-home-dir.sh --uninstall --force >/dev/null 2>&1 || true
}

# A. a SYSTEM delta still runs => our binary goes, the wiring STAYS.
uninstall_case "$RECON_DIR/ok:$NODELTA"
assert "uninstall(system delta): our binary removed" "[[ ! -e \"$UC_HOME/.local/bin/delta\" ]]"
assert "uninstall(system delta): git keys KEPT"      "[[ \$(nkeys \"$UC_GC\") -eq 5 ]]"
rm -rf "$UC_HOME"

# B. no delta anywhere => binary goes AND the wiring goes.
uninstall_case "$NODELTA"
assert "uninstall(no delta): our binary removed"     "[[ ! -e \"$UC_HOME/.local/bin/delta\" ]]"
assert "uninstall(no delta): git keys removed"       "[[ \$(nkeys \"$UC_GC\") -eq 0 ]]"
assert "uninstall(no delta): sibling settings survive" \
    "[[ -n \"\$(GIT_CONFIG_GLOBAL=\"$UC_GC\" git config --global --get core.excludesfile)\" ]]"
rm -rf "$UC_HOME"
# The outer sandbox must be untouched by both runs.
assert "uninstall cases left the sandbox alone" "[[ -d \"$SB/.config/chezmoi\" || ! -e \"$SB/.config\" ]]"

# ---- Part B: the site-functions completion scheme ---------------------------
# Completion FILES cannot ride the dotfiles_tool_init print-and-eval route, so
# they get an $fpath directory instead. Two things fail silently here: a $fpath
# line placed after compinit does nothing at all, and a zsh completion not named
# _<tool> is never autoloaded.
# zsh history policy. The dedupe options all operate on the IN-MEMORY list, so
# HISTSIZE < SAVEHIST names an on-disk target one session can never reach — that
# inversion shipped for a long time and is what this section guards first.
sec "structural: zsh history dedupe policy (no network)"
HIST_SRC="home/dot_config/shell/zsh.sh"
COMMON_SRC="home/dot_config/shell/common.sh"
# Numeric, not a literal grep: this must keep holding when the values change, and
# it must catch a re-inversion rather than a specific pair of numbers.
assert "HISTSIZE >= SAVEHIST (no inversion)" \
    "[[ \$(grep -E '^HISTSIZE=' $HIST_SRC | cut -d= -f2) -ge \$(grep -E '^SAVEHIST=' $HIST_SRC | cut -d= -f2) ]]"
for _o in hist_reduce_blanks hist_ignore_dups hist_save_no_dups \
          hist_expire_dups_first hist_ignore_space hist_find_no_dups; do
    assert "zsh.sh sets $_o" "nocomment $HIST_SRC | grep -qE '^setopt .*$_o'"
done
# hist_ignore_all_dups removes the OLDER copy of any repeat, destroying the
# chronology the last-20-into-a-script workflow reads. RULED OUT by the operator.
# Comment-stripped, per the standing rule: the file explains at length why this
# option is excluded, so a raw grep matches its own rationale and can never pass.
assert "hist_ignore_all_dups stays out" \
    "[[ -z \$(nocomment $HIST_SRC | grep 'hist_ignore_all_dups') ]]"
# share_history implies inc_append_history AND imports other panes' commands live.
# Deliberately not adopted; assert the weaker option is the one in force.
assert "inc_append_history, not share_history" \
    "nocomment $HIST_SRC | grep -qE '^setopt inc_append_history' && [[ -z \$(nocomment $HIST_SRC | grep 'share_history') ]]"
# fzf's ^R defaults to FUZZY: `dang` matched 693 entries by scattered characters.
assert "FZF_CTRL_R_OPTS forces exact matching" \
    "nocomment $COMMON_SRC | grep -qF \"FZF_CTRL_R_OPTS='--exact'\""
assert "FZF_CTRL_R_OPTS is guarded on fzf existing" \
    "nocomment $COMMON_SRC | grep -qE 'df_have fzf && export FZF_CTRL_R_OPTS'"
# Scoping matters: --exact in FZF_DEFAULT_OPTS would force it on the file and
# directory pickers too, where fuzzy matching is the entire point.
assert "--exact is scoped to ^R, not global" \
    "[[ -z \$(nocomment $COMMON_SRC | grep 'FZF_DEFAULT_OPTS' | grep -- '--exact') ]]"

sec "structural: shell completion site-functions scheme (no network)"
ZSHRC_SRC="home/dot_config/shell/zsh.sh"
BASHRC_SRC="home/dot_config/shell/bash.sh"
RCSH_SRC="home/dot_config/shell/rc.sh"
assert "zsh.sh adds the site-functions dir to \$fpath" \
    "grep -qF 'fpath=(\"\$_dotfiles_site_functions\" \$fpath)' $ZSHRC_SRC"
assert "zsh.sh points at the XDG site-functions path" \
    "grep -qF 'zsh/site-functions' $ZSHRC_SRC"
# Guarded, so a machine that has not run the fetchers yet gets no dangling entry.
assert "the \$fpath entry is guarded on the dir existing" \
    "grep -qF 'if [ -d \"\$_dotfiles_site_functions\" ]; then' $ZSHRC_SRC"
# ORDERING, not presence. An assert that merely greps for the line passes a
# mutation that moves it after compinit — which is the actual failure mode, and
# it is silent. rc.sh sources zsh.sh (step 3) strictly before it runs compinit
# (step 7), so prove the ordering in rc.sh itself.
assert "rc.sh sources <shell>.sh BEFORE compinit" \
    "[[ \$(grep -n 'DOTFILES_SHELL.sh\"' $RCSH_SRC | head -1 | cut -d: -f1) -lt \$(grep -n 'compinit -C' $RCSH_SRC | cut -d: -f1) ]]"
# The $fpath line must NOT have been parked in the post-compinit tool-init block.
assert "the \$fpath entry is not in the post-compinit block" \
    "awk '/^[[:space:]]*#/{next} /dotfiles_tool_init/{f=1} END{exit f?1:0}' $ZSHRC_SRC"
# Comment-stripped: the block's own comment names this path while explaining the
# scheme, so a raw grep matches the prose and survives deleting the actual code.
# (It did exactly that when first written raw — the mutation went uncaught.)
assert "bash.sh sources the XDG bash-completion dir" \
    "nocomment $BASHRC_SRC | grep -qF 'bash-completion/completions'"
assert "bash.sh guards the completion dir on existence" \
    "grep -qF 'if [ -d \"\$_dotfiles_bash_completions\" ]; then' $BASHRC_SRC"
# Both helpers live in _lib.sh so the rename rule exists in exactly one place.
assert "_lib.sh defines fb_install_completions"     "grep -qE '^fb_install_completions\\(\\)' $LIB"
assert "_lib.sh defines fb_remove_completions"      "grep -qE '^fb_remove_completions\\(\\)' $LIB"
assert "_lib.sh defines both completion dir helpers" \
    "grep -qE '^fb_completion_zsh_dir\\(\\)' $LIB && grep -qE '^fb_completion_bash_dir\\(\\)' $LIB"
# Surgical teardown: these are shared dirs that may hold a distro package's
# completions, so removal must rmdir upward rather than rm -rf the directory.
# Scoped to fb_remove_completions' body: matching on the directory NAMES is
# useless because the code refers to them through $zdir/$bdir, so a literal
# `rm -rf "$zdir"` would slip straight past. Assert no rm -rf anywhere in the
# function instead. (remove_bin legitimately uses rm -rf, hence the range.)
assert "completion teardown never uses rm -rf" \
    "awk '/^fb_remove_completions\\(\\)/{i=1;next} i&&/^}/{exit} i&&/^[[:space:]]*#/{next} i&&/rm -rf/{f=1} END{exit f?1:0}' $LIB"
assert "completion teardown rmdirs upward instead"  "grep -qF 'rmdir \"\$zdir\" \"\$bdir\"' $LIB"

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

# ===========================================================================
# Slots 18-21 end to end. The structural group above pins the SOURCE; this one
# proves the parts that only a real fetch can: that the interpolated inner
# directory actually matches what upstream ships (the tag-vs-version split is
# invisible until you extract), that the completion files land under their
# autoload names, and that delta's git wiring is applied and is idempotent.
if [[ $RUN_BINS == 1 ]]; then
    sec "fd/bat/delta/xh fetchers (slots 18-21, ~13 MB) — binaries, completions, git wiring"
    ZDIR="$SB/.local/share/zsh/site-functions"
    BDIR="$SB/.local/share/bash-completion/completions"
    for t in 18:fd 19:bat 20:delta 21:xh; do
        slot="${t%%:*}"; tool="${t##*:}"
        f="$SB/.local/bin/fetch.bins/${slot}_fetch.${tool}.sh"
        if [[ -x "$f" ]]; then
            "$f" >/dev/null 2>&1
            assert "$tool installed + --version works" "\"$BIN_DIR/$tool\" --version >/dev/null 2>&1"
            assert "$tool symlink -> ~/.local/apps"    "[[ \"\$(readlink -f \"$BIN_DIR/$tool\")\" == \"$APP_DIR\"/* ]]"
            assert "installed $tool is an ELF binary"  "head -c4 \"\$(readlink -f \"$BIN_DIR/$tool\")\" | grep -q ELF"
            # The autoload name is the whole point: bat ships bat.zsh, and a file
            # installed under that name is never loaded by zsh — silently.
            assert "$tool zsh completion installed as _$tool" "[[ -s \"$ZDIR/_$tool\" ]]"
            assert "$tool bash completion installed as $tool" "[[ -s \"$BDIR/$tool\" ]]"
        else
            skip "$tool fetcher not present (apply group did not run)"
        fi
    done
    # bat is the ONE whose upstream zsh filename differs from its autoload name,
    # so prove the rename actually happened rather than a copy under the old name.
    assert "bat.zsh was RENAMED, not copied verbatim" "[[ ! -e \"$ZDIR/bat.zsh\" ]]"
    # zsh must actually autoload them. This is the assertion the rename exists for:
    # with the file named bat.zsh it resolves to nothing and nothing warns.
    if command -v zsh >/dev/null 2>&1; then
        comps="$(zsh -f -c '
            fpath=("'"$ZDIR"'" ${^${(M)fpath:#*/functions*}})
            autoload -Uz compinit && compinit -u -D
            for c in fd bat delta xh; do print -r -- "$c=${_comps[$c]:-NONE}"; done' 2>/dev/null)"
        for c in fd bat delta xh; do
            assert "zsh autoloads the $c completion" "[[ \"\$comps\" == *\"$c=_$c\"* ]]"
        done
    else
        skip "zsh completion autoload check (no zsh on PATH)"
    fi
    # delta's git wiring. GIT_CONFIG_GLOBAL is pinned into the sandbox at setup,
    # so these read the sandbox file and never the developer's real ~/.gitconfig.
    if [[ -x "$BIN_DIR/delta" ]]; then
        assert "git core.pager set to delta"        "[[ \"\$(git config --global --get core.pager)\" == delta ]]"
        assert "git interactive.diffFilter set"     "[[ \"\$(git config --global --get interactive.diffFilter)\" == 'delta --color-only' ]]"
        assert "git delta.navigate set"             "[[ \"\$(git config --global --get delta.navigate)\" == true ]]"
        assert "git delta.side-by-side set"         "[[ \"\$(git config --global --get delta.side-by-side)\" == true ]]"
        assert "git delta.line-numbers set"         "[[ \"\$(git config --global --get delta.line-numbers)\" == true ]]"
        # Re-running must not duplicate keys or sections — `git config --global`
        # replaces in place, and this proves it for the section header too.
        "$SB/.local/bin/fetch.bins/20_fetch.delta.sh" >/dev/null 2>&1
        assert "re-run does not duplicate [delta]"  "[[ \$(grep -c '^\\[delta\\]' \"$GIT_CONFIG_GLOBAL\") -eq 1 ]]"
        assert "re-run does not duplicate core.pager" "[[ \$(git config --global --get-all core.pager | wc -l) -eq 1 ]]"
        # Teardown reverses it, and survives a second run (--unset on an absent
        # key exits 5, --remove-section on an absent section exits 128).
        git config --global --unset core.pager || true
        git config --global --unset interactive.diffFilter || true
        git config --global --remove-section delta || true
        assert "teardown clears core.pager"         "[[ -z \"\$(git config --global --get core.pager || true)\" ]]"
        assert "teardown removes the [delta] section" "! grep -q '^\\[delta\\]' \"$GIT_CONFIG_GLOBAL\""
        # Completion teardown is surgical: our files go, the dirs go only if empty.
        ( . "$LIB" >/dev/null 2>&1; fb_remove_completions fd bat delta xh ) >/dev/null 2>&1
        assert "teardown removes zsh completions"   "[[ ! -e \"$ZDIR/_fd\" && ! -e \"$ZDIR/_bat\" && ! -e \"$ZDIR/_delta\" && ! -e \"$ZDIR/_xh\" ]]"
        assert "teardown removes bash completions"  "[[ ! -e \"$BDIR/fd\" && ! -e \"$BDIR/bat\" && ! -e \"$BDIR/delta\" && ! -e \"$BDIR/xh\" ]]"
    else
        skip "delta git wiring (delta not installed)"
    fi
else
    skip "fd/bat/delta/xh fetchers (pass --bins or RUN_BINS_FETCH=1 to enable)"
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
if [[ $FAIL -eq 0 ]]; then
    echo "  ✅ all assertions passed"
    exit 0
fi
printf '  failing assertions:\n'
printf '    - %s\n' "${FAILED[@]}"
# The counter and the list are written by the same line of bad(), so they can only
# disagree if a failure was raised in a subshell — where the increment is lost too.
# That is unprovable from here, but the divergence it leaves behind is not.
[[ ${#FAILED[@]} -eq $FAIL ]] || \
    printf '  ⚠ %d failures counted but %d captured — a bad() ran in a subshell\n' \
        "$FAIL" "${#FAILED[@]}"
if [[ -s "$EVID_LOG" ]]; then
    KEEP_EVID=1
    printf '  probe transcript (the raw stdout/stderr the asserts discard): %s\n' "$EVID_LOG"
fi
echo "  ❌ failures above"
exit 1
