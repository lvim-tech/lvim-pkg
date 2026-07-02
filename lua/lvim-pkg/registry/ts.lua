-- lvim-pkg: tree-sitter parser registry reader.
-- Consumes the editor-agnostic treesitter-parser-registry (neovim-treesitter org)
-- — a community catalogue mapping language → parser repo + where its Neovim queries
-- live, explicitly designed for any installer to adopt. Fetched once via curl,
-- cached on disk with a TTL; a stale copy is used as fallback when a fetch fails.
-- This replaces nvim-treesitter as our source of parser/query metadata.
--
---@module "lvim-pkg.registry.ts"

local config = require("lvim-pkg.config")
local util = require("lvim-pkg.install.util")
local paths = require("lvim-pkg.paths")

local M = {}

local URL = "https://raw.githubusercontent.com/neovim-treesitter/treesitter-parser-registry/main/registry.json"

---@type table<string, table>|nil  lang → entry { filetypes, requires?, source }
local cache = nil
---@type table<string, string>|nil  filetype → lang
local ft_index = nil

--- Decode the on-disk registry into the in-memory caches. Returns success.
---@return boolean
local function load_file()
    local f = io.open(paths.ts_registry_file(), "r")
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

--- Load the registry from disk if present (synchronous, no fetch).
---@return boolean  loaded
function M.load()
    if cache then
        return true
    end
    return load_file()
end

--- True when the cache file exists and is younger than `config.registry_ttl` (a ttl of 0 or
--- less disables the age check, so any existing cache counts as fresh).
---@return boolean
local function fresh()
    local st = vim.uv.fs_stat(paths.ts_registry_file())
    if not st then
        return false
    end
    local ttl = config.registry_ttl
    if type(ttl) ~= "number" or ttl <= 0 then
        return true
    end
    return (os.time() - st.mtime.sec) < ttl
end

--- Ensure the registry is available. Fetches on first-run bootstrap (no cache on disk), when
--- the cache is older than `config.registry_ttl`, or when `force` is set (the explicit
--- :LvimInstaller update-registry command). A fresh cache is used as-is; a failed fetch falls
--- back to whatever copy is on disk.
---@param cb? fun()
---@param force? boolean  Re-fetch now even if a fresh cache exists
---@return nil
function M.ensure(cb, force)
    cb = cb or function() end
    if not force and fresh() then
        load_file() -- populate the in-memory cache from the fresh on-disk copy
        return cb()
    end
    paths.ensure()
    util.download(URL, paths.ts_registry_file(), function()
        load_file() -- loads the fresh download, or the existing copy if the download failed
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
