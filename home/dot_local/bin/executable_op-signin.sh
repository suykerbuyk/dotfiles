#!/usr/bin/env sh

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# op-signin.sh -- obtain a 1Password CLI session on a headless (browserless) box
# and emit it for `eval`.
#
# Usage:
#   eval "$(op-signin.sh)"      # sign in; inject OP_SESSION_* into THIS shell
#   op-signin.sh --help
#
# WHY eval, and why a bin. This file is a CHILD process: it cannot export a
# variable back into the shell that launched it. `op signin` prints
# `export OP_SESSION_<shorthand>="..."` on stdout for exactly this reason, and
# this helper passes that line straight through. So the session reaches the
# parent shell only through `eval "$(...)"` -- which is the whole contract. The
# `op-session` shell function in ~/.config/shell/common.sh is the ergonomic
# one-word form of that same eval.
#
# SECRETS. The master password is read by `op` itself from /dev/tty with echo
# off -- never on argv, never in an exported variable. OP_SECRET_KEY (enroll
# only) is read by `op` from the ENVIRONMENT during `op account add`; it is never
# placed on a command line (/proc/PID/cmdline is world-readable). stdout carries
# ONLY the `export` line, so `eval` of a failed run is a safe no-op; everything
# human-facing goes to stderr.
#
# NOT the desktop-app path. This is CLI master-password auth, independent of the
# 1Password DESKTOP-APP IPC that tsh-login-syketech.sh documents (setgid group
# onepassword-cli on 1Password-BrowserSupport.sock). No setgid bit is involved
# here, so this file deliberately does NOT import df_op_linux_sgid_ok or print
# the chgrp/chmod fix -- those belong to the desktop-integration path only.

set -eu

# Derived from arg0, never hardwired: chezmoi decides the applied name, and a
# hardwired one goes stale silently in the messages below.
me="${0##*/}"

usage() {
	printf 'Usage: %s [--help]\n' "$me"
	printf '  Sign in to the 1Password CLI and print an `export OP_SESSION_*`\n'
	printf '  line on stdout for eval. Run it as:  eval "$(%s)"\n' "$me"
	printf '  (or the `op-session` shell function, which wraps that eval).\n'
	printf '\n'
	printf '  On a fresh box where the account is not yet enrolled, it is added\n'
	printf '  automatically ONLY when all three of OP_ACCOUNT_ADDRESS,\n'
	printf '  OP_ACCOUNT_EMAIL and OP_SECRET_KEY are staged in ~/.keys; otherwise\n'
	printf '  it signs in to the already-enrolled account and those vars are\n'
	printf '  unnecessary.\n'
}

case "${1:-}" in
-h | --help | help)
	usage
	exit 0
	;;
esac

die() {
	printf '%s: %s\n' "$me" "$*" >&2
	exit 1
}

# Presence guard, the lifestyle-bin idiom: inline `command -v`, never df_have (a
# sourced rc-layer function this file does not have). Unlike tsh-login there is
# nothing to DEGRADE to here -- with no `op` there is no session to obtain -- so
# a clear non-zero exit is the honest outcome, and the empty stdout makes the
# surrounding `eval` a no-op.
command -v op >/dev/null 2>&1 || die "1Password CLI (op) not found on PATH."

# The account to target. OP_ACCOUNT_ADDRESS is OPTIONAL: with it we pass
# --account (deterministic on a box enrolled with more than one account); without
# it `op signin` uses its single enrolled account. We stage OP_ACCOUNT_ADDRESS,
# NOT op's own OP_ACCOUNT selector -- exporting OP_ACCOUNT from ~/.keys would
# retarget `op` for every interactive shell, including tsh-login and
# ssh-load-keys.
addr="${OP_ACCOUNT_ADDRESS:-}"

# Does `op account list` already know this account? Matched on whichever
# identifier we were handed (address or email).
op_knows() {
	op account list 2>/dev/null | grep -Fq "$1"
}

# --- enroll-if-needed, announced -------------------------------------------
# Only when ALL THREE staged vars are present AND the account is absent. The
# add authenticates (reading OP_SECRET_KEY from the env and prompting for the
# master password on the tty); its own chatter is redirected to stderr so stdout
# stays reserved for the signin export below. ONE-TIME COST: enrolling and then
# signing in asks for the master password twice on a brand-new box; that is the
# first-run enroll path only, not the per-session path.
if [ -n "$addr" ] && ! op_knows "$addr" && ! op_knows "${OP_ACCOUNT_EMAIL:-}"; then
	if [ -n "${OP_ACCOUNT_EMAIL:-}" ] && [ -n "${OP_SECRET_KEY:-}" ]; then
		printf '%s: account %s not enrolled -- adding it (OP_SECRET_KEY read from env; a master-password prompt follows).\n' \
			"$me" "$addr" >&2
		op account add --address "$addr" --email "$OP_ACCOUNT_EMAIL" >&2 \
			|| die "op account add failed for $addr."
	else
		# Address staged but the enroll secrets are not -- name exactly what is
		# missing rather than failing opaquely inside `op signin` below.
		_missing=""
		[ -n "${OP_ACCOUNT_EMAIL:-}" ] || _missing="$_missing OP_ACCOUNT_EMAIL"
		[ -n "${OP_SECRET_KEY:-}" ] || _missing="$_missing OP_SECRET_KEY"
		die "account $addr not enrolled and cannot enroll --${_missing} absent from ~/.keys."
	fi
fi

# --- sign in ----------------------------------------------------------------
# Emit `op signin`'s OWN fresh stdout export line, never a cached OP_SESSION_*
# variable -- that is what makes a stale token impossible by construction.
# `op signin` is documented idempotent: it prompts only when not authenticated,
# so a live session re-emits its export with no prompt and a dead/absent one
# prompts and emits a fresh token. Either way `eval` receives a valid line.
#
# No authed pre-check is attempted. `op account get` and `op whoami` do not
# reliably distinguish a live session from a dead one (op whoami was rejected for
# this in ssh-load-keys; `op account get` was measured rc=1 against a live
# session), so a pre-check would either prompt redundantly or skip wrongly.
# Always-signin is correct on its own. TO BE CONFIRMED on a box that already
# holds a live session: that `op signin` there re-emits with no second prompt
# (this pane holds no session, so it cannot be exercised here).
if [ -n "$addr" ]; then
	op signin --account "$addr"
else
	op signin
fi
