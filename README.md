# lvim-pkg

The single **data + operations hub** for the LVIM installable ecosystem. One
plugin that answers every "what is available / installed / missing" question and
performs every install / update / remove, across three backends:

| Kind | Backend | Handles |
| --- | --- | --- |
| `mason` | mason-registry | LSP servers, linters, formatters, DAP, tree-sitter CLI |
| `parser` | treesitter-parser-registry | treesitter parsers + their Neovim queries |
| `plugin` | `vim.pack` | Neovim plugins |

Both the Mason and the parser backends are **self-contained** — no `mason.nvim` and
no `nvim-treesitter`. Each consumes an editor-agnostic community catalogue
(`mason-registry`, `treesitter-parser-registry`) and installs from source itself:
Mason via npm / pypi / golang / cargo / github; parsers by compiling the grammar
with the tree-sitter CLI and dropping the `.so` + query files on the runtimepath so
Neovim's built-in `vim.treesitter` uses them. Catalogues are fetched and cached with
a configurable TTL.

It has **no UI** (that is `lvim-installer`) and **no editor runtime** (LSP attach
lives in `lvim-lsp`, treesitter highlighting in `lvim-ts`). Domain plugins depend
on `lvim-pkg`; `lvim-pkg` depends on nothing in the ecosystem.

## Installation

Requires `kkharji/sqlite.lua` (the database for pins, install receipts and per-filetype declines).

### LVIM IDE

Ships with LVIM IDE, loaded early (`lazy = false`, high priority) because other
plugins query it during their own setup. Override via your user module
(`lua/modules/user/init.lua`):

```lua
modules["lvim-tech/lvim-pkg"] = {
  dependencies = { "kkharji/sqlite.lua" },
  config = function()
    require("lvim-pkg").setup({ ensure_cli = true })
  end,
}
```

### Standalone (lazy.nvim)

```lua
{
  "lvim-tech/lvim-pkg",
  lazy = false,
  priority = 1000,
  dependencies = { "kkharji/sqlite.lua" },
  opts = { ensure_cli = true },   -- bootstrap the tree-sitter CLI
}
```

## Usage

```lua
require("lvim-pkg").setup({ ensure_cli = true })
```

## Configuration

`setup(opts)` merges into the defaults (`LvimPkgConfig`):

```lua
require("lvim-pkg").setup({
  root = vim.fn.stdpath("data") .. "/lvim-pkgs",  -- unified install root
  ensure_cli = true,                              -- install the tree-sitter CLI on setup
  update_registry = true,                         -- silently refresh the catalogues at setup
  registry_ttl = 7 * 24 * 60 * 60,                -- seconds before a cached catalogue is stale
})
```

Everything lvim-pkg installs lives under `root`: `packages/` (Mason binaries),
`bin/` (linked executables, added to `PATH`) and `ts/parser` + `ts/queries`
(treesitter parsers and their queries, added to the runtimepath), plus
`lvim-pkg.db` (SQLite: pins, install receipts and per-filetype declines) and the
cached `registry.json` / `ts-registry.json` catalogues. Neovim plugins are **not**
here — `vim.pack` owns them under `site/pack/core/opt`.

Both catalogues refresh silently at setup once their cache is older than
`registry_ttl`, and can be force-refreshed via `:LvimInstaller update-registry
[mason|ts|all]`.

## API

```lua
local pkg = require("lvim-pkg")

pkg.available(kind)            -- string[]
pkg.installed(kind)            -- string[]
pkg.is_installed(kind, name)   -- boolean
pkg.install(kind, items, cb, opts)
pkg.update(kind, names, cb)
pkg.remove(kind, names, cb)

-- Requirement registry (filetype-driven prompt)
pkg.register_provider(name, function(ft) return { item, ... } end)
pkg.missing_for_ft(ft)         -- LvimPkgItem[] (missing, not declined)

-- Version pins (per kind; a git ref for plugins)
pkg.pin(kind, name, version)
pkg.get_pin(kind, name)        -- string|nil
pkg.unpin(kind, name)

-- Per-filetype declines: missing_for_ft filters these out and the prompt stops offering them
pkg.decline(ft, names)         -- names: string[]
pkg.undecline(ft, name)        -- re-enable one
pkg.declined()                 -- { { ft = "...", name = "..." }, ... }

-- Registry refresh ("mason" | "ts" | "all"); force ignores the TTL
pkg.update_registry(which, cb, force)
```

### LvimPkgItem

```lua
{ kind = "mason"|"parser"|"plugin", name = "...", label? = "...", group? = "..." }
```

Domain plugins register a provider during their own `setup()`:

```lua
require("lvim-pkg").register_provider("ts", function(ft)
    local lang = require("lvim-ts").missing_for_ft(ft)
    return lang and { { kind = "parser", name = lang, label = "parser: " .. lang } } or {}
end)
```

## Part of the LVIM ecosystem

- [lvim-installer](https://github.com/lvim-tech/lvim-installer) — the UI for this engine
- [lvim-ls](https://github.com/lvim-tech/lvim-ls) — LSP engine (tool requirement provider)
- [lvim-ts](https://github.com/lvim-tech/lvim-ts) — treesitter runtime (parser requirement provider)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) — shared UI / notify
