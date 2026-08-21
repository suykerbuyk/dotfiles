# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# doctor-registry.sh — single source of truth for tool health rows.
#
# Each row:  <command>|<fetch.bins stem>|<note>
# Stem is the name inside fetch.bins/NN_fetch.<stem>.sh (or executable_NN_…).
#
# The STEM alone decides provisioning: empty stem = not provisioned by this
# repo. The note is free-form context and says nothing about provisioning —
# a provisioned row may carry one, and the reporter shows it on the MISS line.
# (lib/doctor-report.sh used to key "not provisioned" on a non-empty note,
# which silently disowned every provisioned row that wanted an explanation.)
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
		'delta|delta| git pager; also wires five global git config keys' \
		'xh|xh|' \
		'tsh|tsh| Teleport client; the fetcher DEFERS when a system-wide tsh exists' \
		'zed|zed|' \
		'ghostty|ghostty| community AppImage; upstream ships Linux via distros' \
		'chezmoi|chezmoi|' \
		'tv|| not provisioned by fetch.bins' \
		'keychain|| superseded by ~/.config/bashrc.d/10-ssh-agent.sh'
}
