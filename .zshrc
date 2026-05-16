which starship 2>&1 >/dev/null && eval "$(starship init zsh)"
HISTFILE=~/.history
HISTSIZE=10000
SAVEHIST=50000

setopt inc_append_history

#. "$HOME/.asdf/asdf.sh"

# append completions to fpath
#fpath=(${ASDF_DIR}/completions $fpath)
# initialise completions with ZSH's compinit
#autoload -Uz compinit && compini
set -o vi
export XZ_OPT="-9 -T0"

#Set VimKey bindings:
bindkey -v
plugins=(vimode)

VIM="$(whence -p nvim || whence -p vim || whence vi)"
export EDITOR="${VIM}"
export VISUAL="${VIM}"
export SUDO_EDITOR="$EDITOR"
unset VIM
export GOPATH=$HOME/code/go
[ ! -d ${GOPATH} ] && mkdir -p "${GOPATH}/bin"
export PATH="${GOPATH}/bin:$PATH"
export CLAUDE_VAULT=~/obsidian/ObsMeetings

[ -s "$HOME/.keys" ] && source $HOME/.keys \
	|| echo - " no local .keys file found."
[ -d "${HOME}/.local/bin" ] && export PATH="${HOME}/.local/bin:$PATH" \
	|| echo "Users ~/.local/bin directory does not exists"
[ -s "${HOME}/.local/bin/go" ] \
	|| echo " - go does not appear to be locally installed." 
[ -s "${HOME}/.cargo/bin/cargo" ] && source "$HOME/.cargo/env" \
	|| echo " - rust does not appear to be locally installed."
[ -s ${HOME}/.config/broot/launcher/bash/br ] && source ${HOME}/.config/broot/launcher/bash/br \
	|| echo " - broot is not installed locally."

whence -cp fzf 2>&1 >/dev/null && source <(fzf --zsh) \
	|| echo "fzf is not installed"
# https://wiki.archlinux.org/title/SSH_keys
whence -cp keychain 2>&1 >/dev/null \
	&& eval $(keychain --eval --quiet id_ed25519 ) \
	|| echo "keychain not installed"

# Setup 'tv' shell helpers and completion if tv is installed
whence -cp tv 2>&1 >/dev/null && eval $(tv init zsh) || echo "tv not installed" 
#
# If installed locally, add nvm to user path.
NVM_INSTALL="$HOME/.local/apps/nvm"
if [ -d "$NVM_INSTALL" ] ; then
	export NVM_DIR="$NVM_INSTALL"
	[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
	[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
else
	echo "nvm node version manager is not installed."
	echo "https://github.com/nvm-sh/nvm?tab=readme-ov-file#install--update-script"
fi

# If installed, add ROCM to the path and export the environmental variable for its install path
ROCM_INSTALL="/opt/rocm/"
if [ -d "${ROCM_INSTALL}/bin" ] ; then
	export ROCM_PATH="${ROCM_INSTALL}"
	export PATH="${ROCM_PATH}/bin:${PATH}"
	echo "ROCM added to path"
else
	echo "ROCM is not installed"
fi
