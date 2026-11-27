# Neorex

Neorex is a Rex-focused Lua plugin. `neorex.lua` runs in Rex's Lua 5.1 runtime;
`lua/neorex/` and `scripts/start.lua` run in Neovim 0.12 or later.

- Keep the Rex side compatible with Lua 5.1 and Rex's documented APIs. No Lua C
  modules, LuaRocks, standalone Lua interpreter or custom executable is required.
- Neovim owns rendering, input, buffers and RPC. Rex owns the terminal panes.
- The native server must preserve unsaved work when a terminal closes. Never
  restart or replace a live editor without checking this.
- Existing key bindings and custom pane titles take precedence.
- The tree stays closed by default. Theme integration is opt-in and must never
  edit the user's Neovim configuration.
- Keep all plugin source in this checkout; user config only loads it.
- Keep the current two-space Lua formatting; avoid unrelated reformatting.
- Run `nvim --headless -u NONE -i NONE -l tests/run.lua` after behavior changes.
  A single target can be passed as its last argument: workspace, rex_workspace,
  theme or native. Tests must use isolated state/config directories.
- Test live changes in a separate Rex session. A requested user preview may be
  opened in its own tab, keeping existing editing buffers intact.
- Use GitHub Issues on justusperillieux/neorex. Keep PR/commit titles conventional.
- Do not add AI/model attribution or co-author trailers to commits or PRs.
