## Current State

- Phase: Bootstrap complete (SSH agent with systemd socket, unified installer, fetch validation fixes).
- 2 high-priority tasks completed (setup-ssh-agent-systemd, replace-fetch-all-with-update-user-home-dir).
- New task: investigate-stow-static-alternatives (high).
- Installer in project root only (update-user-home-dir.sh); not stowed.
- ~/.local/apps/ now properly populated on clean systems (fb_check_bin fix).
- Test harness and documentation added (doc/ssh-agent.md, doc/fetch-bins.md).

## Open Threads

- `investigate-stow-static-alternatives` (high, new) -- Research static GNU Stow or Go/Rust single-binary replacement for self-contained bootstrap (dynamic linking, no sudo/dev tools). See tasks/investigate-stow-static-alternatives.md.
- Tooling Gotchas (list_dir + dotfiles/stow) -- Documented in resume and workflow; review at session start.

## Completed Plans

| Task | Iteration | File |
|------|-----------|------|
| setup-ssh-agent-systemd | current | tasks/setup-ssh-agent-systemd.md |
| replace-fetch-all-with-update-user-home-dir | current | tasks/replace-fetch-all-with-update-user-home-dir.md |

