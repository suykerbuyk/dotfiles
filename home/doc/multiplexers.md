# Multiplexers: tmux and herdr

This repo configures **two** terminal multiplexers and treats them as peers:

- **tmux** — the incumbent. `home/dot_tmux.conf`, the `tm` session helper, and
  `tmux-pane-log`. See also [shell.md](shell.md).
- **herdr** — an agent-oriented multiplexer/runtime (fetch.bins slot 17). Config
  at `home/dot_config/herdr/config.toml`; completions wired into the rc layer.

herdr was originally **fetched, not adopted** — installed, but referenced by
nothing. That was reversed: it is now adopted, at parity with tmux.

## The `ctrl+b` prefix is shared ON PURPOSE

Both use `ctrl+b`. This looks like a bug and is not one.

The two are **never nested**. Running herdr *inside* tmux would make the outer
session eat every prefix keystroke — but that is a usage error, not a
configuration one. What sharing the prefix buys is that switching between the
two costs nothing: the same keys do the same things. Maximising the number of
shared meta-keys is the entire design goal, so a *collision* here is the
intended outcome rather than a tolerated cost.

Do not "fix" this by giving herdr a different prefix.

## Parity is additive

Every rebound action in `config.toml` lists the **tmux key first** and keeps
**herdr's own default** as a second binding:

```toml
cycle_pane_next = ["prefix+space", "prefix+tab"]
```

Two reasons, and the second is the load-bearing one:

1. No herdr muscle memory is destroyed by adopting tmux's keys.
2. herdr's docs warn that punctuation-with-modifiers — `%` is shift+5, `"` is
   shift+' — "may depend on your terminal/tmux setup". Config validation cannot
   detect a key the *terminal* fails to deliver. With an array, such an action
   degrades to herdr's native key instead of becoming unreachable.

### The one exception: `detach`

`detach = "prefix+d"` is the single rebind that **drops** herdr's native key
rather than keeping it. Both reasons above fail to apply here:

1. Keeping `prefix+q` meant `ctrl+b q` **detached the client**, while the same
   chord in tmux is `display-panes` — a harmless pane picker. Muscle memory was
   not being preserved by the fallback; it was being punished by it, on a key
   reached for by reflex. That is the exact failure the shared prefix exists to
   prevent.
2. The delivery hedge is irrelevant: `prefix+d` is a plain unmodified letter,
   not punctuation-with-modifiers. There is nothing for the array to hedge.

So `ctrl+b d` detaches **both** multiplexers, and `prefix+q` is freed for
`goto` (see below). Do not "restore" the herdr fallback here — a test asserts
its absence specifically, because re-adding it silently reinstates the old
behaviour.

## Binding table

Actions where herdr's default already matched tmux are pinned explicitly in
`config.toml` anyway, so that a silent upstream default change produces a diff
rather than a quiet desync.

| Action | tmux | herdr | Status |
|---|---|---|---|
| prefix | `C-b` | `ctrl+b` | already matched, pinned |
| focus pane L/D/U/R | `prefix h/j/k/l` | `prefix+h/j/k/l` | already matched, pinned |
| cycle pane | `prefix space` | `prefix+tab` | **rebound** → `["prefix+space", "prefix+tab"]` |
| last pane | `prefix ;` | *(shipped unset)* | **filled in** → `last_pane = "prefix+;"`, see below |
| split side-by-side | `prefix %` | `prefix+v` | **rebound** → `split_vertical` |
| split stacked | `prefix "` | `prefix+minus` | **rebound** → `split_horizontal` |
| close pane | `prefix x` | `prefix+x` | already matched |
| zoom | `prefix z` | `prefix+z` | already matched |
| new tab/window | `prefix c` | `prefix+c` | already matched |
| next / prev | `prefix n` / `p` | `prefix+n` / `prefix+p` | already matched |
| select 1..9 | `prefix 1..9` | `prefix+1..9` | already matched |
| rename tab/window | `prefix ,` | `prefix+shift+t` | **rebound** |
| close tab/window | `prefix &` | `prefix+shift+x` | **rebound** |
| detach | `prefix d` | `prefix+q` | **rebound**, and the sole *non-additive* one — see above |
| display-panes | `prefix q` | *(none)* | **approximated** → `goto` = `["prefix+q", "prefix+g"]`, see below |
| copy-mode / scrollback | `prefix [` | `prefix+e` | **rebound** to `edit_scrollback`; a real `copy_mode` exists and is unruled — see below |
| help / list-keys | `prefix ?` | `prefix+?` | already matched |
| picker | `prefix w` | `prefix+w` | already matched |

