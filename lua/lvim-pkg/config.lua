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

---@type LvimPkgConfig
return {
    root = vim.fn.stdpath("data") .. "/lvim-pkgs",
    ensure_cli = true,
    snapshot_dir = nil,
    registry_ttl = 7 * 24 * 60 * 60,
    max_concurrency = 4,
}
