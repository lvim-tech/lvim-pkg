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
Neovim's built-in `vim.treesitter` uses them. Each catalogue is fetched at setup when
its on-disk cache is missing or older than `registry_ttl`, and on demand.

It has **no UI** (that is `lvim-installer`) and **no editor runtime** (LSP attach
lives in `lvim-lsp`, treesitter highlighting in `lvim-ts`). Domain plugins depend
on `lvim-pkg`; `lvim-pkg` depends on nothing in the ecosystem.

## Installation

No Lua-plugin dependencies — install state is plain JSON under the install root (see
[Layout on disk](#layout-on-disk)). External tools are needed only to actually fetch and
build packages: `curl`, `tar`/`unzip`, a C compiler (`cc`) and the per-source toolchains
(`git`, `npm`, `python3`/`pip`, `go`, `cargo`). Run `:checkhealth lvim-pkg` to see what is
present.

### LVIM IDE

Ships with LVIM IDE, loaded early (`lazy = false`, high priority) because other
plugins query it during their own setup. Override via your user module
(`lua/modules/user/init.lua`):

```lua
modules["lvim-tech/lvim-pkg"] = {
    config = function()
        require("lvim-pkg").setup({ ensure_cli = true })
    end,
}
```

### Standalone (lazy.nvim)

```text
{
  "lvim-tech/lvim-pkg",
  lazy = false,
  priority = 1000,
  opts = { ensure_cli = true },   -- bootstrap the tree-sitter CLI
}
```

## Usage

```lua
require("lvim-pkg").setup({ ensure_cli = true })
```

## Configuration

`setup(opts)` merges into the live defaults (`LvimPkgConfig`), in place, so every
`require("lvim-pkg.config")` reader sees the effective values:

```lua
require("lvim-pkg").setup({
    root = vim.fn.stdpath("data") .. "/lvim-pkgs", -- unified install root
    ensure_cli = true, -- install the tree-sitter CLI on setup when missing
    snapshot_dir = nil, -- version-snapshot dir (default: <config>/.snapshots)
    registry_ttl = 7 * 24 * 60 * 60, -- re-fetch a cached catalogue at setup once this old (0 = never)
    max_concurrency = 4, -- max packages installed in parallel per batch
})
```

Everything lvim-pkg installs lives under `root`: `packages/` (Mason binaries),
`bin/` (linked executables, added to `PATH`) and `ts/parser` + `ts/queries`
(treesitter parsers and their queries, added to the runtimepath), plus
`state.json` (install receipts + per-filetype declines), the active version
snapshot (pins / per-plugin + per-Mason version choices) and the cached
`registry.json` / `ts-registry.json` catalogues. Neovim plugins are **not**
here — `vim.pack` owns them under `site/pack/core/opt`.

Catalogues are downloaded at setup when the cache file is missing or older than
`registry_ttl` (default 7 days; set it to `0` to disable the age-based refresh). Force a
re-download any time via `:LvimInstaller update-registry [mason|ts|all]`.

## API

```lua
local pkg = require("lvim-pkg")
```

### Backend operations (kind = `"mason"|"parser"|"plugin"`)

```lua
pkg.available(kind) -- string[]
pkg.installed(kind) -- string[]
pkg.is_installed(kind, name) -- boolean
pkg.install(kind, items, cb, opts)
pkg.update(kind, names, cb)
pkg.remove(kind, names, cb)
pkg.backend(kind) -- the backend module, or nil
```

### Versions

```lua
pkg.installed_version(name) -- string|nil (Mason package version)
pkg.available_versions(kind, name, cb) -- async; cb(string[]|nil) (Mason only)
pkg.parser_installed_version(lang) -- string|nil (grammar revision)
pkg.is_managed(name) -- installed in OUR path (vs legacy mason.nvim)
pkg.package_path(name) -- install dir (ours, else legacy mason)
```

### Requirement registry (filetype-driven prompt)

Domain plugins register a provider during their own `setup()`; the unified prompt
aggregates every provider's missing items for the opened filetype.

```lua
pkg.register_provider(name, function(ft)
    return { item, ... }
end)
pkg.missing_for_ft(ft) -- LvimPkgItem[] (missing, not declined)
pkg.on(event, fn) -- subscribe to installer events (e.g. "installing")
pkg.emit(event, ...) -- fire subscribers
```

### Plugin introspection (reported by the host loader)

```text
pkg.register_plugins(map)             -- host loader registers the full spec set once
pkg.record_load(name, reason, time)   -- host loader records each load
pkg.plugins()                         -- rich info for every plugin
pkg.plugin_info(name)                 -- rich info for one
pkg.plugin_stats()                    -- { loaded, total }
pkg.check_outdated(cb, on_progress)   -- async: which plugins have an upstream update
pkg.parser_outdated(lang)             -- last-check result for a parser
pkg.check_parsers_outdated(cb, on_progress)
-- plugin git data (pin menu): branches/tags/commits/current/fetch/checkout/…
pkg.plugin_branches(name) / plugin_default_branch(name) / plugin_current(name)
pkg.plugin_tags(name) / plugin_commits(name, ref) / plugin_newest_tag(name)
pkg.plugin_resolve_tag(name, prefix) / plugin_branch_tip(name, branch)
pkg.plugin_fetch(name, cb) / plugin_checkout(name, ref) / plugin_update_branch(name, branch)
pkg.load_tags(cb) / git_log(name) / load_git_log(name, cb)
```

### Version pins (per kind; a git ref for plugins)

```lua
pkg.pin(kind, name, version, reftype, branch) -- reftype "tag"|"branch", branch = context
pkg.get_pin(kind, name) -- string|nil
pkg.get_pin_full(kind, name) -- { version, reftype, branch }|nil
pkg.pins() -- kind -> name -> version
pkg.pins_full(kind) -- name -> full record
pkg.unpin(kind, name)
```

### Snapshots (switchable version sets)

A snapshot pins the whole installed set (each plugin's git HEAD, each Mason
package's version) to a named file; selecting one and restoring its diff checks
out / reinstalls only what differs.

```lua
pkg.snapshots() -- string[]
pkg.active_snapshot() -- string
pkg.select_snapshot(name) -- boolean
pkg.snapshot_save(name) -- ok, err?
pkg.snapshot_diff() -- { plugins = {{name,from,to}}, mason = {...} }
pkg.snapshot_restore(diff, cb, on_progress)
pkg.snapshot_export(dest) -- write the active set to a shareable lockfile; ok, err?
pkg.snapshot_import(src, name) -- read a lockfile into a new (non-active) snapshot; ok, err?
```

### Per-filetype declines

`missing_for_ft` filters these out and the prompt stops offering them.

```lua
pkg.decline(ft, names) -- names: string[]
pkg.undecline(ft, name) -- re-enable one
pkg.declined() -- { { ft = "...", name = "..." }, ... }
```

### Registry refresh

```lua
pkg.update_registry(which, cb, force) -- which "mason"|"ts"|"all"; force ignores the cache
```

### LvimPkgItem

```text
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
