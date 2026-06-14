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

---@type LvimPkgConfig
return {
    root = vim.fn.stdpath("data") .. "/lvim-pkgs",
    ensure_cli = true,
    snapshot_dir = nil,
}
