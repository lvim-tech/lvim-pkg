-- lvim-pkg: SQLite-backed store for pins, install receipts and declines.
-- One database (root/lvim-pkg.db) holds:
--   pins      kind (mason|parser|plugin) → name → version
--   receipts  name → { version, type, bins, installed_at }
--   declines  (ft, name) → packages the user chose not to install for a filetype
-- sqlite.lua is loaded lazily (packadd on first access) so it never adds to the
-- critical startup path. If sqlite is unavailable the helpers degrade to nil/no-op
-- and callers fall back to their previous behaviour.
--
---@module "lvim-pkg.db"

local M = {}

---@type table|false|nil  the opened db, false = unavailable, nil = not tried yet
local db = nil

--- Open (once) the sqlite database, loading sqlite.lua on demand.
---@return table|nil
local function get()
	if db ~= nil then
		return db or nil
	end
	pcall(vim.cmd, "packadd sqlite.lua")
	local ok, sqlite = pcall(require, "sqlite")
	if not ok then
		db = false
		return nil
	end
	local paths = require("lvim-pkg.paths")
	paths.ensure()
	local opened, handle = pcall(sqlite, {
		uri = paths.root() .. "/lvim-pkg.db",
		pins = { id = true, kind = "text", name = "text", version = "text", reftype = "text", branch = "text" },
		receipts = {
			id = true,
			name = "text",
			version = "text",
			typ = "text",
			bins = "luatable",
			installed_at = "integer",
		},
		declines = { id = true, ft = "text", name = "text" },
	})
	db = opened and handle or false
	if db then
		-- Add columns to a pre-existing pins table (older schema).
		pcall(function()
			db:execute("ALTER TABLE pins ADD COLUMN reftype text")
		end)
		pcall(function()
			db:execute("ALTER TABLE pins ADD COLUMN branch text")
		end)
	end
	return db or nil
end

-- ── pins ────────────────────────────────────────────────────────────────────

--- Pinned version for a name of a kind, or nil.
---@param kind string
---@param name string
---@return string|nil
function M.pin_get(kind, name)
	local d = get()
	if not d then
		return nil
	end
	local rows = d.pins:get({ where = { kind = kind, name = name } })
	return rows[1] and rows[1].version or nil
end

--- All pins as kind → name → { version, reftype, branch } (one query).
---@return table<string, table<string, { version: string, reftype: string|nil, branch: string|nil }>>
function M.pins_all_full()
	local d = get()
	if not d then
		return {}
	end
	local out = {}
	for _, r in ipairs(d.pins:get()) do
		out[r.kind] = out[r.kind] or {}
		out[r.kind][r.name] = { version = r.version, reftype = r.reftype, branch = r.branch }
	end
	return out
end

--- Full pin record (version + how it was pinned), or nil.
---@param kind string
---@param name string
---@return { version: string, reftype: string|nil, branch: string|nil }|nil
function M.pin_get_full(kind, name)
	local d = get()
	if not d then
		return nil
	end
	local rows = d.pins:get({ where = { kind = kind, name = name } })
	local r = rows[1]
	if not r then
		return nil
	end
	return { version = r.version, reftype = r.reftype, branch = r.branch }
end

--- Pin (upsert) a name of a kind to a version.
---@param kind string
---@param name string
---@param version string
---@return nil
function M.pin_set(kind, name, version, reftype, branch)
	local d = get()
	if not d then
		return
	end
	d.pins:remove({ kind = kind, name = name })
	d.pins:insert({ kind = kind, name = name, version = version, reftype = reftype, branch = branch })
end

--- Remove a pin.
---@param kind string
---@param name string
---@return nil
function M.pin_unset(kind, name)
	local d = get()
	if not d then
		return
	end
	d.pins:remove({ kind = kind, name = name })
end

--- All pins as kind → name → version.
---@return table<string, table<string, string>>
function M.pins_all()
	local d = get()
	if not d then
		return {}
	end
	local out = {}
	for _, r in ipairs(d.pins:get()) do
		out[r.kind] = out[r.kind] or {}
		out[r.kind][r.name] = r.version
	end
	return out
end

-- ── receipts ──────────────────────────────────────────────────────────────────

--- Install receipt for a package, or nil.
---@param name string
---@return { name: string, version: string, type: string, bins: string[] }|nil
function M.receipt_get(name)
	local d = get()
	if not d then
		return nil
	end
	local rows = d.receipts:get({ where = { name = name } })
	local r = rows[1]
	if not r then
		return nil
	end
	return { name = r.name, version = r.version, type = r.typ, bins = r.bins or {} }
end

--- Upsert a package's install receipt.
---@param name string
---@param receipt { version?: string, type?: string, bins?: string[] }
---@return nil
function M.receipt_set(name, receipt)
	local d = get()
	if not d then
		return
	end
	d.receipts:remove({ name = name })
	d.receipts:insert({
		name = name,
		version = receipt.version,
		typ = receipt.type,
		bins = receipt.bins or {},
		installed_at = os.time(),
	})
end

--- Remove a package's receipt.
---@param name string
---@return nil
function M.receipt_remove(name)
	local d = get()
	if not d then
		return
	end
	d.receipts:remove({ name = name })
end

--- Names of all packages with a receipt.
---@return string[]
function M.receipt_names()
	local d = get()
	if not d then
		return {}
	end
	local out = {}
	for _, r in ipairs(d.receipts:get()) do
		out[#out + 1] = r.name
	end
	return out
end

-- ── declines ──────────────────────────────────────────────────────────────────

--- Record that `name` was declined for filetype `ft` (idempotent).
---@param ft string
---@param name string
---@return nil
function M.decline_add(ft, name)
	local d = get()
	if not d then
		return
	end
	d.declines:remove({ ft = ft, name = name })
	d.declines:insert({ ft = ft, name = name })
end

--- Remove a decline (re-enable `name` for `ft`).
---@param ft string
---@param name string
---@return nil
function M.decline_remove(ft, name)
	local d = get()
	if not d then
		return
	end
	d.declines:remove({ ft = ft, name = name })
end

--- Names declined for `ft`, as a set.
---@param ft string
---@return table<string, boolean>
function M.declines_for_ft(ft)
	local d = get()
	if not d then
		return {}
	end
	local out = {}
	for _, r in ipairs(d.declines:get({ where = { ft = ft } })) do
		out[r.name] = true
	end
	return out
end

--- Every decline as a { ft, name } list.
---@return { ft: string, name: string }[]
function M.declines_all()
	local d = get()
	if not d then
		return {}
	end
	local out = {}
	for _, r in ipairs(d.declines:get()) do
		out[#out + 1] = { ft = r.ft, name = r.name }
	end
	return out
end

--- True when the database is usable.
---@return boolean
function M.available()
	return get() ~= nil
end

return M
