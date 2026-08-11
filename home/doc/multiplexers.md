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

## Binding table

Actions where herdr's default already matched tmux are pinned explicitly in
`config.toml` anyway, so that a silent upstream default change produces a diff
rather than a quiet desync.

| Action | tmux | herdr | Status |
|---|---|---|---|
| prefix | `C-b` | `ctrl+b` | already matched, pinned |
| focus pane L/D/U/R | `prefix h/j/k/l` | `prefix+h/j/k/l` | already matched, pinned |
| cycle pane | `prefix space` | `prefix+tab` | **rebound** → `["prefix+space", "prefix+tab"]` |
| split side-by-side | `prefix %` | `prefix+v` | **rebound** → `split_vertical` |
| split stacked | `prefix "` | `prefix+minus` | **rebound** → `split_horizontal` |
| close pane | `prefix x` | `prefix+x` | already matched |
| zoom | `prefix z` | `prefix+z` | already matched |
| new tab/window | `prefix c` | `prefix+c` | already matched |
| next / prev | `prefix n` / `p` | `prefix+n` / `prefix+p` | already matched |
| select 1..9 | `prefix 1..9` | `prefix+1..9` | already matched |
| rename tab/window | `prefix ,` | `prefix+shift+t` | **rebound** |
| close tab/window | `prefix &` | `prefix+shift+x` | **rebound** |
| detach | `prefix d` | `prefix+q` | **rebound** |
| copy-mode / scrollback | `prefix [` | `prefix+e` | **rebound** (different model, see below) |
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
