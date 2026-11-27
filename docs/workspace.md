# Editing beside your agents

The workspace is a persistent Neovim editor for each Rex tab. It loads your
normal Neovim configuration and adds an optional file tree, fuzzy file picker, recent
agent references, file-and-line review comments, and local previews.

## Configure Rex

Add this to your Rex `init.lua`, replacing the path with your checkout:

~~~lua
local repo = "/path/to/neorex"
dofile(repo .. "/neorex.lua").setup {
  apply_rex_theme = false,
}
~~~

Then run `rex config check` and `rex config reload`. The integration is
Lua: Rex manages the panes and shortcuts; the Neovim runtime in
`lua/neorex/workspace/` provides the editor features. Native Neovim runs as a
persistent headless server, with `nvim --remote-ui` in the Rex terminal.

There is no custom executable. Set `nvim_bin` in the setup table
if needed; `rex_bin` overrides Rex's CLI location. Your normal Neovim configuration is loaded first. The runtime is
found beside the Rex entrypoint, so all plugin code stays in the checkout.

`apply_rex_theme = true` queries the attached terminal's current colors and
applies them to Neorex's highlights. It never edits your Neovim configuration.
Colors refresh on UI attachment or focus; `:NeorexTheme` refreshes them manually.
With the option disabled, your normal Neovim colorscheme remains in control.

Cmd-E toggles this tab's editor, Cmd-O opens the recent-file picker, and
Shift-Cmd-E reveals the active file in the tree. These bindings are added
only where your Rex config leaves the keys free. App-level shortcut
settings still take priority.

The command palette also offers:

| Action | Behavior |
| --- | --- |
| `neorex_toggle` | Hide or restore the editor |
| `neorex_files` | Reveal the active file in the tree |
| `neorex_pick` | Fuzzy-search repository files |
| `neorex_recent` | Agent references and Git changes |
| `neorex_preview` | Preview the current file |
| `neorex_notes` | Review comments |
| `neorex_open` | Open a file, with optional line and column |
| `neorex_close` | Close the editor, refusing unsaved work |
| `neorex_status` | Report this tab's editor as JSON |
| `neorex_list` | List live native editors, including retained servers |

~~~sh
rex do neorex_toggle
rex do neorex_open file=src/main.rs:42:5
rex do neorex_preview
rex do neorex_status
~~~

Rex's `-b BLOCK` flag selects a particular terminal when needed.

The editor opens beside the source terminal, titled `Neorex · <project>`.
You can rename the pane yourself; Neorex keeps that custom title.
The tree starts closed; Shift-Cmd-E or `:NeorexFiles` opens it on request.
Hiding detaches that same
terminal from the layout; showing restores it. Neovim, unsaved buffers,
cursor, undo history and language servers keep running while hidden.
Each Rex tab has its own editor. Workspaces currently require a local Rex
terminal.

The workspace uses one Rex terminal containing the editor, its splits and
picker floats. The optional tree also stays inside that terminal. Rex manages
the terminal's placement; native Neovim handles rendering and input.

## Neovim keys

These mappings are added only when the key is not already mapped.

| Key | Behavior |
| --- | --- |
| `<leader>ne` | Toggle the tree, keeping the editor open |
| `<leader>nf` | Find a repository file |
| `<leader>no` | Agent references and Git changes |
| `<leader>np` | Preview the current file |
| `<leader>ac` | Comment on the current line or visual range |
| `<leader>al` | Review or delete comments |
| `<leader>as` | Choose an agent and paste comments after confirmation |
| `<leader>aS` | Choose an agent, confirm, paste and submit comments |

Commands are available even when a key is already in use:
`:NeorexFiles`, `:NeorexPick`, `:NeorexRecent`, `:NeorexPreview`,
`:NeorexComment`, `:NeorexNotes`, `:NeorexSend` and
`:NeorexSend!`.

