-- lvim-pkg: tree-sitter parser registry reader.
-- Consumes the editor-agnostic treesitter-parser-registry (neovim-treesitter org)
-- — a community catalogue mapping language → parser repo + where its Neovim queries
-- live, explicitly designed for any installer to adopt. Fetched once via curl,
-- cached on disk with a TTL; a stale copy is used as fallback when a fetch fails.
-- This replaces nvim-treesitter as our source of parser/query metadata.
--
---@module "lvim-pkg.registry.ts"

local util = require("lvim-pkg.install.util")
local paths = require("lvim-pkg.paths")
local config = require("lvim-pkg.config")

local M = {}

local URL = "https://raw.githubusercontent.com/neovim-treesitter/treesitter-parser-registry/main/registry.json"

---@type table<string, table>|nil  lang → entry { filetypes, requires?, source }
local cache = nil
---@type table<string, string>|nil  filetype → lang
local ft_index = nil

---@return string
local function cache_path()
	return paths.root() .. "/ts-registry.json"
end

--- Decode the on-disk registry into the in-memory caches. Returns success.
---@return boolean
local function load_file()
	local f = io.open(cache_path(), "r")
	if not f then
		return false
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	if not (ok and type(data) == "table") then
		return false
	end
	cache = {}
	ft_index = {}
	-- Keep only real parser entries (skip metadata keys like "$schema").
	for lang, entry in pairs(data) do
		if type(entry) == "table" and type(entry.source) == "table" then
			cache[lang] = entry
			for _, ft in ipairs(entry.filetypes or {}) do
				ft_index[ft] = ft_index[ft] or lang
			end
		end
	end
	return true
end

--- True when a cached registry exists and is younger than the configured TTL.
---@return boolean
local function fresh()
	local stat = vim.uv.fs_stat(cache_path())
	local ttl = config.registry_ttl or (7 * 24 * 60 * 60)
	return stat ~= nil and (os.time() - stat.mtime.sec) < ttl
end

--- Load the registry from disk if present (synchronous, no fetch).
---@return boolean  loaded
function M.load()
	if cache then
		return true
	end
	return load_file()
end

--- Ensure the registry is available, fetching it when missing or stale (or when
--- `force` is set — used by the manual update command). A failed fetch falls back to
--- the stale on-disk copy. When auto-update is disabled and not forced, the existing
--- cache is used as-is without a fetch.
---@param cb? fun()
---@param force? boolean  Ignore the TTL and the update_registry gate, re-fetch now
---@return nil
function M.ensure(cb, force)
	cb = cb or function() end
	if cache and fresh() and not force then
		return cb()
	end
	if fresh() and not force then
		load_file()
		return cb()
	end
	if not force and not config.update_registry then
		load_file() -- auto-update off: use whatever cache exists
		return cb()
	end
	paths.ensure()
	util.download(URL, cache_path(), function()
		load_file() -- loads the fresh download, or the stale copy if the download failed
		cb()
	end)
end

--- Every language name in the registry.
---@return string[]
function M.names()
	M.load()
	local out = {}
	for lang in pairs(cache or {}) do
		out[#out + 1] = lang
	end
	table.sort(out)
	return out
end

--- The registry entry for a language, or nil.
---@param lang string
---@return table|nil
function M.get(lang)
	M.load()
	return (cache or {})[lang]
end

--- Resolve a filetype to its parser language (falls back to the filetype itself).
---@param ft string
---@return string
function M.lang_for_ft(ft)
	M.load()
	return (ft_index or {})[ft] or ft
end

return M
