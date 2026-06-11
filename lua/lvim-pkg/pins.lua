-- lvim-pkg: version pins. A pin is simply the chosen version of a plugin or Mason
-- package recorded in the active snapshot file (see lvim-pkg.snapshot). Installing
-- "latest" leaves no entry (= track latest); installing a specific version writes it.
-- Parsers are not versioned, so their pin operations are no-ops. This module is a thin,
-- stable façade over lvim-pkg.snapshot for the installer and the host loader.
--
---@module "lvim-pkg.pins"

local snapshot = require("lvim-pkg.snapshot")

local M = {}

--- The chosen version for a name, or nil (= latest).
---@param kind string
---@param name string
---@return string|nil
function M.get(kind, name)
	return snapshot.get(kind, name)
end

--- Record `name` (of `kind`) at `version` in the active snapshot.
---@param kind string
---@param name string
---@param version string
---@param reftype? string
---@param branch? string
---@return nil
function M.set(kind, name, version, reftype, branch)
	snapshot.set(kind, name, version, reftype, branch)
end

--- Full record ({ version, reftype, branch }), or nil.
---@param kind string
---@param name string
---@return table|nil
function M.get_full(kind, name)
	return snapshot.get_full(kind, name)
end

--- Remove a name's entry (= track latest).
---@param kind string
---@param name string
---@return nil
function M.unset(kind, name)
	snapshot.unset(kind, name)
end

--- All pins as kind → name → version.
---@return table<string, table<string, string>>
function M.all()
	local out = {}
	for kind, names in pairs(snapshot.all_full()) do
		out[kind] = {}
		for name, rec in pairs(names) do
			out[kind][name] = rec.version
		end
	end
	return out
end

--- All pins with full records (kind → name → { version, reftype, branch }).
---@return table<string, table<string, table>>
function M.all_full()
	return snapshot.all_full()
end

return M
