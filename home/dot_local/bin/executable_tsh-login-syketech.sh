#!/bin/bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -eu

# Derived from arg0, never hardwired: this file is applied by chezmoi and the
# name it lands under is not this script's to assert. A hardwired name goes stale
# silently -- the messages keep naming a file that no longer exists.
me="${0##*/}"

PROXY=syketech.com
ITEM="Syketech Teleport"
# A distinctly named local. Assigning to USER would clobber the standard
# environment variable for the rest of the process.
login=suykerbuyk
# Force the OTP flow. With a WebAuthn passkey enrolled, `tsh` otherwise offers
# every registered factor at once -- it tries a security key that does not exist
# here, and its prompt changes wording depending on what is registered. Pinning
# the mode makes the prompt DETERMINISTIC instead of something to pattern-match,
# and skips a WebAuthn attempt that can only fail on a machine with no CTAP key.
# Override once a security key exists: TSH_LOGIN_MFA_MODE=cross-platform.
mfa_mode="${TSH_LOGIN_MFA_MODE:-otp}"

# Scoped to THIS proxy on purpose: a bare `tsh status` exits 0 while logged in to
# any cluster, so an unscoped check would skip the login we actually need.
# Measured: exit 0 with a live syketech.com profile, exit 1 without one.
#
# This runs before the tool guards so a still-valid session costs nothing -- in
# particular it never wakes `op`, which is a biometric prompt. A missing `tsh`
# exits 127 here, falls through, and is reported by the guard below.
if tsh status --proxy="$PROXY" >/dev/null 2>&1; then
	printf 'Already logged in to %s -- nothing to do.\n' "$PROXY"
	exit 0
fi

# Presence guards, cheapest failure first. `df_have` is NOT usable here: it is a
# sourced shell function from the rc layer and this file sources nothing. Inline
# `command -v` is the lifestyle-bin idiom (see executable_hrdr). A bare `have` is
# never safe in this repo -- bash-completion does `unset -f have`.
if ! command -v tsh >/dev/null 2>&1; then
	printf '%s: tsh not found on PATH.\n' "$me" >&2
	exit 1
fi

if ! command -v op >/dev/null 2>&1; then
	printf '%s: 1Password CLI (op) not found on PATH.\n' "$me" >&2
	printf '  Install it, or log in manually:\n' >&2
	printf '    tsh login --proxy=%s --user=%s\n' "$PROXY" "$login" >&2
	exit 1
fi

export TELEPORT_TLS_ROUTING_CONN_UPGRADE=true
# The rc layer already exports this on desktops carrying the 1Password agent
# (dot_config/bashrc.d/10-ssh-agent.sh). Repeated here for headless boxes and
# non-interactive shells, which never reach that branch.
export TELEPORT_USE_LOCAL_SSH_AGENT=false

# One `op` call per distinct secret. An earlier version fetched the password
# twice -- once into a variable it then never read, and once inline for a paste
# buffer -- costing an extra unlock prompt for nothing.
pass="$(op item get "$ITEM" --fields label=password --reveal)"
otp="$(op item get "$ITEM" --otp)"

# ---------------------------------------------------------------------------
# Preferred path: drive `tsh login` under a pty and answer its prompts directly.
#
# `tsh` takes no password on stdin -- it opens the terminal and reads with echo
# off -- so a pty is the only way to answer it programmatically. Doing so means
# the secret never lands in ANY shared surface: no paste buffer, no system
# clipboard, no argv. That is also why there is no multiplexer branch here.
# tmux, herdr and a bare terminal all take this identical path, which is the
# whole point: herdr has no paste-buffer concept to port the old approach to.
#
# Secrets reach the driver on STDIN. Never on argv (/proc/PID/cmdline is
# WORLD-readable) and never in the environment (owner-readable, and this box runs
# other agents under the same user).
#
# python3 is a SOFT dependency, matching how the rest of this repo treats it (it
# is one of four fb_unzip backends, never required). No pip, no venv: pty, os,
# select, termios, tty, fcntl and signal are all standard library.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
	driver="$(mktemp)"
	trap 'rm -f "$driver"' EXIT INT TERM
	cat >"$driver" <<'PYDRIVER'
import errno, fcntl, os, pty, select, signal, sys, termios, time, tty

PASSWORD_CUE = b"password for Teleport user"
# tsh's MFA prompt CHANGES with what is registered. Before a passkey existed it
# read "Enter an OTP code from a device:"; with two factors it reads "Tap any
# security key or enter a code from a OTP device" -- which does not contain the
# substring "OTP code". Matching one literal missed the other and the login hung
# with the code never sent. Match a SET, lowercased. --mfa-mode above should make
# this moot; it is kept because a silent hang is the expensive failure.
OTP_CUES = (b"otp code", b"otp device", b"enter a code")
FIRST_PROMPT_TIMEOUT = float(os.environ.get("TSH_LOGIN_PROMPT_TIMEOUT", "30"))
TAIL = 512


