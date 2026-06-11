-- lvim-pkg: the active version snapshot — a switchable JSON file of per-plugin and
-- per-mason version choices. Shape:
--     { "plugins": { "<owner/repo>": { "commit"|"tag"|"branch": "…" } },
--       "mason":   { "<name>":       { "version": "…" } } }
-- A missing entry (or an empty file / "{}") means LATEST: HEAD for a plugin, the
-- registry's newest for a Mason package. The file is read and written in place, so the
-- installer UI and a text editor edit the same file; switching the active file (via the
-- host's snapshot selector) switches the whole version set. Parsers are NOT versioned
-- here — their version is dictated by the treesitter registry.
--
---@module "lvim-pkg.snapshot"

local config = require("lvim-pkg.config")

local M = {}

-- Map a backend "kind" to a snapshot section. Parsers have no version → no section.
local SECTION = { plugin = "plugins", plugins = "plugins", mason = "mason" }

--- Absolute path of the active snapshot file, or nil when none is configured.
---@return string|nil
local function path()
	if type(config.snapshot_file) == "string" and config.snapshot_file ~= "" then
		return config.snapshot_file
	end
	-- Fall back to the host's convention (lvim distribution): <config>/.snapshots/<active>.
	local g = _G.LVIM
	if g and g.global and g.global.lvim_path and g.snapshot then
		return g.global.lvim_path .. "/.snapshots/" .. g.snapshot
	end
	return nil
end

--- Read the active snapshot, normalized to { plugins = {…}, mason = {…} }.
---@return { plugins: table, mason: table }
local function read()
	local empty = { plugins = {}, mason = {} }
	local p = path()
	if not p then
		return empty
	end
	local f = io.open(p, "r")
	if not f then
		return empty
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	if not ok or type(data) ~= "table" then
		return empty
	end
	-- Backward-compat: a flat lazy-lock snapshot ({ "name": {commit} }) is plugins-only.
	if data.plugins == nil and data.mason == nil then
		data = { plugins = data, mason = {} }
	end
	data.plugins = data.plugins or {}
	data.mason = data.mason or {}
	return data
end

--- Encode `value` as indented, key-sorted JSON (the file is human-edited).
---@param value any
---@param indent? string
---@return string
local function pretty(value, indent)
	indent = indent or ""
	local ni = indent .. "  "
	if type(value) ~= "table" then
		return vim.json.encode(value)
	end
	if vim.islist(value) then
		if #value == 0 then
			return "[]"
		end
		local parts = {}
		for _, v in ipairs(value) do
			parts[#parts + 1] = ni .. pretty(v, ni)
		end
		return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
	end
	local keys = {}
	for k in pairs(value) do
		keys[#keys + 1] = k
	end
	if #keys == 0 then
		return "{}"
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = ni .. vim.json.encode(k) .. ": " .. pretty(value[k], ni)
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

--- Write the snapshot back to the active file.
---@param data table
---@return boolean
local function write(data)
	local p = path()
	if not p then
		return false
	end
	local f = io.open(p, "w")
	if not f then
		return false
	end
	f:write(pretty(data))
	f:close()
	return true
end

--- Normalize a raw entry to { version, reftype, branch }.
---@param entry table|nil
---@return { version: string, reftype: string, branch: string|nil }|nil
local function normalize(entry)
	if type(entry) ~= "table" then
		return nil
	end
	if entry.commit then
		return { version = entry.commit, reftype = "commit", branch = entry.branch }
	elseif entry.tag then
		return { version = entry.tag, reftype = "tag", branch = entry.branch }
	elseif entry.branch then
		return { version = entry.branch, reftype = "branch" }
	elseif entry.version then
		return { version = entry.version, reftype = "version" }
	end
	return nil
end

--- The chosen version for a plugin/mason name in the active snapshot, or nil (= latest).
---@param kind string
---@param name string
---@return string|nil
function M.get(kind, name)
	local sec = SECTION[kind]
	if not sec then
		return nil
	end
	local rec = normalize(read()[sec][name])
	return rec and rec.version or nil
end

--- Full record for a name ({ version, reftype, branch }), or nil.
---@param kind string
---@param name string
---@return table|nil
function M.get_full(kind, name)
	local sec = SECTION[kind]
	if not sec then
		return nil
	end
	return normalize(read()[sec][name])
end

--- Pin `name` to `version` in the active snapshot. reftype ∈ commit|tag|branch|version
--- (defaults: "version" for mason, "commit" for plugins).
---@param kind string
---@param name string
---@param version string
---@param reftype? string
---@param branch? string
---@return nil
function M.set(kind, name, version, reftype, branch)
	local sec = SECTION[kind]
	if not sec or not version or version == "" then
		return
	end
	reftype = reftype or (sec == "mason" and "version" or "commit")
	local entry = { [reftype] = version }
	if branch and branch ~= "" then
		entry.branch = branch
	end
	local data = read()
	data[sec][name] = entry
	write(data)
end

--- Remove a name's entry (= track latest).
---@param kind string
---@param name string
---@return nil
function M.unset(kind, name)
	local sec = SECTION[kind]
	if not sec then
		return
	end
	local data = read()
	if data[sec][name] ~= nil then
		data[sec][name] = nil
		write(data)
	end
end

--- All entries as kind → name → { version, reftype, branch } (for the installer).
---@return table<string, table<string, table>>
function M.all_full()
	local data = read()
	local out = { plugin = {}, mason = {} }
	for name, entry in pairs(data.plugins) do
		out.plugin[name] = normalize(entry)
	end
	for name, entry in pairs(data.mason) do
		out.mason[name] = normalize(entry)
	end
	return out
end

return M
