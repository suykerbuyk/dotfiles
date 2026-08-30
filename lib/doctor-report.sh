# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# doctor-report.sh — print the dotfiles health report.
# Requires: df_doctor_registry. Optional: DF_ROOT for checkout-relative installer hints.

df_doctor_fetch_bins_dirs() {
	[ -d "${HOME}/.local/bin/fetch.bins" ] && printf '%s\n' "${HOME}/.local/bin/fetch.bins"
	if [ -n "${DF_ROOT:-}" ] && [ -d "${DF_ROOT}/home/dot_local/bin/fetch.bins" ]; then
		printf '%s\n' "${DF_ROOT}/home/dot_local/bin/fetch.bins"
	fi
}

# df_doctor_installer_for <stem> — print path of matching fetcher, or fail.
# Note: must not use a pipe-to-while (subshell) or the found path is lost.
df_doctor_installer_for() {
	_stem=$1
	[ -n "${_stem}" ] || return 1
	_found=
	# Applied names: 01_fetch.jq.sh ; source names: executable_01_fetch.jq.sh
	for _dir in "${HOME}/.local/bin/fetch.bins" ${DF_ROOT:+"${DF_ROOT}/home/dot_local/bin/fetch.bins"}; do
		[ -n "${_dir}" ] && [ -d "${_dir}" ] || continue
		for _pat in "${_dir}"/*_fetch."${_stem}".sh "${_dir}"/executable_*_fetch."${_stem}".sh; do
			if [ -r "${_pat}" ]; then
				printf '%s\n' "${_pat}"
				return 0
			fi
		done
	done
	return 1
}

df_have() { command -v "$1" >/dev/null 2>&1; }

df_doctor_report() {
	_shell=${DOTFILES_SHELL:-unknown}
	if [ "${_shell}" = unknown ]; then
		if [ -n "${ZSH_VERSION:-}" ]; then
			_shell=zsh
		elif [ -n "${BASH_VERSION:-}" ]; then
			_shell=bash
		fi
	fi

	printf 'shell:  %s\n' "${_shell}"
	printf 'env:    %s (PATH + exports, every shell)\n' "${HOME}/.config/shell/env.sh"
	printf 'rc:     %s (interactive only)\n\n' "${HOME}/.config/shell/common.sh"

	_fb_hint=${HOME}/.local/bin/fetch.bins
	df_doctor_registry | while IFS='|' read -r _cmd _stem _note; do
		# Row literals write the note with a leading space for legibility;
		# strip it so every branch below aligns identically.
		_note=${_note# }
		# "Not provisioned by this repo" is an EMPTY STEM — the registry's own
		# stated contract — and NEVER a non-empty note. The two predicates
		# agreed only while notes appeared exclusively on stemless rows, which
		# stopped being true the moment a provisioned tool wanted an
		# explanatory one. Keying on the note told the user this repo does not
		# ship tree-sitter/herdr/ghostty/delta, and swallowed the only
		# actionable thing on the line — the fetcher to run — at precisely the
		# moment it is worth reading, i.e. when that fetcher has failed.
		if df_have "${_cmd}"; then
			# op: presence is not operability. Linux desktop IPC
			# authenticates the CLI by setgid group onepassword-cli;
			# a user-owned 0755 binary gets ECONNRESET. Report NEED
			# (and the two sudo lines) instead of a green ok.
			# Requires df_op_linux_sgid_ok from lib/df-common.sh.
			if [ "${_cmd}" = op ] && df_is_linux && ! df_op_linux_sgid_ok; then
				_op_real=$(df_op_resolve) || _op_real=$(command -v op)
				printf '  %-9s %-5s %s\n' "${_cmd}" 'NEED' \
					"${_op_real} is not setgid onepassword-cli (desktop IPC will reset)"
				df_op_linux_sgid_fix "${_op_real}"
			else
				printf '  %-9s %-5s %s\n' "${_cmd}" 'ok' "$(command -v "${_cmd}")"
			fi
		elif [ -z "${_stem}" ]; then
			printf '  %-9s %-5s %s\n' "${_cmd}" 'n/a' "${_note}"
		elif _inst=$(df_doctor_installer_for "${_stem}"); then
			printf '  %-9s %-5s → run %s%s\n' "${_cmd}" 'MISS' "${_inst}" "${_note:+  (${_note})}"
		else
			printf '  %-9s %-5s (no installer in %s)%s\n' "${_cmd}" 'MISS' "${_fb_hint}" "${_note:+  (${_note})}"
		fi
	done

	# No broot `br` special case here, deliberately. The rc layer defines `br` by
	# eval'ing `broot --print-shell-function "$DOTFILES_SHELL"` whenever the binary
	# is present (see ~/.config/shell/common.sh), so the shim cannot be missing
	# independently of the binary — the plain `broot` row above already covers it.
	# The old check tested ~/.config/broot/launcher/<shell>/br and advised
	# `broot --install`; under zsh that path is never created by any amount of
	# --install, so the note could never be cleared.

	if [ ! -d "${HOME}/.local/apps/nvm" ]; then
		if _inst=$(df_doctor_installer_for nvm); then
			printf '  %-9s %-5s → run %s\n' 'nvm' 'MISS' "${_inst}"
		fi
	else
		printf '  %-9s %-5s %s\n' 'nvm' 'ok' "${HOME}/.local/apps/nvm"
	fi

	if [ -d /opt/rocm/bin ]; then
		printf '  %-9s %-5s /opt/rocm\n' 'rocm' 'ok'
	else
		printf '  %-9s %-5s system package, not provisioned by this repo (/opt/rocm)\n' 'rocm' 'n/a'
	fi

	# Tool-integration staleness. dotfiles_tool_init evals each tool's shell
	# integration ONCE, at shell start, and exports DOTFILES_TOOL_INIT_EPOCH when
	# it does. Phase 5 of the installer then replaces those same binaries
	# underneath shells that are already running, and nothing reconciles the two,
	# so a long-lived shell keeps the old integration indefinitely — silently,
	# with nothing to grep and no version mismatch anywhere a user would look.
	#
	# stat MUST dereference (-L). These are ~/.local/bin/<tool> symlinks into
	# ~/.local/apps/, and the link mtime tracks neither the tool nor the upgrade:
	# measured here, fzf's link was 4 months OLDER than its binary while
	# starship's was NEWER than its own. Only the resolved binary answers the
	# question, so a check without -L would sit there reporting `ok` forever.
	_stale=
	if [ -n "${DOTFILES_TOOL_INIT_EPOCH:-}" ]; then
		for _t in starship fzf tv herdr broot; do
			_p=$(command -v "${_t}" 2>/dev/null) || continue
			_m=$(df_stat_mtime "${_p}") || continue
			[ "${_m}" -gt "${DOTFILES_TOOL_INIT_EPOCH}" ] && _stale="${_stale}${_stale:+, }${_t}"
		done
		if [ -n "${_stale}" ]; then
			printf '  %-9s %-5s %s\n' 'tool-init' 'STALE' \
				"${_stale} newer than this shell's integrations — run: dotfiles-reinit"
		else
			printf '  %-9s %-5s %s\n' 'tool-init' 'ok' 'integrations current'
		fi
	else
		# Not a failure: a non-interactive shell never runs the rc layer, so
		# there is nothing to be stale. Only an INTERACTIVE shell missing the
		# stamp would be interesting, and doctor cannot tell the difference.
		printf '  %-9s %-5s %s\n' 'tool-init' 'n/a' 'no stamp (non-interactive shell)'
	fi

	# Secrets triad (see ./keys or dotfiles-keys).
	if [ -r "${HOME}/.keys" ]; then
		printf '  %-9s %-5s %s\n' 'keys' 'ok' \
			"${HOME}/.keys (mode $(df_stat_mode "${HOME}/.keys"), $(grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "${HOME}/.keys" 2>/dev/null || echo 0) entries) — edit: keys / dotfiles-keys"
	elif [ -r "${HOME}/.config/chezmoi/key.txt" ]; then
		printf '  %-9s %-5s %s\n' 'keys' 'MISS' 'age key present but ~/.keys not applied — run: ./keys status'
	else
		printf '  %-9s %-5s %s\n' 'keys' 'n/a' 'no age identity — restore it: ./keys get-key'
	fi

	return 0
}
