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