### Splits: the convention is PROVISIONAL

**The split convention is not decided.** Which keys mean side-by-side vs stacked
— across tmux *and* herdr — is still under evaluation, to be settled by running
with it rather than by argument. The bindings in `config.toml` are a starting
point, not a ruling.

The test suite therefore **does not pin the mapping**. It asserts only what
holds under any convention: both split actions exist, each keeps its herdr
native key as a fallback, and the two never collide on one key. Swap the two
lines freely — the suite stays green. Pinning the mapping would have put
friction on exactly the thing being evaluated.

Iterating costs nothing; neither tool needs a restart:

```sh
# herdr
prefix+shift+r          # or: herdr server reload-config
# tmux
prefix : source-file ~/.tmux.conf
```

### The inversion, which is true whichever convention wins

- **herdr names the divider.** `split_vertical` draws a *vertical divider*, so
  panes end up **side by side**.
- **tmux names the axis.** `split-window -h`, bound to `%`, also produces
  **side-by-side** panes.

So matching tmux's `%` means binding herdr's `split_vertical`, and tmux's `"`
(`split-window -v`, stacked) means `split_horizontal`. The words are opposite;
the resulting layouts are the same. If a split ever goes the wrong way, this is
why. herdr's own API is unambiguous where the config is not —
`herdr pane split --direction <right|down>`.

Once the convention is settled, record it here and in `config.toml`, and — if
tmux's side needs rebinding too — in `dot_tmux.conf`, which currently leaves
splits at tmux's defaults (`%` and `"`).

## tmux's `prefix q` (display-panes) is approximated by `goto`

In tmux, `prefix q` overlays a number on every visible pane and focuses the one
you type. **herdr 0.8.0 has no equivalent action.** That is verified, not
inferred — herdr's own validator rejects both plausible spellings while
accepting every real action in the same file:

```
$ herdr config check
unknown config key keys.display_panes; ignoring key
unknown config key keys.select_pane_by_number; ignoring key
```

`goto` — herdr's modal **NAVIGATE** mode — is the nearest analogue, so
`prefix+q` is aliased to it and herdr's native `prefix+g` is kept alongside.
NAVIGATE reserves `1..9` for selection (the default config forbids binding those
digits as navigate-mode movement keys), which is what makes it the right
approximation rather than an arbitrary landing spot.

### Why a *true* numbered overlay was not built

It is possible but disproportionate, and half of it is blocked:

- The socket API **does** support focus-by-id — `pane.focus` takes
  `{"pane_id": string}`, and `pane.layout` returns per-pane rects.
- The **CLI does not expose it**. `herdr pane focus` requires
  `--direction <left|right|up|down>`; its `--pane` flag names the *source* pane.
  So a `[[keys.command]]` would have to speak raw JSON to `$HERDR_SOCKET_PATH`.
- A `type = "popup"` command is **session-modal** and cannot paint digits over
  the other panes. The result would be a numbered *list*, not tmux's overlay.

A faithful overlay needs a herdr **plugin** (`herdr plugin`, which exposes
`plugin.pane.focus`). If that is ever wanted, that is the route — not a custom
command.

## Undecided: `copy_mode` turns out to exist

The binding table's copy-mode row reflects the original reading that herdr had
no copy-mode and only an "open the scrollback in `$EDITOR`" action. **That is
wrong for 0.8.0.** `copy_mode` is a real, bindable action — it passes
`herdr config check` — and the binary carries a full vi-style mode:

```
COPY   h/j/k/l w/b/e { } move   / ? search   n/N   v/space select   y/enter copy   q/esc exit
```

which is close to tmux's copy-mode. `swap_pane_left/down/up/right` are likewise
real but absent from `herdr --default-config`.

`last_pane` and `cycle_pane_previous` were originally recorded here as absent
too. **That was wrong** — both appear in `herdr --default-config`, commented
out, `last_pane` explicitly as `""  # optional, unset by default`. They are not
hidden actions; they are documented ones herdr declines to bind. `last_pane` has
since been bound (see below); `cycle_pane_previous` remains unbound, and its
native `prefix+shift+tab` is available if a tmux counterpart is ever wanted.

