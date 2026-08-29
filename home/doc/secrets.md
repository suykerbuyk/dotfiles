# Secrets (`~/.keys`) — age-encrypted, public-repo-safe

API keys and tokens live in `~/.keys`, which the interactive shell sources
(`common.sh`). This repo is public, so `~/.keys` is **never** committed in the
clear: it is stored as an **age-encrypted** blob and decrypted on `chezmoi
apply`. The one irreducible secret — the age identity that decrypts it — lives
only on your machines and in 1Password, never in the repo.

## The one command you need

From the checkout root (preferred when you are already there):

```
./keys            # edit ~/.keys (decrypted), re-encrypt + apply on save
./keys status     # is the age key present? is ~/.keys decrypted?
./keys show       # list variable NAMES only (never values)
./keys get-key    # restore the age identity from 1Password
```

After apply, the same CLI is on `PATH` as `dotfiles-keys` (a trampoline into
`./keys`), so it works from any directory:

```
dotfiles-keys status
```

After `./keys` / `dotfiles-keys` edits a key, commit & push the repo — it prints
the exact command. That is the whole day-to-day workflow; you never call
`chezmoi` or `age` directly.

## How it fits together

| Piece | Where | Secret? |
|---|---|---|
| Encrypted secrets | `home/encrypted_private_dot_keys.age` (in the repo) | No — ciphertext, safe to publish |
| Decrypted secrets | `~/.keys` (mode `0600`, sourced by the shell) | Yes — local only, never committed |
| age **recipient** (public key) | `chezmoi.toml.template` → `~/.config/chezmoi/chezmoi.toml` | No — public, safe to commit |
| age **identity** (private key) | `~/.config/chezmoi/key.txt` (mode `0600`) + 1Password doc `dotfiles age key` | **Yes — never in the repo** (gitignored) |

`chezmoi.toml` also sets `encryption = "age"` and `sourceDir` (so bare `chezmoi`
and `dotfiles-keys` find the repo). The installer renders it from the committed
template, substituting your `$HOME` and the checkout path.

## Fresh machine

1. **Get the age identity onto the box** — the installer does this automatically
   from 1Password when `op` can talk to the desktop app. The `op` binary is
   fetched by `./update-user-home-dir.sh` (slot 23) only when a system
   `1password-cli` package is not already on PATH; a distro `op` is preferred
   because it is already setgid `onepassword-cli`. Otherwise, place the age
   key by hand:
   ```
   op document get 'dotfiles age key' --vault Personal --out-file ~/.config/chezmoi/key.txt
   chmod 600 ~/.config/chezmoi/key.txt
   ```
   (or paste it from the 1Password app).

   After installation, enable **Settings > Developer > Integrate with
   1Password CLI** in the 1Password app. On Linux the CLI must also be
   **setgid `onepassword-cli`** — the app resets `1Password-BrowserSupport.sock`
   otherwise (`connecting to desktop app: read: connection reset`). Slot 23
   prints these if they are still needed; a re-fetch strips setgid:

   ```
   sudo chgrp onepassword-cli ~/.local/apps/op
   sudo chmod g+s ~/.local/apps/op
   op whoami
   ```

   `OP_SECRET_KEY` in `~/.keys` is for `op account add` on a box without the
   desktop app.
2. `git pull` (or clone) and run `./update-user-home-dir.sh`.

That's it — `~/.keys` materializes at `0600`. A machine **without** the key still
installs everything else cleanly: `.chezmoiignore` drops `.keys` when
`~/.config/chezmoi/key.txt` is absent, so nothing fails; you just have no secrets
until the key lands.

## Why age (and not gpg)

age is a single static binary (`FiloSottile/age`) with no keyring, no agent, no
config — a keypair is just two short strings. chezmoi speaks it natively. It is
fetched as a **bootstrap tool** (Phase 3 of the installer), *before* `chezmoi
apply`, because apply invokes `age` to decrypt.

## Adding or rotating keys

- **Add/change a value:** `./keys` (or `dotfiles-keys`), edit, save, then commit & push.
- **Rotate the age key** (compromise, or periodic hygiene):
  1. `age-keygen -o ~/.config/chezmoi/key.txt.new` → note the new `age1…` recipient.
  2. Update `recipient` in `chezmoi.toml.template` and re-render the config.
  3. `chezmoi re-add` / re-encrypt `~/.keys` to the new recipient.
  4. Replace `~/.config/chezmoi/key.txt`, update the 1Password document, and
     distribute to your other machines.
  5. Commit the re-encrypted blob + new recipient; push.

## Threat model (honest)

The age encryption protects the secrets **in the public repo** — that is its job,
and it does it completely. It does **not** protect the *local* machine: the
decrypted `~/.keys` (and the `key.txt` identity) sit on disk at `0600`, so on a
machine without full-disk encryption a stolen/offline drive exposes them — but
that was already true of `~/.keys` before any of this. Closing that gap is
full-disk encryption, a separate measure. See the deferred-hardening notes.
