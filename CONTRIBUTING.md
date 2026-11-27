# Contributing

Neorex is a Lua plugin for Rex and Neovim 0.12+. Report bugs and feature requests
through [GitHub Issues](https://github.com/justusperillieux/neorex/issues).

The Rex entrypoint is `neorex.lua`. Neovim editor features live in
`lua/neorex/workspace/`, theme integration in `lua/neorex/theme.lua`, and the
native server launcher in `scripts/start.lua`.

Run the isolated tests before opening a pull request:

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
```

Use a Conventional Commit title for your PR. Explain the resulting behavior,
how it was checked, and any limitations. Test live pane behavior in a separate
Rex session so it cannot interrupt someone else's editor.
