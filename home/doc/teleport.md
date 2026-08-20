# Teleport (`tsh`): reaching hosts, and reaching browser-less ones

The cluster is `syketech.com`. `tsh` is a hard dependency of three things in this
repo: the `ProxyCommand` in `home/private_dot_ssh/private_config`, the login
helper `home/dot_local/bin/executable_tsh-login-syketech.sh`, and the fleet
scripts `update.teleport.sh` / `teleport.versions.sh`.

**The ruling, up front.** From a workstation, log in normally and reach
everything through the proxy. Anywhere else, choose by **credential exposure,
not by whether a browser exists** — `tsh login` works fine on a headless box,
because this cluster is local auth (password + TOTP, both typed, no browser
anywhere in the flow). It just leaves a 12h certificate on that machine. When
you would rather leave nothing behind, use `tsh ssh --headless` and approve in a
browser elsewhere. Everything below is why, and the traps on the way.

> **`--headless` is not "the way to use a browser-less box".** That was the
> obvious reading and it is wrong. A browser-less box can hold a full
> certificate; `--headless` is what you reach for when it *shouldn't*.

## "Headless" is three problems with three different answers

Deciding which one you are in comes first, because the answers do not transfer.

| | Situation | Answer |
|---|---|---|
| **a** | **Remote headless** — a node in a rack, you at a workstation | Reach it *through* the proxy. Never authenticate on it. |
| **b** | **Local headless** — you at a console with no GUI/browser | `tsh login` works (typed secrets, 12h cert). Prefer `tsh ssh --headless` when the box should hold **no** credential. |
| **c** | **Unattended** — cron or an agent, no human at all | Machine ID (`tbot`). Out of scope here. |

Case **a** is the common one and needs no new machinery — it is already built and
was simply undocumented. A security key does **not** help case (a): a key you
must physically touch cannot serve a machine you are not standing at.

## 1. Workstation-first (case a) — the default

`home/private_dot_ssh/private_config` already routes the cluster:

```sshconfig
Host *.syketech.com !syketech.com
    ProxyCommand "tsh" proxy ssh --cluster=syketech.com --proxy=syketech.com:443 %r@%h:%p
```

So after a normal `tsh login`, plain `ssh host.syketech.com` works, as do
`tsh ssh <node>`, `tsh scp`, and `tsh ls`. Nothing is typed on the far end and no
credential is copied anywhere. **If you are reaching for a headless login, check
first that you are not in case (a), where the answer is to stay where you are.**

> The `ProxyCommand` deliberately holds the portable `"tsh"`, not an absolute
> path. `tsh config` rewrites it to this host's `/opt/teleport/system/bin/tsh`,
> so that hunk reappears as chezmoi drift after any Teleport touch. Keep the
> portable form.

## 2. `tsh ssh --headless` (case b)

### There is no headless *login*

```console
$ tsh login --proxy=syketech.com --user=suykerbuyk --headless
ERROR: Headless login is not supported for this command.
       Only 'tsh ls', 'tsh ssh', and 'tsh scp' are supported.
```

**The confusing part is not that the flag is missing — it is that the flag is
everywhere.** `--headless` is a *global* flag: it appears in the flag list of
`tsh --help` itself, so it parses on every subcommand and is then refused at
runtime by all but those three. Seeing it in `tsh login --help` proves nothing.

Confirmed on client v18.10.4 against proxy 18.10.1, so this is not a
stale-version artifact.

**This does not mean a browser-less box cannot log in.** Plain `tsh login` works
there — verified on `qa-deb13-01`, which prompts `Enter password for Teleport
user suykerbuyk:` on the terminal and needs no browser. What does not exist is a
*headless* login: one that authenticates without you typing the secrets on that
box.

### What it does instead

`--headless` is per-command. Teleport holds the key material in memory for the
duration of that one request and writes no certificate, so it cannot be wrapped
by `tsh-login-syketech.sh` and never will be.

