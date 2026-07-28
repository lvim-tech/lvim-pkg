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

--- Merge `config.extra_parsers` over whatever the catalogue provided. A language the community
--- registry does not carry is otherwise uninstallable through this engine, and forking the
--- catalogue for one entry would mean maintaining 300 someone else already maintains. The entries
--- use the registry's OWN shape, so nothing downstream can tell them apart — and they WIN a name
--- collision, because an explicit local entry is a deliberate statement about that language.
---@return integer added
local function apply_extra()
    cache = cache or {}
    ft_index = ft_index or {}
    local added = 0
    for lang, entry in pairs(config.extra_parsers or {}) do
        if type(entry) == "table" and type(entry.source) == "table" then
            cache[lang] = entry
            for _, ft in ipairs(entry.filetypes or {}) do
                ft_index[ft] = lang
            end
            added = added + 1
        end
    end
    return added
end

--- Decode the on-disk registry into the in-memory caches. Returns success.
---@return boolean
local function load_file()
    local f = io.open(paths.ts_registry_file(), "r")
    if not f then
        -- No catalogue on disk yet. The configured extras are still installable — they need no
        -- download of their own — so this is a partial load rather than a failure.
        return apply_extra() > 0
    end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    if not (ok and type(data) == "table") then
        return apply_extra() > 0
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
    -- After the catalogue, never before: the extras are meant to override it.
    apply_extra()
    return true
end

--- Drop the decoded catalogue. The next read re-decodes the on-disk copy and re-merges the
--- configured extras — no download, so this is cheap enough to call from a plugin's setup.
---@return nil
function M.invalidate()
    cache = nil
    ft_index = nil
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
        if not cache then
            load_file() -- populate the in-memory cache from the fresh on-disk copy
        end
        return cb()
    end
    paths.ensure()
    local tmp = vim.fn.tempname()
    util.download(URL, tmp, function(err)
        if not err then
            local f = io.open(tmp, "r")
            local content = f and f:read("*a") or nil
            if f then
                f:close()
            end
            local ok, data = false, nil
            if content then
                ok, data = pcall(vim.json.decode, content)
            end
            if ok and type(data) == "table" then
                -- COPY (not rename): tempname() is on tmpfs and the data dir is often a different filesystem,
                -- so fs_rename fails EXDEV and the catalogue never updates. The tmp is deleted just below.
                pcall(vim.uv.fs_copyfile, tmp, paths.ts_registry_file())
                cache, ft_index = nil, nil
            end
        end
        pcall(vim.fn.delete, tmp)
        load_file() -- loads the fresh validated download, or keeps the existing copy on error
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
