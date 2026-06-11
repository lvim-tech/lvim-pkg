-- lvim-pkg plugin guard.
-- Nothing auto-runs; consumers drive everything via require("lvim-pkg").
-- This file exists so the plugin manager recognises the plugin without requiring
-- an explicit `main` field.
if vim.g.loaded_lvim_pkg then
	return
end
vim.g.loaded_lvim_pkg = true
