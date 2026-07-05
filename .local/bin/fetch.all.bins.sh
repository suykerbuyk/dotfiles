#!/usr/bin/env bash

# TODO: We should be sourcing the individual fetch scripts rather than calling them.
# Each of the unique vars to an install script should only override an environmental var if it is not set

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
