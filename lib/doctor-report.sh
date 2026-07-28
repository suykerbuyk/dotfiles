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
		if df_have "${_cmd}"; then
			printf '  %-9s %-5s %s\n' "${_cmd}" 'ok' "$(command -v "${_cmd}")"
		elif [ -n "${_note}" ]; then
			printf '  %-9s %-5s %s\n' "${_cmd}" 'n/a' "${_note}"
		elif _inst=$(df_doctor_installer_for "${_stem}"); then
			printf '  %-9s %-5s → run %s\n' "${_cmd}" 'MISS' "${_inst}"
		else
			printf '  %-9s %-5s (no installer in %s)\n' "${_cmd}" 'MISS' "${_fb_hint}"
		fi
	done

	# broot: binary alone is not enough — need the per-shell `br` launcher.
	if df_have broot && [ ! -r "${HOME}/.config/broot/launcher/${_shell}/br" ]; then
		printf '  %-9s %-5s binary present, but the `br` shim is missing → run: broot --install\n' 'broot' 'note'
	fi

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

	# Secrets triad (see ./keys or dotfiles-keys).
	if [ -r "${HOME}/.keys" ]; then
		printf '  %-9s %-5s %s\n' 'keys' 'ok' \
			"${HOME}/.keys (mode $(stat -c %a "${HOME}/.keys" 2>/dev/null), $(grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "${HOME}/.keys" 2>/dev/null || echo 0) entries) — edit: keys / dotfiles-keys"
	elif [ -r "${HOME}/.config/chezmoi/key.txt" ]; then
		printf '  %-9s %-5s %s\n' 'keys' 'MISS' 'age key present but ~/.keys not applied — run: ./keys status'
	else
		printf '  %-9s %-5s %s\n' 'keys' 'n/a' 'no age identity — restore it: ./keys get-key'
	fi

	return 0
}