```console
$ tsh ssh --headless --proxy=syketech.com --user=suykerbuyk johns@qa-deb13-01 hostname
Complete headless authentication in your local web browser:

https://syketech.com:443/web/headless/<request-id>

or execute this command in your local terminal:

tsh headless approve --user=suykerbuyk --proxy=syketech.com:443 <request-id>
```

It then blocks until the request is approved or expires. Note the second option
it offers — see the trap in section 3 before believing it.

### It really does leave nothing behind

Verified on `qa-deb13-01` **after a successful session**, which is the only
version of this check worth trusting:

```console
$ find ~/.tsh -type f
~/.tsh/bin/.config.json
~/.tsh/bin/.lock

$ tsh status ; echo $?
ERROR: Not logged in.
1
```

No certificate, no key, no profile. The box is exactly as unauthenticated after
the session as before it. That is the whole point: **this is the tool for a
machine you do not want holding a credential.** The one file written is
client-tools update state, not credential material.

## 3. Approving a headless request

### The browser — the path that works

Open the printed `https://syketech.com:443/web/headless/<id>` URL on a machine
with a browser and approve. The 1Password passkey (`BD770i-1Pass`, WebAuthn)
serves the assertion. **Verified end to end.** No password is typed on the
browser-less box, no OTP is echoed there, and `op` never runs there at all.

### 🔴 The CLI path does not work without a hardware key

Teleport prints `tsh headless approve …` as an equal alternative. It is not one.
Headless authentication accepts **only** a direct WebAuthn/CTAP assertion, and
the 1Password passkey cannot provide it — not merely because `tsh` cannot see it,
but because the server rejects browser-delegated assertions *by type*.

All three advertised methods, tested against one request:

| `--mfa-mode` | What the client does | Server verdict |
|---|---|---|
| `otp` | Prompts `Enter an OTP code from a device:`, accepts it | ❌ `MFA response of type *proto.MFAAuthenticateResponse_TOTP is not supported for headless authentication` |
| `browser` | Opens a local callback for the assertion | ❌ `…MFAAuthenticateResponse_Browser is not supported…` |
| `auto` | Picks WEBAUTHN, fails with no key, falls back to BROWSER | ❌ Same Browser rejection |
| WEBAUTHN | Needs a CTAP device over libfido2 | ✅ The only accepted type |

**Teleport advertises what it will not accept.** The default run prints
`Available MFA methods [WEBAUTHN, OTP, BROWSER]` and invites you to choose with
`--mfa-mode`, then refuses two of the three. A user following the tool's own
guidance is walked into a dead end, will assume they mistyped the code, and will
retry — and retries are what trip cluster login-failure lockout.

Use the browser URL. `tsh headless approve` becomes useful only if a USB security
key is ever bought; nothing else about this document changes if one is.

### 🔴 `tsh headless approve` exits 0 when it DENIES

Its two prompts read from **different places**:

- `Approve? [y/N]:` reads **stdin**.
- `Enter an OTP code from a device:` reads **/dev/tty with echo off**, exactly
  like `tsh login`'s password prompt.

So piping `y` and a code answers the confirmation, silently fails to deliver the
second factor, causes Teleport to **deny** the login — and exits **0**. The
initiating side reports `ERROR: headless authentication denied` while the
approving side reports success.

| stdin | Outcome | `$?` |
|---|---|---|
| `/dev/null` | `failed reading prompt response: EOF`, request untouched | 1 |
| pipe `y\n<code>\n` | **Login DENIED** | **0** |
| terminal, MFA rejected by server | Request stays pending | 1 |

**Do not wrap this in a naive helper.** A rejected MFA exits 1 while a *missing*
one exits 0 — the exit code is inverted relative to the outcome that matters.
Anything that automates approval needs the pty treatment
`tsh-login-syketech.sh` already uses, for the same underlying reason.

## 4. Probing session state

