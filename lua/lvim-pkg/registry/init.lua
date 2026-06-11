-- lvim-pkg: Mason registry reader.
-- Loads the registry index (registry.json) and exposes package metadata for both
-- the installer and the control panel.  Fetches its own copy from the mason-registry
-- GitHub release (registry.json.zip) so the catalogue stays fresh WITHOUT mason.nvim;
-- falls back to the copy mason.nvim may already have downloaded, then to a stale copy.
--
---@module "lvim-pkg.registry"

local paths = require("lvim-pkg.paths")
local purl = require("lvim-pkg.registry.purl")
local util = require("lvim-pkg.install.util")
local config = require("lvim-pkg.config")

local M = {}

local URL = "https://github.com/mason-org/mason-registry/releases/latest/download/registry.json.zip"

---@type table[]|nil          Decoded registry array
local cache = nil
---@type table<string, table>|nil  name → package spec
local index = nil
---@type table<string, string>|nil  bin name → owning package name
local bin_index = nil

--- Candidate registry index locations, in priority order.
---@return string[]
local function candidates()
	return {
		paths.registry_file(),
		vim.fn.stdpath("data") .. "/mason/registries/github/mason-org/mason-registry/registry.json",
	}
end

--- Load and cache the registry array (empty table when no index is found).
---@param force? boolean  Re-read from disk
---@return table[]
function M.load(force)
	if cache and not force then
		return cache
	end
	cache, index, bin_index = {}, nil, nil
	for _, path in ipairs(candidates()) do
		local f = io.open(path, "r")
		if f then
			local content = f:read("*a")
			f:close()
			local ok, data = pcall(vim.json.decode, content)
			if ok and type(data) == "table" then
				cache = data
				break
			end
		end
	end
	return cache
end

--- True when our cached registry.json is younger than the configured TTL.
---@return boolean
local function fresh()
	local stat = vim.uv.fs_stat(paths.registry_file())
	local ttl = config.registry_ttl or (7 * 24 * 60 * 60)
	return stat ~= nil and (os.time() - stat.mtime.sec) < ttl
end

--- Fetch the Mason registry (registry.json.zip from the latest release), extract it to
--- our own cache (root/registry.json), and reload. Skips the fetch when the cache is
--- fresh, or when auto-update is off (unless `force`). A failed fetch keeps the old copy.
---@param cb? fun()
---@param force? boolean  Ignore the TTL and the update_registry gate, re-fetch now
---@return nil
function M.ensure(cb, force)
	cb = cb or function() end
	if fresh() and not force then
		return cb()
	end
	if not force and not config.update_registry then
		return cb()
	end
	paths.ensure()
	local tmp = vim.fn.tempname()
	vim.fn.mkdir(tmp, "p")
	local zip = tmp .. "/registry.json.zip"
	util.download(URL, zip, function(err)
		if err then
			return cb() -- keep the existing cache
		end
		util.extract(zip, tmp, function(e2)
			if not e2 and vim.fn.filereadable(tmp .. "/registry.json") == 1 then
				pcall(vim.uv.fs_copyfile, tmp .. "/registry.json", paths.registry_file())
				M.load(true) -- reload from the fresh cache
			end
			cb()
		end)
	end)
end

--- All package specs.
---@return table[]
function M.all()
	return M.load()
end

--- Every package name in the registry.
---@return string[]
function M.names()
	local names = {}
	for _, p in ipairs(M.load()) do
		names[#names + 1] = p.name
	end
	return names
end

--- Look up a package spec by name.
---@param name string
---@return table|nil
function M.get(name)
	if not index then
		-- Load first: M.load() resets `index`, so build the map afterwards.
		local all = M.load()
		index = {}
		for _, p in ipairs(all) do
			index[p.name] = p
		end
	end
	return index[name]
end

--- Resolve a dependency name to its registry package name.
--- Accepts either a package name (returned as-is) or a binary/tool name owned by
--- a package (resolved via a generic bin → package index — no hardcoded aliases).
---@param dep string
---@return string
function M.resolve(dep)
	if M.get(dep) then
		return dep
	end
	if not bin_index then
		bin_index = {}
		for _, p in ipairs(M.load()) do
			for binname in pairs(p.bin or {}) do
				if not bin_index[binname] then
					bin_index[binname] = p.name
				end
			end
		end
	end
	return bin_index[dep] or dep
end

--- Parsed purl for a package's source id.
---@param name string
---@return LvimPkgPurl|nil
function M.source(name)
	local spec = M.get(name)
	if not spec or not spec.source then
		return nil
	end
	return purl.parse(spec.source.id)
end

return M
