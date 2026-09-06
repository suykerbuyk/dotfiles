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

	# Which ssh-agent did this environment actually select, and does it answer?
	#
	# There was no row for this, and that is why an agent outage read as a broken
	# vault for an afternoon: every failure in this area is silent. Two layers pick
	# the socket independently — env.sh for every shell, bashrc.d/10-ssh-agent.sh
	# for interactive ones — so "which agent am I using" genuinely is not something
	# a user can answer by reading one file.
	#
	# REACHABILITY, never signability. `ssh-add -l` answers instantly even against
	# a LOCKED 1Password agent (measured: rc 0, 13 identities listed). `ssh-add -T`
	# is the one that queues a GUI approval and blocks indefinitely on a display
	# nobody is watching — so it must never appear in a health report. What this row
	# can prove is that a socket exists and something answers on it; whether that
	# something will consent to sign is not knowable without risking the hang.
	#
	# Bounded anyway, where timeout(1) exists: a socket that listen()s but never
	# accepts makes `ssh-add -l` block forever, and doctor must degrade rather than
	# hang. Same posture as mnt.vault.sh's probe.
	_agent_sock=${SSH_AUTH_SOCK:-}
	if [ -z "${_agent_sock}" ]; then
		printf '  %-9s %-5s %s\n' 'agent' 'n/a' \
			'SSH_AUTH_SOCK unset — no agent in this environment'
	elif [ ! -S "${_agent_sock}" ]; then
		printf '  %-9s %-5s %s\n' 'agent' 'MISS' \
			"SSH_AUTH_SOCK names a non-socket: ${_agent_sock}"
	elif ! df_have ssh-add; then
		printf '  %-9s %-5s %s\n' 'agent' 'n/a' \
			"socket present but no ssh-add on PATH: ${_agent_sock}"
	else
		case "${_agent_sock}" in
		*/.1password/agent.sock) _agent_via='1Password app' ;;
		*/openssh_agent)         _agent_via='systemd ssh-agent.socket' ;;
		*/ssh-agent-*.sock)      _agent_via='plain ssh-agent (rc layer)' ;;
		/tmp/ssh-*/agent.*)      _agent_via='forwarded over ssh' ;;
		*/.keychain/*)           _agent_via='keychain' ;;
		*)                       _agent_via='unrecognised origin' ;;
		esac
		if df_have timeout; then
			_agent_out=$(SSH_AUTH_SOCK="${_agent_sock}" timeout 5 ssh-add -l 2>/dev/null)
		else
			_agent_out=$(SSH_AUTH_SOCK="${_agent_sock}" ssh-add -l 2>/dev/null)
		fi
		_agent_rc=$?
		# BSD wc pads; trim at the point of capture or a string compare skews.
		_agent_n=$(printf '%s\n' "${_agent_out}" | grep -c '^[0-9]' | tr -d ' ')
		case ${_agent_rc} in
		0) printf '  %-9s %-5s %s\n' 'agent' 'ok' \
			"${_agent_n} identities via ${_agent_via}" ;;
		1) printf '  %-9s %-5s %s\n' 'agent' 'ok' \
			"no identities loaded — via ${_agent_via}" ;;
		2) printf '  %-9s %-5s %s\n' 'agent' 'MISS' \
			"stale socket, nothing answers: ${_agent_sock}" ;;
		124) printf '  %-9s %-5s %s\n' 'agent' 'MISS' \
			"${_agent_via} did not answer within 5s: ${_agent_sock}" ;;
		*) printf '  %-9s %-5s %s\n' 'agent' 'MISS' \
			"ssh-add exited ${_agent_rc} against ${_agent_via}" ;;
		esac
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
