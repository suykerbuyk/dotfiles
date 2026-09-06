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

**Two layers pick the socket, and only one of them is this fragment.**
`~/.config/shell/env.sh` runs first, for *every* shell, and points at the systemd
socket when nothing was inherited. The rc fragment below runs only for
**interactive** shells. So `ssh -A host cmd` never reaches the fragment at all —
`env.sh` is the whole story there, which is why its inherited-socket guard matters
more than anything in this list.

**Agent priority (interactive shells, in order)**:
1. **An inherited, live `SSH_AUTH_SOCK`** — a forwarded agent (`ssh -A`), a
   multiplexer pane, anything the session arrived with. Probed for liveness
   (`ssh-add -l`, rc 2 means a stale inode) and kept if it answers.
   The 1Password socket and the systemd socket are exempt from this step, because
   this repo put them there rather than the session.
2. **1Password agent** (`~/.1password/agent.sock` + `op` CLI present) — sets
   `TELEPORT_USE_LOCAL_SSH_AGENT=false` automatically. Desktop-only, so
   headless/WSL/FreeBSD skip it.
3. Systemd OpenSSH socket (`$XDG_RUNTIME_DIR/openssh_agent`).
4. Keychain fallback.
5. Manual `ssh-agent` on a predictable socket.

🔴 **1Password is the DEFAULT, not an override.** It used to be step 1 and
unconditional — "this check runs first (before any guard) so it reliably wins" —
which meant any machine with the app installed silently discarded a forwarded
agent in favour of a local one that might be locked. Measured: an inherited, live
`/run/user/1000/openssh_agent` came back as `~/.1password/agent.sock`. Agent
forwarding was dismissed twice on evidence that bug produced. Do not restore the
old order; the harness asserts against it.

Competing agents (`gpg-agent-ssh.socket`, `gcr-ssh-agent.socket`) are detected with a note on desktops. Consider masking them (`systemctl --user mask gpg-agent-ssh.socket`) to eliminate conflicts with tsh and ssh-add.

## Migration from keychain

The original `keychain` block in `.zshrc` is preserved but commented with a migration note. The new fragment falls back to keychain if higher-priority agents are not present. After verification, you can remove the keychain lines.

## Testing

- `setup-ssh-agent.sh --dry-run` (now shows updated priority and competing-agent note)
- `systemctl --user status ssh-agent.socket`
- `echo $SSH_AUTH_SOCK` and `ssh-add -l` (should succeed quickly; no hangs)
- `tsh version` / `tsh ls` (no manual `TELEPORT_USE_LOCAL_SSH_AGENT=false` needed on desktops)
- Non-interactive: `bash -c 'source ~/.config/bashrc.d/10-ssh-agent.sh; echo $SSH_AUTH_SOCK'`
- Which agent did this shell actually pick, and does it answer: `./doctor` (the `agent` row names the socket, its origin, and how many identities it holds — reachability only, never a signature test, because `ssh-add -T` blocks against a locked 1Password vault)
- Forwarded-agent check: `SSH_AUTH_SOCK=/some/live/foreign.sock bash -c 'source ~/.config/bashrc.d/10-ssh-agent.sh; echo $SSH_AUTH_SOCK'` — must echo back the socket you gave it, unchanged
- Keychain migration simulation (comment keychain block and re-source).
- WSL/Arch/Debian/Pop!_OS cross-check (1Password path skipped on headless; systemd works everywhere; no breakage after reboot).

## Integration with Other Tasks

This is the foundational piece. The dependent `replace-fetch-all-with-update-user-home-dir` task can now call `setup-ssh-agent.sh` from `update-user-home-dir.sh` for full home bootstrap.

See the task file `tasks/setup-ssh-agent-systemd.md` for the full revised plan, acceptance criteria, and test matrix.

**Last updated**: 2026-07-12 (as part of `/vpc-execute-plan` phases 1-4).

This setup is idempotent, stow-safe, cross-distro, and non-breaking. It leverages the existing `_lib.sh` patterns for consistency.
