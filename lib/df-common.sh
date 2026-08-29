# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# df-common.sh — shared helpers for repo-root management CLIs.
# Source from a root script:  . "$(dirname "$0")/lib/df-common.sh" && df_init "$0"
#
# Not a user command. Bootstrap (update-user-home-dir.sh) keeps its own fetch.bins
# lib; this is for day-2 tools that run from an already-cloned checkout.

# df_init <path-to-invoking-script>
# Sets DF_ROOT (checkout root) and DF_SRC (chezmoi source tree = $DF_ROOT/home).
df_init() {
	_self=$1
	case ${_self} in
	/*) _dir=$(dirname "${_self}") ;;
	*) _dir=$(dirname "$(pwd)/${_self}") ;;
	esac
	# Resolve .. and symlinks when readlink -f exists.
	if command -v readlink >/dev/null 2>&1 && readlink -f "${_dir}" >/dev/null 2>&1; then
		DF_ROOT=$(readlink -f "${_dir}")
	else
		DF_ROOT=$(CDPATH= cd "${_dir}" && pwd)
	fi
	# If we were sourced as lib/df-common.sh, caller should pass the root script
	# path; if DF_ROOT ends in /lib, climb one level.
	case ${DF_ROOT} in
	*/lib) DF_ROOT=$(dirname "${DF_ROOT}") ;;
	esac
	DF_SRC=${DF_ROOT}/home
	if [ ! -d "${DF_SRC}" ]; then
		printf 'df: not a dotfiles checkout (missing %s) — run from the repo root.\n' "${DF_SRC}" >&2
		return 1
	fi
	return 0
}

df_have() { command -v "$1" >/dev/null 2>&1; }

# df_op_resolve [path] — print the real path of the 1Password CLI binary.
# Default: `command -v op` through readlink -f. Fails if op is not on PATH.
df_op_resolve() {
	_op_p=${1-}
	if [ -z "${_op_p}" ]; then
		_op_p=$(command -v op) || return 1
	fi
	if command -v readlink >/dev/null 2>&1; then
		_op_r=$(readlink -f "${_op_p}" 2>/dev/null) || _op_r=${_op_p}
	else
		_op_r=${_op_p}
	fi
	printf '%s\n' "${_op_r}"
}

# df_op_linux_sgid_ok [path]
#
# True when the 1Password CLI binary can pass the Linux desktop-app GID
# check: the setgid bit is set AND the file group is onepassword-cli.
# The app resets 1Password-BrowserSupport.sock otherwise (ECONNRESET
# before any message is accepted). Path defaults to `command -v op`
# resolved through readlink -f. Non-Linux callers get false — the check
# is Linux-only. Canonical predicate; the login helper and slot 23
# duplicate a short copy because those files cannot source this one.
df_op_linux_sgid_ok() {
	[ "$(uname -s)" = Linux ] || return 1
	_op_p=$(df_op_resolve "${1-}") || return 1
	[ -f "${_op_p}" ] || return 1
	[ -g "${_op_p}" ] || return 1
	[ "$(stat -c '%G' "${_op_p}" 2>/dev/null)" = onepassword-cli ] || return 1
	return 0
}

# df_op_linux_sgid_fix [path] — print the rootless-fetcher sudo lines for
# the resolved binary. Includes groupadd when the group does not exist.
# Prints to stdout; the caller decides stderr vs the doctor report.
df_op_linux_sgid_fix() {
	_op_p=$(df_op_resolve "${1-}") || return 1
	if ! getent group onepassword-cli >/dev/null 2>&1; then
		printf '    sudo groupadd -f onepassword-cli\n'
	fi
	printf '    sudo chgrp onepassword-cli %s\n' "${_op_p}"
	printf '    sudo chmod g+s %s\n' "${_op_p}"
}

# df_delta_gitconfig_reconcile — drop delta's five git keys when delta cannot run.
#
# THE ONLY implementation of this rule, deliberately. It has two call sites and
# they must not be able to disagree about what "delta is available" means:
#   1. ./doctor — the once-per-login health check (rc.sh runs dotfiles-doctor once
#      per login session era), so a machine whose delta went away self-heals.
#   2. update-user-home-dir.sh --uninstall --force, AFTER `remove_bin delta`.
#
# THE PREDICATE IS OPERABILITY, NOT PRESENCE: `delta --version`, never
# `command -v delta` and never df_have (which IS command -v, just above). That is
# not pedantry here. delta is the one fetcher with a gnu fallback on
# architectures with no musl build, so present-but-not-runnable is a REAL state
# for it — wrong glibc, dangling symlink, cross-arch ELF (exactly what fetching
# the aarch64 build onto an x86_64 box produces). `command -v` reports success for
# every one of those, which would leave core.pager aimed at a binary that cannot
# execute — precisely the breakage this function exists to prevent, since
# `git diff` then dies with "unable to execute pager 'delta'" and exit 128.
#
# A SYSTEM-packaged delta is a legitimate delta. If any delta still runs after
# ours has been removed, the wiring is still valid and is left untouched.
#
# Silence: nothing to remove => completely silent, exit 0. Keys actually removed
# => exactly ONE informational line, because silently rewriting a user's global
# git config is worse than saying so. It is a notice, not an error.
#
# Every git call is guarded and its stderr suppressed: `--unset` on an absent key
# exits 5 and `--remove-section` on an absent section exits 128 (and prints
# "fatal: no such section"), and both call sites run under `set -e`.
#
# No locking, deliberately: rc.sh gates the greet behind a `set -C` stamp in
# $XDG_RUNTIME_DIR, so exactly one shell per login session reaches this. A lost
# race degrades to "heals next session", never to an error.
df_delta_gitconfig_reconcile() {
	command -v git >/dev/null 2>&1 || return 0

	# Operability, not presence — see above. Do not "simplify" to command -v.
	if delta --version >/dev/null 2>&1; then
		return 0
	fi

	# Stay completely silent when there is nothing of ours to remove.
	_dg_had=0
	for _dg_k in core.pager interactive.diffFilter \
		delta.navigate delta.side-by-side delta.line-numbers; do
		if git config --global --get "${_dg_k}" >/dev/null 2>&1; then
			_dg_had=1
		fi
	done
	if [ "${_dg_had}" -eq 0 ]; then
		return 0
	fi

	# Surgical, as with podman's config and ghostty's terminfo: unset only the
	# keys we set. NEVER --remove-section core or --remove-section interactive —
	# the user keeps unrelated settings in both (excludesfile, singleKey, …).
	# Only [delta] is ours end to end, so only it goes wholesale.
	git config --global --unset core.pager >/dev/null 2>&1 || true
	git config --global --unset interactive.diffFilter >/dev/null 2>&1 || true
	git config --global --remove-section delta >/dev/null 2>&1 || true
	printf 'delta is not runnable — removed its git pager settings (core.pager, interactive.diffFilter, [delta]).\n'
	return 0
}

df_die() {
	printf '%s\n' "$*" >&2
	exit 1
}

# Prefer the fetched binary; fall back to PATH.
df_chezmoi_bin() {
	if [ -x "${HOME}/.local/bin/chezmoi" ]; then
		printf '%s\n' "${HOME}/.local/bin/chezmoi"
		return 0
	fi
	if df_have chezmoi; then
		command -v chezmoi
		return 0
	fi
	return 1
}

# df_chezmoi <args...>  — chezmoi with this checkout as --source.
df_chezmoi() {
	_cm=$(df_chezmoi_bin) || df_die "df: chezmoi not found — run ./update-user-home-dir.sh first"
	"${_cm}" --source "${DF_SRC}" --destination "${HOME}" --no-tty "$@"
}