def winsize(dst, src):
    try:
        fcntl.ioctl(dst, termios.TIOCSWINSZ,
                    fcntl.ioctl(src, termios.TIOCGWINSZ, b"\0" * 8))
    except OSError:
        pass


def main():
    argv = sys.argv[1:]
    if not argv:
        return 2
    raw = sys.stdin.buffer.read().split(b"\n")
    password = raw[0] if raw else b""
    otp = raw[1] if len(raw) > 1 else b""
    try:
        term = os.open("/dev/tty", os.O_RDWR)
    except OSError:
        sys.stderr.write("no controlling terminal; cannot drive tsh\n")
        return 2

    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execvp(argv[0], argv)
        except OSError as exc:
            os.write(2, f"cannot exec {argv[0]}: {exc}\n".encode())
        os._exit(127)

    winsize(master, term)
    try:
        signal.signal(signal.SIGWINCH, lambda *_: winsize(master, term))
    except (ValueError, OSError):
        pass

    saved = None
    try:
        saved = termios.tcgetattr(term)
        tty.setraw(term)
    except termios.error:
        saved = None

    sent_pw = sent_otp = warned = otp_warned = False
    seen = b""
    deadline = time.monotonic() + FIRST_PROMPT_TIMEOUT
    otp_deadline = None
    try:
        while True:
            pending = (not sent_pw) or (otp and not sent_otp)
            try:
                ready, _, _ = select.select([master, term], [], [],
                                            0.5 if pending else None)
            except OSError as exc:
                if exc.errno == errno.EINTR:
                    continue
                raise
            # Never guess. If the expected prompt has not appeared, stop trying to
            # inject and leave the terminal to the human -- a password written at
            # the wrong moment is a failed login, and failed logins lock accounts.
            if not sent_pw and not warned and time.monotonic() > deadline:
                warned = True
                os.write(term, b"\r\n[tsh-login] no password prompt seen;"
                               b" type it yourself -- injection abandoned.\r\n")
            # Symmetric warning for the second factor. Without it a missed OTP cue
            # hangs in silence, which is exactly how the 2026-08-15 live trial
            # failed: the code was in hand and never sent, and nothing said so.
            if (sent_pw and otp and not sent_otp and not otp_warned
                    and otp_deadline is not None
                    and time.monotonic() > otp_deadline):
                otp_warned = True
                os.write(term, b"\r\n[tsh-login] no OTP prompt recognised;"
                               b" type the code yourself.\r\n")
            if master in ready:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                os.write(term, chunk)
                seen = (seen + chunk)[-TAIL:]
                if not sent_pw and PASSWORD_CUE in seen:
                    os.write(master, password + b"\n")
                    sent_pw = True
                    seen = b""
                    otp_deadline = time.monotonic() + FIRST_PROMPT_TIMEOUT
                elif (sent_pw and not sent_otp and otp
                      and any(cue in seen.lower() for cue in OTP_CUES)):
                    os.write(master, otp + b"\n")
                    sent_otp = True
                    seen = b""
            if term in ready:
                try:
                    chunk = os.read(term, 4096)
                except OSError:
                    chunk = b""
                if chunk:
                    os.write(master, chunk)
    finally:
        if saved is not None:
            try:
                termios.tcsetattr(term, termios.TCSAFLUSH, saved)
            except termios.error:
                pass
        os.close(master)

    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


sys.exit(main())
PYDRIVER

	# `printf` is a bash builtin, so the pipeline forks without exec'ing and the
	# secrets never appear in any process's cmdline.
	# `--ttl` is MINUTES, so 1800 is 30 HOURS -- already at Teleport's typical
	# hard cap, and the cluster's own default is 12h. Not a number to raise.
	printf '%s\n%s\n' "$pass" "$otp" |
		python3 "$driver" tsh login --proxy="$PROXY" --user="$login" \
			--mfa-mode="$mfa_mode" --ttl 1800
	exit $?
fi

# ---------------------------------------------------------------------------
# Fallback: no python3. Nothing is auto-typed, so the human drives `tsh` by hand.
#
# There is deliberately no paste-buffer branch here. tmux's `set-buffer` had no
# herdr equivalent (herdr exposes no buffer or clipboard command at all), so
# keeping it would have meant one multiplexer getting a convenience the other
# could not, plus a live secret parked in a shared surface -- and on the pty path
# above nothing needs pasting in the first place.
# ---------------------------------------------------------------------------
printf '%s: python3 not found -- falling back to a manual login.\n' "$me" >&2
printf '  Password: copy it from 1Password ("%s").\n' "$ITEM" >&2

# RULING (2026-08-15, human): the OTP is printed on stdout. It is a known
# exposure -- `tmux-pane-log` can persist it and it sits in scrollback -- weighed
# and accepted for convenience. Do NOT "fix" this as a regression; reopen the
# ruling instead. It applies to this manual path, where the human still has to
# read the code; the pty path above types it and never displays it.
printf 'One time password: %s\n' "$otp"

tsh login --proxy="$PROXY" --user="$login" --mfa-mode="$mfa_mode" --ttl 1800
