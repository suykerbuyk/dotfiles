# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# doctor-registry.sh — single source of truth for tool health rows.
#
# Each row:  <command>|<fetch.bins stem>|<note>
# Stem is the name inside fetch.bins/NN_fetch.<stem>.sh (or executable_NN_…).
# Empty stem + note = not provisioned by this repo.
#
# Sourced by ./doctor and (indirectly) by the interactive greet path.

df_doctor_registry() {
	printf '%s\n' \
		'starship|starship|' \
		'fzf|fzf|' \
		'broot|broot|' \
		'nvim|nvim|' \
		'rg|ripgrep|' \
		'jq|jq|' \
		'go|go|' \
		'cargo|rust|' \
		'ninja|ninja|' \
		'podman|podman|' \
		'tree-sitter|tree-sitter| parser CLI for nvim-treesitter' \
		'herdr|herdr| agent-oriented multiplexer; adopted at parity with tmux' \
		'fd|fd|' \
		'bat|bat|' \
		'delta|delta|' \
		'xh|xh|' \
		'zed|zed|' \
		'ghostty|ghostty| community AppImage; upstream ships Linux via distros' \
		'chezmoi|chezmoi|' \
		'tv|| not provisioned by fetch.bins' \
		'keychain|| superseded by ~/.config/bashrc.d/10-ssh-agent.sh'
}
