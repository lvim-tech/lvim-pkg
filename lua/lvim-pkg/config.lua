-- lvim-pkg: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place, so every
-- require("lvim-pkg.config") reader sees the effective values.
--
---@module "lvim-pkg.config"

---@class LvimPkgConfig
---@field root            string        Unified install root (subfolders: packages/ bin/ ts/)
---@field ensure_cli      boolean       Install the tree-sitter CLI on first setup when missing
---@field update_registry boolean       Silently refresh the mason + ts registry caches at setup
---@field registry_ttl    integer       Seconds before a cached registry is considered stale
---@field snapshot_file   string|nil    Active version snapshot (plugin + mason versions); the host
---                                      sets this. When nil, falls back to the lvim distribution's
---                                      <config>/.snapshots/<active> convention.

---@type LvimPkgConfig
return {
	root = vim.fn.stdpath("data") .. "/lvim-pkgs",
	ensure_cli = true,
	update_registry = true,
	registry_ttl = 7 * 24 * 60 * 60, -- 7 days
	snapshot_file = nil,
}