```console
$ tsh status ; echo $?     # 1 when not logged in, 0 when logged in
$ tsh logout ; echo $?     # ALWAYS 0 -- "All users logged out." even with no session
```

`tsh logout` is idempotent and safe to call unconditionally, but it **cannot be
used to probe login state**. Use `tsh status`, and scope it to the proxy
(`tsh status --proxy=syketech.com`) — a bare `tsh status` exits 0 while logged in
to *any* cluster.

> **Capture `$?` before any trailing command.** `tsh status | head -6; echo $?`
> reports `head`'s status, not `tsh`'s — it prints 0 while `tsh` exited 1, which
> silently inverts the probe. Redirect instead: `tsh status >f 2>&1; echo $?`.
> This is the same hazard recorded under mutation discipline in the test suite,
> and it was re-derived the hard way against the live cluster.

Sessions last **12h** — the cluster's `default_session_ttl`, readable without
logging in:

```console
$ curl -s https://syketech.com/v1/webapi/ping | jq -r .auth.default_session_ttl
12h0m0s
```

## 5. The login helper prefers 1Password, but does not require it

`tsh-login-syketech.sh` runs anywhere. `op` is the **preferred** secret source,
never a requirement:

- With a working `op`, it drives `tsh` under a **pty** and answers both prompts
  automatically. The pty is necessary because `tsh` reads the password from
  `/dev/tty` with echo off, not from stdin — so no secret reaches a paste
  buffer, a clipboard, or argv. tmux, herdr and a bare terminal take one path.
- With `op` missing **or failing**, it says so and falls through to an ordinary
  interactive `tsh login`. Same 12h certificate; you type the two secrets that
  `op` would have supplied.

**The predicate is operability, not presence.** `command -v op` proves only that
a binary exists. The failure actually observed was an *installed* `op` returning
`error initializing client: authorization timeout` because its biometric prompt
went unanswered — and `op --help` and `op --version` both pass in exactly that
state, since neither touches the desktop integration that fails. The only honest
test of "can `op` hand over this secret" is asking it for the secret, so the
script tries and degrades rather than pre-flighting a guess.

It never substitutes `tsh ssh --headless` for a login. That would produce no
certificate, report success, and leave `ssh <host>` still broken — so the
fallback message *offers* it and the script never runs it.

> Measured on `qa-deb13-01`: `python3` and `jq` present, `op` **missing**. That
> box takes the interactive path and gets a normal certificate.

> The pty technique itself does **not** require a controlling terminal — a
> `pty.fork()` driver that relays to a log works fine in CI. The helper's
> `/dev/tty` requirement comes from *its* job of handing the terminal back to the
> human, not from `tsh`.

## 6. Rejected: shipping identity files

`tsh login --out=identity --format=file` mints a portable credential that
`tsh -i identity ssh …` can use on a box that never logs in. **Declined.** It is
a better secret than a password, but copying it to the machine is exactly the
hand-carried-credential exposure this whole approach exists to remove, and unlike
`--headless` it leaves that credential sitting on the far end.

## 7. Out of scope: unattended access (case c)

Nothing here covers a cron job or an agent that needs cluster access with no
human present. Headless authentication always requires a human to approve, so it
is not an automation path. That is Machine ID (`tbot`) territory, and it wants
cluster-side setup plus a systemd user unit before it belongs in this repo.

## Testing

Nothing here is asserted by the test suite and nothing should be. **Never drive
`tsh login` from the harness** — failed authentication attempts count toward
cluster login-failure lockout, and a test that locks the account is worse than no
test. Unauthenticated calls (`tsh version`, `/v1/webapi/ping`) are safe.

See also [`ssh-agent.md`](ssh-agent.md) for `TELEPORT_USE_LOCAL_SSH_AGENT` and
the agent-priority order, and [`fetch-bins.md`](fetch-bins.md) for how the
toolchain is installed.
