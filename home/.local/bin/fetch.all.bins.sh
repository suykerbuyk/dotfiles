#!/usr/bin/env bash

# Uses the refactored fetch.bins/ scripts (each sources _lib.sh).
# The TODO about sourcing vs calling has been retired per user instruction.
# Run from $HOME (after `stow -R .` from ~/dotfiles) to satisfy the safety guard.

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed 's/x86_64/amd64/ ; s/aarch64/arm64/')" # Normalize arch for jq naming

SCRIPT_DIR="$(dirname $(realpath $0))"

if [[ $OS =~ "bsd" ]] ; then
	echo "Running on a BSD"
	sudo pkg install jq ripgrep broot neovim
	fetch.bins/02_fetch.nvm.sh ; fetch.bins/04_fetch.go.sh ; fetch.bins/06_fetch.fzf.sh
	exit
fi
for F in $(find ${SCRIPT_DIR}/fetch.bins/ -type f -executable | sort); do
    echo $F
    $F
done
