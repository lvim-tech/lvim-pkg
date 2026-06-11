-- lvim-pkg: version/commit pins, stored in the SQLite database (lvim-pkg.db).
-- Pins lock a package, parser or plugin to a specific version/commit; the mason
-- installer applies a pin by overriding the registry's default version. Falls back
-- to a no-op when sqlite is unavailable. The legacy pins.json is imported once.
--
---@module "lvim-pkg.pins"

local M = {}

local db = require("lvim-pkg.db")
local migrated = false

--- One-time import of the legacy root/pins.json into the database.
local function migrate()
	if migrated then
		return
	end
	migrated = true
	if not db.available() then
		return
	end
	local file = require("lvim-pkg.paths").root() .. "/pins.json"
	local f = io.open(file, "r")
	if not f then
		return
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" then
		for kind, names in pairs(data) do
			if type(names) == "table" then
				for name, version in pairs(names) do
					if type(name) == "string" and type(version) == "string" and version ~= "" then
						db.pin_set(kind, name, version)
					end
				end
			end
		end
	end
	os.rename(file, file .. ".migrated") -- don't re-import
end

--- The pinned version for a name, or nil.
---@param kind string
---@param name string
---@return string|nil
function M.get(kind, name)
	migrate()
	return db.pin_get(kind, name)
end

--- Pin `name` (of `kind`) to `version`.
---@param kind string
---@param name string
---@param version string
---@return nil
function M.set(kind, name, version, reftype, branch)
	migrate()
	db.pin_set(kind, name, version, reftype, branch)
end

--- Full pin record (version + reftype + branch), or nil.
---@param kind string
---@param name string
---@return { version: string, reftype: string|nil, branch: string|nil }|nil
function M.get_full(kind, name)
	migrate()
	return db.pin_get_full(kind, name)
end

--- Remove a pin.
---@param kind string
---@param name string
---@return nil
function M.unset(kind, name)
	migrate()
	db.pin_unset(kind, name)
end

--- All pins (kind → name → version).
---@return table<string, table<string, string>>
function M.all()
	migrate()
	return db.pins_all()
end

--- All pins with their full records (kind → name → { version, reftype, branch }).
---@return table<string, table<string, table>>
function M.all_full()
	migrate()
	return db.pins_all_full()
end

return M
