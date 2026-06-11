-- lvim-pkg: shared runtime state.
-- Holds the requirement providers and event hooks contributed by domain plugins
-- (lvim-lsp, lvim-ts) for the filetype-driven install prompt. Config lives in
-- lvim-pkg.config (the live table that setup() merges user options into).
--
---@module "lvim-pkg.state"

local M = {}

--- Requirement providers contributed by domain plugins.
--- name → fun(ft: string): LvimPkgItem[]
---@type table<string, fun(ft: string): table[]>
M.providers = {}

--- Event hooks contributed by domain plugins (installer emits, domains subscribe).
--- event → fun(...)[]   e.g. "installing" (active: boolean)
---@type table<string, fun(...)[]>
M.hooks = {}

return M
