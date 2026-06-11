-- lvim-pkg: requirement aggregation for the unified installer prompt.
-- Domain plugins register providers that, given a filetype, return the items
-- they would need installed.  missing_for_ft aggregates them and filters to the
-- items that are genuinely not installed yet and not declined for the filetype.
--
---@module "lvim-pkg.data"

local state = require("lvim-pkg.state")
local db = require("lvim-pkg.db")

local M = {}

---@class LvimPkgItem
---@field kind   string  Backend kind: "mason" | "parser" | "plugin"
---@field name   string  Package/parser/plugin name passed to the backend
---@field label? string  Display label (falls back to name)
---@field group? string  Optional grouping key (e.g. the owning LSP server)

--- Collect every provider's items for `ft`, de-duplicated and missing-only.
---@param ft string
---@return LvimPkgItem[]
function M.missing_for_ft(ft)
	local pkg = require("lvim-pkg")
	local declined = db.declines_for_ft(ft)
	local seen = {}
	local out = {}
	for _, provider in pairs(state.providers) do
		local ok, items = pcall(provider, ft)
		if ok and type(items) == "table" then
			for _, item in ipairs(items) do
				local key = item.kind .. "\0" .. item.name
				if not seen[key] and not declined[item.name] and not pkg.is_installed(item.kind, item.name) then
					seen[key] = true
					item.label = item.label or item.name
					out[#out + 1] = item
				end
			end
		end
	end
	return out
end

return M