## `last_pane` fills tmux's `prefix ;`

tmux's `prefix ;` jumps back to the previously active pane with no direction key
and no cycling. herdr has the identical action and ships it **unset**, so the
binding fills a gap rather than overriding a native default — which is why it is
a scalar with no fallback, unlike every additive rebind in the table.

herdr's own comment suggests `prefix+tab` for it. That is deliberately declined:
`prefix+tab` is already `cycle_pane_next`'s fallback, and the suite asserts the
two never collide.

Two facts worth keeping:

- **The tmux side is a stock default.** `dot_tmux.conf` never binds `;`, so the
  pairing exists only in `config.toml` and this table.
- **`herdr config check` validates chords, not just key names.** A bogus
  `prefix+NOT_A_REAL_KEY_ZZZ` is rejected with `invalid keybinding: … disabling
  binding` — so a passing check confirms the chord is recognised. Note the
  failure mode: an invalid binding is silently **disabled**, not fatal, so a
  typo costs the key rather than announcing itself.
- **Scope differs, and that is RULED acceptable (2026-08-11).** herdr calls
  `last_pane` "global back-and-forth"; tmux's `last-pane` is window-scoped.
  Whether herdr's actually crosses tabs/workspaces is still unconfirmed — it
  needs a keypress in a live session. The human has ruled it does not matter:
  a global jump beats having no shortcut. This is a closed question. If the
  scope proves global, that is the accepted outcome, not a defect to fix.

**No ruling has been made**, so `config.toml` still binds `prefix+[` to
`edit_scrollback` and nothing here is asserted by the suite. Recorded so the
gap is not rediscovered from scratch.

## Three tmux actions have no herdr equivalent

These are **accepted gaps**, not oversights. Nothing in `config.toml` tries to
approximate them, and no workaround is pretended:

| tmux | Binding | Why herdr cannot match it |
|---|---|---|
| pane logging | `prefix C-h` → `tmux-pane-log` | herdr has no `pipe-pane`. A `[[keys.command]]` popup could run *something*, but not a live tee of pane output with dedup and rotation. |
| direct resize | `prefix H/J/K/L` (repeatable) | herdr resizes through a **modal** `prefix+r` mode. A different paradigm, not a rebind. |
| mouse toggle | `prefix m` | herdr's `mouse_capture` is a config value with no bindable action, so it cannot be flipped at runtime. |

If you need any of these mid-task, that is a reason to be in tmux for that task.

## Validate every config edit

```sh
herdr config check
```

It reports `invalid keybinding: keys.<action> = "…"; disabling binding` for an
unknown key, and `unknown config key keys.<action>; ignoring key` for a
misspelled action — **including inside the arrays**. Both failures are otherwise
silent: herdr starts fine and the binding simply never fires. The test harness
runs this check against the managed file when herdr is installed.

Note what the check does **not** cover: it validates syntax, not whether your
terminal actually delivers the chord. That is what the additive arrays are for.

## Only ONE file in `~/.config/herdr/` is managed

`~/.config/herdr/` is **not** a config directory. Alongside `config.toml` it
holds live runtime state:

```
config.toml          <- the only managed file
herdr.sock           <- live server socket
herdr-client.sock    <- live client socket
session.json         <- live session/workspace state
herdr-server.log     herdr-client.log
.plugins.lock
```

So the chezmoi source directory is `home/dot_config/herdr/` containing exactly
one entry, and it must **never** be renamed to `exact_herdr`: the `exact_`
attribute makes chezmoi delete unmanaged entries in that directory, which here
would mean deleting live sockets and session state out from under a running
server. A test asserts the `exact_` prefix is absent.

This is the same class of trap as broot's launcher directory
([shell.md](shell.md)): a tool whose config path doubles as its runtime path.

## herdr CLI commands reach the RUNNING server

`herdr pane …`, `herdr workspace …` and the rest of the socket API talk to the
live server, and they find it **regardless of `$HOME`/`$XDG_CONFIG_HOME`**. A
sandboxed `HOME` does *not* isolate them; a `herdr pane split` run "in a
sandbox" from inside a herdr pane splits a real pane in the real session.

Only `herdr config check` and `herdr --default-config` are safely sandboxable,
because they read files rather than the socket. Nesting is refused outright
(`nested herdr is disabled by default`), which is what makes an accidental
sandbox launch harmless.
