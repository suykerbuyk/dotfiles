# SSH Agent Setup (systemd Socket Activation)

This document describes the preferred SSH agent setup for this dotfiles project. It replaces/supplements the previous `keychain` approach with a modern, systemd user unit based solution (socket activation).

## Components (all in `home/` stow package)

- `home/.config/systemd/user/ssh-agent.service` (existing, updated from host)
- `home/.config/systemd/user/ssh-agent.socket` (new, standard template with `ExecStartPost` for `SSH_AUTH_SOCK`)
- `home/.config/bashrc.d/10-ssh-agent.sh` (new fragment — guarded, idempotent, prefers systemd socket, falls back to keychain or manual `ssh-agent`)
- `home/.local/bin/setup-ssh-agent.sh` (new standalone script with `--dry-run`, idempotent `systemctl`, status reporting, migration notes)
- Updates to `home/.zshrc`, `home/.bashrc-arch`, `home/.bashrc-debian` (safe sourcing of `bashrc.d/*.sh` after interactive checks; keychain block conditionalized with migration note)

## Usage

After stowing (`stow -d ~/dotfiles -t ~ home`):

```bash
setup-ssh-agent.sh          # full setup (enable socket, create dirs, print status)
setup-ssh-agent.sh --dry-run # preview only
setup-ssh-agent.sh --help   # usage
```

The fragment is automatically sourced by the rc files on shell startup.

**Agent priority (final detection order)**:
1. **1Password agent** (`~/.1password/agent.sock` + `op` CLI present) — sets `TELEPORT_USE_LOCAL_SSH_AGENT=false` automatically. Only activated on desktops where both exist (no impact on headless/WSL/servers). **This check now runs first** (before any guard) so it reliably wins on machines like this Pop!_OS laptop.
2. Systemd OpenSSH socket (`$XDG_RUNTIME_DIR/openssh_agent`).
3. Keychain fallback.
4. Manual `ssh-agent`.

Competing agents (`gpg-agent-ssh.socket`, `gcr-ssh-agent.socket`) are detected with a note on desktops. Consider masking them (`systemctl --user mask gpg-agent-ssh.socket`) to eliminate conflicts with tsh and ssh-add.

## Migration from keychain

The original `keychain` block in `.zshrc` is preserved but commented with a migration note. The new fragment falls back to keychain if higher-priority agents are not present. After verification, you can remove the keychain lines.

## Testing

- `setup-ssh-agent.sh --dry-run` (now shows updated priority and competing-agent note)
- `systemctl --user status ssh-agent.socket`
- `echo $SSH_AUTH_SOCK` and `ssh-add -l` (should succeed quickly; no hangs)
- `tsh version` / `tsh ls` (no manual `TELEPORT_USE_LOCAL_SSH_AGENT=false` needed on desktops)
- Non-interactive: `bash -c 'source ~/.config/bashrc.d/10-ssh-agent.sh; echo $SSH_AUTH_SOCK'`
- 1Password detection test: `ls -l ~/.1password/agent.sock && command -v op` (should prefer it + set Teleport var)
- Keychain migration simulation (comment keychain block and re-source).
- WSL/Arch/Debian/Pop!_OS cross-check (1Password path skipped on headless; systemd works everywhere; no breakage after reboot).

## Integration with Other Tasks

This is the foundational piece. The dependent `replace-fetch-all-with-update-user-home-dir` task can now call `setup-ssh-agent.sh` from `update-user-home-dir.sh` for full home bootstrap.

See the task file `tasks/setup-ssh-agent-systemd.md` for the full revised plan, acceptance criteria, and test matrix.

**Last updated**: 2026-07-12 (as part of `/vpc-execute-plan` phases 1-4).

This setup is idempotent, stow-safe, cross-distro, and non-breaking. It leverages the existing `_lib.sh` patterns for consistency.
