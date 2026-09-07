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

## Getting a key when there is no 1Password GUI

Two mechanisms, split by **direction of travel**, not by machine. They are not
alternatives — you need both, because they serve opposite cases.

**From a desktop that HAS the 1Password app → forward the agent.** The remote
box uses this machine's agent, so every signature raises an approval prompt on
the desktop where you already are. Nothing is copied anywhere; the key never
leaves the app. Enabled **per host** in `~/.ssh/config` — `vault01` today — and
never in `Host *`, because root on the forwarded-to host can use the socket for
the life of the session. For multi-hop use `ProxyJump`, never a chain of
`ForwardAgent yes`: under ProxyJump the intermediate host carries a tunnelled
connection and never sees the agent socket.

**From a box with NO local agent worth forwarding (WSL) → `ssh-load-keys.sh`.**
Forwarding cannot help there — there is no local 1Password agent to forward — so
the keys come from `op` instead:

```
op read "op://Personal/<item-UUID>/private key?ssh-format=openssh" | ssh-add -t <ttl> -
```

Key material goes vault → stdout → pipe → agent memory: never disk, never argv,
never the environment. Notes that cost real debugging time:

- `?ssh-format=openssh` is **mandatory**. The default is whatever format the key
  was *stored* in, and 5 of the 13 items in this vault return PKCS#1 or PKCS#8,
  which `ssh-add` rejects as `invalid format`.
- Address items by **UUID**. Two items are both titled `SSH Key bd770i`, and a
  title-addressed read exits 1 with a disambiguation list.
- Read **op's** exit status, not just `ssh-add`'s. On an expired session op fails
  while `ssh-add` reports `invalid format` against an empty stream — which is the
  misdiagnosis this whole area started from.
- `op whoami` is **not** a liveness probe: in 2.39.0 it reports
  `account is not signed in` while `op read` succeeds in the same second.
- The manifest (`~/.config/shell/ssh-keys.manifest`) is **host-local and
  unmanaged**, like `env.d`. A laptop needs different keys than a workstation,
  and this repo is public — a committed manifest would publish which vault items
  hold which keys.
- Auth is manual `op signin`, which works with no desktop app. A 1Password
  **service account cannot read a Personal or Private vault**, so it is not an
  option here; that route needs the keys moved to a shared vault first.

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
- Agent forwarding resolves per host: `ssh -G <host> | grep forwardagent`
- Keys loadable without a GUI: `ssh-load-keys.sh --list`, then `ssh-load-keys.sh`
- Forwarded-agent check: `SSH_AUTH_SOCK=/some/live/foreign.sock bash -c 'source ~/.config/bashrc.d/10-ssh-agent.sh; echo $SSH_AUTH_SOCK'` — must echo back the socket you gave it, unchanged
- Keychain migration simulation (comment keychain block and re-source).
- WSL/Arch/Debian/Pop!_OS cross-check (1Password path skipped on headless; systemd works everywhere; no breakage after reboot).

## Integration with Other Tasks

This is the foundational piece. The dependent `replace-fetch-all-with-update-user-home-dir` task can now call `setup-ssh-agent.sh` from `update-user-home-dir.sh` for full home bootstrap.

See the task file `tasks/setup-ssh-agent-systemd.md` for the full revised plan, acceptance criteria, and test matrix.

**Last updated**: 2026-07-12 (as part of `/vpc-execute-plan` phases 1-4).

This setup is idempotent, stow-safe, cross-distro, and non-breaking. It leverages the existing `_lib.sh` patterns for consistency.
