#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# Load SSH keys from 1Password into the running ssh-agent, with a TTL.
#
# For the GUI-less origin: a WSL session, or any terminal where the 1Password
# desktop app is not available to serve its own agent. Agent forwarding is the
# better answer when you HAVE a local agent worth forwarding; this is for when
# you do not.
#
# Key material goes vault -> op stdout -> pipe -> agent memory. It never touches
# disk, never appears in argv, never enters the environment. That is the same
# reasoning that put a pty in tsh-login-syketech.sh.
#
# ON DEMAND ONLY. Never source this from shell init: `op` can block on an
# approval prompt, its sessions expire after ~30 minutes of inactivity, and a
# per-shell cost here would be paid by every terminal you open.
#
# The manifest is HOST-LOCAL and unmanaged (like ~/.config/shell/env.d). Two
# reasons, both deliberate: the keys a laptop needs are not the keys a
# workstation needs, and this repo is PUBLIC -- a manifest committed here would
# publish which 1Password items hold which keys, for no benefit.
#
# Usage:
#   ssh-load-keys.sh              load every key in the manifest
#   ssh-load-keys.sh --list       show the manifest without contacting 1Password
#   ssh-load-keys.sh --help       this text
#
# Manifest: ~/.config/shell/ssh-keys.manifest, one 1Password ITEM UUID per line.
#   # comments and blank lines are ignored; text after the UUID is a label
#   x6xvuvozbcxxcbtae2gxakjun4   github
#
# Environment:
#   OP_SSH_VAULT   1Password vault holding the items (default: Personal)
#   SSH_KEY_TTL    seconds the key stays in the agent (default: 36000, ~a workday)
#   OP_READ_TIMEOUT  seconds to wait for each `op read` (default: 120). op can
#                  block forever on an approval prompt nobody answers.

set -u

me=${0##*/}

VAULT=${OP_SSH_VAULT:-Personal}
TTL=${SSH_KEY_TTL:-36000}
OP_TIMEOUT=${OP_READ_TIMEOUT:-120}
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
MANIFEST=${SSH_KEYS_MANIFEST:-${XDG_CONFIG_HOME:-$HOME/.config}/shell/ssh-keys.manifest}

case ${1-} in
-h | --help | help)
	# Print the header comment block, skipping the SPDX banner above it. Same
	# extractor as setup-ssh-agent.sh: a naive line-anchored one stops at the
	# blank line under the shebang and prints nothing, or prints the banner and
	# stops, which is what the harness's --help contract exists to catch.
	awk '/^# SPDX-License-Identifier:/{s=1;next}
	     s==1 && /^[[:space:]]*$/{next}
	     s==1 && /^#/{s=2}
	     s==2 && /^#/{sub(/^#[[:space:]]?/,"");print;next}
	     s==2{exit}' "$0"
	exit 0
	;;
esac

note() { printf '%s: %s\n' "$me" "$*" >&2; }

# ---------------------------------------------------------------------------
# Read the manifest first: it costs nothing and it is the most common reason
# there is nothing to do.
#
# Addressed by UUID, never by title. Two items in this vault are both called
# `SSH Key bd770i`, and a title-addressed read exits 1 with a disambiguation
# list rather than picking one -- measured. A UUID cannot collide.
#
# Read the subcommand BEFORE parsing, and parse with `read`, never `set --`:
# `set -- $line` rewrites the positional parameters, so `$1` stops being the
# argument the caller typed and `--list` silently became "load everything".
action=${1-}

