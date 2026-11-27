# Neorex

[![CI](https://github.com/justusperillieux/neorex/actions/workflows/ci.yml/badge.svg)](https://github.com/justusperillieux/neorex/actions/workflows/ci.yml)

<p><img src="assets/neorex-logo-mascot.png" alt="Neorex — a Rex dinosaur holding the Neovim emblem on Rex's colorful gradient background" width="320"></p>

**Neovim beside your agents.**

A pure Lua Neovim workspace for [Rex](https://www.superlogical.com/rex). Keep a
persistent editor in each Rex tab, find files your agents touched, leave review
comments, and preview documents inside Neovim. Use your existing Neovim setup,
with optional colors from Rex's terminal theme.

Rex manages the pane; native Neovim handles editing, rendering and input. The
editor starts without an extra tree panel. All plugin code lives in one checkout,
with no custom executable or LuaRocks requirement.

## Requirements

- macOS or Linux. The complete Rex workflow has been live-tested on macOS.
- Rex on your `PATH`, with `rex.exec`, `rex.json`, Lua actions and native pane
  APIs. Tested with control API revision 19.
- Neovim 0.12 or later.
- Git for repository navigation and change discovery.

Install Neorex and Neovim on the machine running the Rex server. Use the same
`HOME`, `XDG_DATA_HOME` and `XDG_CONFIG_HOME` values as that server.

## Installation

### With Plugin Rex (recommended)

[Plugin Rex](https://github.com/justusperillieux/plugin-rex) installs the plugin,
loads its configuration and keeps its Git revision in your lockfile.

**1. Install the manager.** If you do not have Plugin Rex yet, follow its
[quick start](https://github.com/justusperillieux/plugin-rex#quick-start).
Its bootstrap creates the plugin list and loader for your Rex configuration.

**2. Add Neorex to your plugin list.** With the bootstrap defaults, edit
`~/.config/rex/plugin-rex-plugins.lua`. Keep your other plugins and add the Neorex
entry to the returned table:

```lua
return {
  -- Your other plugins...
  {
    "justusperillieux/neorex",
    opts = {},
  },
}
```

`opts = {}` calls Neorex's `setup` function with its defaults. To use Rex's
colors, set `opts = { apply_rex_theme = true }`. Keep Neorex eager, since Rex
requires its actions and shortcuts to be declared while the configuration loads.

If you configure Plugin Rex directly in `init.lua`, add the same entry to its
existing `setup` call. Remove any previous direct Neorex loader so the plugin is
configured once. An old `neorex.lua` module in the Rex config directory can take
precedence over the managed checkout; remove an obsolete copy or link when
switching installation methods.

**3. Check and reload.**

```sh
rex config check && rex config reload
```

Plugin Rex installs missing checkouts while the configuration loads, including
during `rex config check`. Open Rex's command palette and look for **Neorex**.
Use Plugin Rex's update and restore actions to manage the installed revision.

### Without Plugin Rex

**1. Clone the plugin.**

```sh
git clone https://github.com/justusperillieux/neorex.git \
  "${XDG_DATA_HOME:-$HOME/.local/share}/rex/neorex"
```

**2. Load it from your existing Rex `init.lua`.** With default paths, this is
`~/.config/rex/init.lua`:

```lua
local data = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
dofile(data .. "/rex/neorex/neorex.lua").setup {
  apply_rex_theme = false,
}
```

For a development checkout, use its entrypoint instead:

```lua
dofile(os.getenv("HOME") .. "/Developer/neorex/neorex.lua").setup {}
```

Use one loader. The Neovim runtime is found beside the entrypoint, so there are
no separate module copies to install.

**3. Check and reload.**

```sh
rex config check && rex config reload
```

To update this installation:

```sh
git -C "${XDG_DATA_HOME:-$HOME/.local/share}/rex/neorex" pull --ff-only
rex config check && rex config reload
```

Configuration reload updates Rex's actions. Already-running editors keep their
loaded runtime and buffers; close them normally after saving and reopen to use
an updated Neovim runtime.

## Use Neorex

| Shortcut | Action |
| --- | --- |
| Cmd-E | Hide or show this tab's editor |
| Cmd-O | Recent agent references and Git changes |
| Shift-Cmd-E | Open the optional file tree and reveal the current file |

Existing bindings are preserved. Rex's command palette offers these actions too,
and the CLI can invoke them directly:

```sh
rex do neorex_toggle
rex do neorex_open file=neorex.lua:42:5
rex do neorex_preview
rex do neorex_status --json
```

The pane is titled **Neorex · project**. Hiding preserves the same Neovim process,
buffers, cursor, undo and language servers. Closing refuses unsaved work. If the
terminal UI closes unexpectedly, an editor with unsaved buffers stays running
and can be reattached. Clean unattended editors exit automatically.

The workspace includes:

- Fuzzy filename search and opening `file:line:column`.
- Recent file references from the agent terminal, local Codex/Claude transcripts
  and uncommitted Git changes. Transcript matching is by repository, not Rex tab.
- Persistent line/range review comments that follow edits; explicit paste or
  submit to a supported agent in the same tab.
- An optional file tree with Git status and guarded file operations.
- Markdown previews through optional Glow; image/SVG previews through Chafa;
  Mermaid previews through optional local `mmdc` and Chafa. Everything stays
  inside Neovim, with source fallbacks for unavailable text renderers.

See [the workspace guide](docs/workspace.md) for Neovim keys, supported agents,
file operations, preview dependencies and recovery commands. Workspaces currently
require local Rex terminals; Neovim splits stay inside the editor pane.

## Configuration

Use these options in the Neorex spec's `opts` table or in a direct `setup` call:

| Option | Default | Purpose |
| --- | --- | --- |
| `apply_rex_theme` | `false` | Use the attached Rex terminal's colors inside Neorex. |
| `nvim_bin` | Detected | Override the Neovim executable path. |
| `rex_bin` | Detected | Override Rex's CLI path for agent-terminal communication. |
| `runtime` | Plugin checkout | Override the directory containing the Neovim runtime. |

### Match Rex's theme

Set `apply_rex_theme = true` to query Rex's current terminal foreground,
background, cursor and ANSI palette. Neorex uses those colors for editor chrome,
syntax, diagnostics, diffs and embedded terminals.

Colors refresh when a UI attaches or gains focus; `:NeorexTheme` refreshes them
manually. If the terminal does not answer color queries, your colorscheme stays
in place. Disabling the option leaves your normal colorscheme in control.

The option changes highlights only in Neorex's running Neovim process. It does
not edit your Neovim configuration, plugins, colorscheme files or Rex's theme.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| No Neorex actions in the palette | Check the loader or plugin spec, keep the plugin eager, then run `rex config check` and reload. |
| The managed plugin loads an older copy | Remove an obsolete `neorex.lua` module in the Rex config directory and keep one setup call. |
| A shortcut opens something else | Existing config bindings and app-level shortcuts take priority; use the command palette. |
| An image or diagram does not render | Install the optional renderer described in the [workspace guide](docs/workspace.md#previews-inside-neovim). |
| An editor terminal closed with unsaved work | Use `rex do neorex_list --json` to find its socket, then [reattach](docs/workspace.md#closing-and-recovery). |

## Develop

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
```

Run this from the repository root. Tests use isolated state/config directories
and native Neovim UI clients; they do not use your running editor. GitHub Actions
runs the Lua/native-Neovim suite on macOS and Linux, plus a real Rex configuration
check on Linux. Neovim and Rex downloads are version-pinned and checksum-verified.

The Rex entrypoint is `neorex.lua`; the Neovim runtime is under `lua/neorex/`.
`scripts/start.lua` is a short-lived Lua launcher executed by Neovim itself.
Only generated state, comments and sockets live outside the checkout.

## Credits and license

Neorex is an independent Lua integration for Rex and Neovim, inspired by
[Neopane](https://github.com/spiritledsoftware/neopane) and the editing workflow
of [herdr-nvim](https://github.com/ChmaraX/herdr-nvim).

[MIT license](LICENSE).