Comments show beside their lines and follow edits using Neovim extmarks.
They are saved in the workspace state directory and are kept after sending.
Sending is explicit: Neorex never submits a comment automatically.
Supported agent processes include Codex, Claude Code, Pi, Aider, OpenCode,
Gemini, Goose and Amp. Only agents in this Rex tab are offered; a shell is
never a comment destination.

The recent-file picker combines file references visible in the original
terminal, the latest matching repository Codex or Claude tool-call
transcript, and uncommitted Git changes. Its title identifies the transcript
when one was used. Transcripts are matched by repository, not by Rex tab:
with several concurrent agent sessions in one repository, the transcript
may belong to another session. The selected terminal's visible references
remain tab-specific. Logs are read locally and never modified or uploaded.

## Tree and picker

The tree refreshes while visible, shows Git status and remembers expanded
folders. The picker filters as you type; typing in the recent-file picker also
searches the whole repository. Enter opens a file, Up/Down or
Ctrl-P/Ctrl-N moves, and Escape cancels.

| Tree key | Behavior |
| --- | --- |
| Enter / `l` | Open file or toggle folder |
| `h` | Close folder |
| `/` | Fuzzy-search repository files |
| `a` | Create a file or folder; end a folder name with `/` |
| `r` | Rename the selected path |
| Tab | Select paths for an operation |
| `m` / `c` | Move / copy selected paths into this folder |
| `d` | Delete selected paths after confirmation |
| `y` / `p` | Yank paths / copy those files into this folder |
| `H` / `I` | Show hidden / Git-ignored paths |
| Backspace / `.` / `~` | Root up / root at this folder / return to repository |
| `Z` / `u` | Collapse folders / refresh |
| `q` / Escape | Focus the editor |
| `?` | Show the keys |

Rename follows open buffers and notifies language servers. Neovim's native
rename saves modified buffers, so Neorex asks before saving and renaming
them; Cancel leaves the disk and buffer untouched. Delete refuses paths
with unsaved buffers. Copy and move never replace an existing destination.
Operations following a path outside the repository ask first.

## Previews inside Neovim

Previews stay inside Neovim; no browser window, remote renderer or CDN is used.

* Markdown uses Glow when installed; otherwise the source is shown with
  Markdown highlighting and concealment. An existing render-markdown.nvim
  installation can render that buffer.
* Images and SVG use Chafa's true-color character rendering in a Neovim
  terminal buffer. They do not require Rex to support a pixel image protocol.
* Mermaid files and fenced Mermaid diagrams use the local `mmdc` renderer
  and Chafa. Rendered diagrams are cached by content. If rendering is
  unavailable or a diagram is invalid, its source remains visible.
* Unsaved text previews use the current buffer, keeping its unsaved changes
  intact. Press `q` or Escape to return to the same source buffer.

Glow and Chafa are optional local renderers. On macOS they can be installed
with `brew install glow chafa`. Mermaid rendering additionally needs Mermaid
CLI's `mmdc` and its local browser runtime. Source previews work without
these renderers; images need Chafa.

## Closing and recovery

`rex do neorex_close` closes this tab's editor, refusing unsaved buffers.
Hiding it does not stop it. When the parent tab closes, a hidden editor
exits if clean. An editor with unsaved work is retained for recovery:

~~~sh
rex do neorex_list --json
nvim --server /tmp/neorex-USER_ID/lua-WORKSPACE_ID.sock --remote-ui
~~~

Use the exact socket returned by `neorex_list` or `neorex_status`. A recovered
editor retains its buffers and undo history; save or discard changes normally.
The workspace will not hide itself
when it is the only remaining pane, because detaching it would close the
tab.

State and review comments live under
`$XDG_STATE_HOME/neorex/workspaces/`, otherwise
`~/.local/state/neorex/workspaces/`. Private native sockets live in
`/tmp/neorex-USER_ID/`. Your Neovim configuration is not rewritten.

The workflow is inspired by
[herdr-nvim](https://github.com/ChmaraX/herdr-nvim/blob/main/herdr-app/RECIPE.md);
the implementation uses Rex's terminal detach/restore API and Neorex's
native Neovim server.