items=()
labels=()
if [ -r "$MANIFEST" ]; then
	while read -r uuid rest || [ -n "${uuid:-}" ]; do
		uuid=${uuid%%#*}
		[ -n "$uuid" ] || continue
		case "$uuid" in \#*) continue ;; esac
		items+=("$uuid")
		rest=${rest%%#*}
		rest=${rest%"${rest##*[![:space:]]}"}
		labels+=("${rest:-$uuid}")
	done <"$MANIFEST"
fi

if [ ${#items[@]} -eq 0 ]; then
	note "no keys to load -- $MANIFEST is absent or empty"
	note "create it with one 1Password item UUID per line. To see the IDs:"
	note "    op item list --categories 'SSH Key'"
	exit 0
fi

if [ "$action" = --list ]; then
	printf 'manifest: %s\nvault:    %s\nttl:      %ss\n\n' "$MANIFEST" "$VAULT" "$TTL"
	i=0
	while [ "$i" -lt ${#items[@]} ]; do
		printf '  %s  %s\n' "${items[$i]}" "${labels[$i]}"
		i=$((i + 1))
	done
	exit 0
fi

# ---------------------------------------------------------------------------
# Skip cleanly where the tools are absent. A skip is not a failure -- this is
# the same posture fb_require_os takes for a slot with no build on this OS.
if ! command -v ssh-add >/dev/null 2>&1; then
	note "ssh-add not on PATH -- nothing to load into"
	exit 0
fi
if ! command -v op >/dev/null 2>&1; then
	note "1Password CLI (op) not on PATH -- skipping (op is linux/darwin only)"
	exit 0
fi

if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "${SSH_AUTH_SOCK:-}" ]; then
	note "no ssh-agent to load into (SSH_AUTH_SOCK unset or not a socket)"
	note "start one, or open a new shell -- see: dotfiles-doctor"
	exit 1
fi

# 🔴 The 1Password agent REFUSES keys added by ssh-add. Loading into it fails
# with a message that reads like a key problem rather than an agent problem,
# which is exactly the misdiagnosis this whole task started from. Catch it here
# and say what is actually wrong.
case "$SSH_AUTH_SOCK" in
*/.1password/agent.sock)
	note "SSH_AUTH_SOCK points at the 1Password agent, which refuses added keys."
	note "That agent already serves your vault directly -- there is nothing to load."
	note "To load into a plain agent instead, unset SSH_AUTH_SOCK and open a new shell."
	exit 1
	;;
esac

# ---------------------------------------------------------------------------
op_err=$(mktemp) || exit 1
add_err=$(mktemp) || exit 1
trap 'rm -f "$op_err" "$add_err"' EXIT INT TERM

loaded=0
failed=0
i=0

while [ "$i" -lt ${#items[@]} ]; do
	uuid=${items[$i]}
	label=${labels[$i]}
	i=$((i + 1))

	# `?ssh-format=openssh` is MANDATORY, not defensive. Measured across all 13
	# items in this vault: the default format is whatever the key was STORED in,
	# and 5 of 13 come back as PKCS#1 or PKCS#8, which ssh-add rejects with
	# `invalid format`. The parameter normalises every one of them, and openssh
	# is its only accepted value.
	#
	# `op item get` is never used, in any flag combination -- it returns a
	# decorated item, and under --format json it returns the private key in
	# CLEARTEXT with no --reveal, which is a leak waiting for a log file.
	#
	# The stream is piped UNMUTATED. A missing trailing newline, CRLF endings, or
	# one leading blank line each produce `invalid format`, so there is no
	# `--no-newline`, no `$( )` round-trip and no intermediate file.
	#
	# 🔴 BOUND the read. `op read` can block indefinitely waiting for an approval
	# or system-auth prompt that nobody is going to answer — measured here against
	# the real vault, where it sat until a 60s timeout killed it. Unbounded, this
	# script hangs forever on exactly the GUI-less box it exists to serve, which is
	# the same unbounded-prompt failure class as `ssh-add -T` against a locked
	# agent. The budget is generous on purpose: a human at a keyboard may take a
	# while to reach for the approval, so this is a "nobody is coming" bound, not a
	# latency target. Where timeout(1) is absent (not FreeBSD, not Linux, but be
	# honest about it) the read runs unbounded and the risk is stated, not hidden.
	: >"$op_err"
	: >"$add_err"
	if [ -n "$TIMEOUT_BIN" ]; then
		"$TIMEOUT_BIN" "$OP_TIMEOUT" \
			op read "op://${VAULT}/${uuid}/private key?ssh-format=openssh" 2>"$op_err" |
			ssh-add -t "$TTL" - >/dev/null 2>"$add_err"
	else
		op read "op://${VAULT}/${uuid}/private key?ssh-format=openssh" 2>"$op_err" |
			ssh-add -t "$TTL" - >/dev/null 2>"$add_err"
	fi
	# Capture the WHOLE array in one assignment. Reading ${PIPESTATUS[0]} into a
	# variable is itself a command, and it resets PIPESTATUS to that command's
	# single status -- so a following ${PIPESTATUS[1]} is unbound under `set -u`.
	rc=("${PIPESTATUS[@]}")
	rc_op=${rc[0]}
	rc_add=${rc[1]}

	# Read op's status, not just ssh-add's. On an expired session op writes to
	# stderr and exits non-zero while ssh-add reports `invalid format` against an
	# empty stream -- the misleading error this task was created from. Note also
	# that `op whoami` is NOT a usable liveness probe: in 2.39.0 it reports
	# "account is not signed in" while `op read` succeeds in the same second.
	# Success is exit 0 from the real command, nothing else.
	if [ "$rc_op" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
		note "op read timed out after ${OP_TIMEOUT}s for '$label' ($uuid)"
		note "  1Password did not answer — is the app unlocked, or the session live?"
		note "  raise the budget with OP_READ_TIMEOUT=<seconds> if the approval is just slow"
		failed=$((failed + 1))
		continue
	fi
	if [ "$rc_op" -ne 0 ]; then
		note "op could not read '$label' ($uuid)"
		if [ -s "$op_err" ]; then sed 's/^/  op: /' "$op_err" >&2; fi
		failed=$((failed + 1))
		continue
	fi
	if [ "$rc_add" -ne 0 ]; then
		note "ssh-add rejected '$label' ($uuid)"
		if [ -s "$add_err" ]; then sed 's/^/  ssh-add: /' "$add_err" >&2; fi
		failed=$((failed + 1))
		continue
	fi
	printf '%s: loaded %s (ttl %ss)\n' "$me" "$label" "$TTL"
	loaded=$((loaded + 1))
done

printf '%s: %s loaded, %s failed\n' "$me" "$loaded" "$failed" >&2
[ "$failed" -eq 0 ] || exit 1
exit 0
