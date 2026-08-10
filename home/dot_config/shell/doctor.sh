# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# doctor.sh — interactive thin wrapper around the doctor CLI.
#
# RC layer only (sourced by rc.sh). Must never reach the env layer: the function
# name has a hyphen and dash rejects `foo-bar()` as a syntax error.
#
# The real report lives at the repo root (`./doctor` → lib/doctor-report.sh).
# After apply, ~/.local/bin/dotfiles-doctor trampolines into that script. This
# file only defines the hyphenated name so:
#   - `command -v dotfiles-doctor` succeeds in interactive shells
#   - the once-per-login greet in rc.sh can call `dotfiles-doctor`
#   - pre-apply / missing trampoline still gets a usable fallback via DF_ROOT

dotfiles-doctor() {
	# Prefer the applied PATH entry (avoids recursive function lookup).
	if [ -x "${HOME}/.local/bin/dotfiles-doctor" ]; then
		"${HOME}/.local/bin/dotfiles-doctor" "$@"
		return $?
	fi
	# Fallback: run the checkout copy when we can find it.
	if command -v chezmoi >/dev/null 2>&1; then
		_src=$(chezmoi source-path 2>/dev/null) || _src=
		if [ -n "${_src}" ] && [ -x "$(dirname "${_src}")/doctor" ]; then
			"$(dirname "${_src}")/doctor" "$@"
			return $?
		fi
	fi
	printf 'dotfiles-doctor: CLI not available — from the checkout run: ./doctor\n' >&2
	printf '  (or bootstrap: ./update-user-home-dir.sh)\n' >&2
	return 1
}

return 0 2>/dev/null || true
