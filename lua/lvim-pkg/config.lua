-- lvim-pkg: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place, so every
-- require("lvim-pkg.config") reader sees the effective values.
--
---@module "lvim-pkg.config"

---@class LvimPkgConfig
---@field root            string        Unified install root (subfolders: packages/ bin/ ts/)
---@field ensure_cli      boolean       Install the tree-sitter CLI on first setup when missing
---@field snapshot_dir    string|nil    Directory holding the version snapshots (switchable
---                                      sets of plugin + mason versions) and the `active`
---                                      marker file. Defaults to <config>/.snapshots.
---@field registry_ttl    integer       Seconds before a cached catalogue is re-downloaded at
---                                      setup. 0 (or less) disables the auto-refresh (fetch
---                                      only when the cache is missing). Default 7 days.
---@field max_concurrency integer       Maximum packages installed in parallel (per batch).
---                                      Default 4.
---@field extra_parsers   table<string, LvimPkgTsEntry>  Tree-sitter parsers the community
---                                      catalogue does not carry, keyed by language. Entries use
---                                      the registry's OWN shape, so nothing else in the engine
---                                      has to know they came from here; they are merged over the
---                                      fetched catalogue on every load and WIN a name collision
---                                      (an explicit local entry outranks the catalogue's).

---@class LvimPkgTsSource
---@field type "self_contained"|"external_queries"|"queries_only"  where the queries come from:
---   the parser repo itself, a separate queries repo, or queries alone reusing another parser
---@field parser_url string?      the grammar repository (all but queries_only)
---@field parser_location string? subdirectory holding grammar.js when it is not the repo root
---@field queries_dir string?     subdirectory holding the queries (self_contained only)
---@field queries_url string?     the queries repository (external_queries)
---@field url string?             the queries repository (queries_only)
---@field parser_semver boolean?  the grammar is released by semver tag rather than by branch

---@class LvimPkgTsEntry
---@field filetypes string[]      the filetypes this parser serves
---@field requires string[]?      other languages that must be installed first
---@field source LvimPkgTsSource

---@type LvimPkgConfig
return {
    root = vim.fn.stdpath("data") .. "/lvim-pkgs",
    ensure_cli = true,
    snapshot_dir = nil,
    registry_ttl = 7 * 24 * 60 * 60,
    max_concurrency = 4,
    extra_parsers = {},
}
