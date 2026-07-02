-- lvim-pkg: Mason registry reader.
-- Loads the registry index (registry.json) and exposes package metadata for both
-- the installer and the control panel.  Fetches its OWN copy of the catalogue from
-- the mason-registry GitHub release (registry.json.zip) into root/registry.json, so
-- the data stays fresh WITHOUT mason.nvim.  Only the catalogue JSON is consumed —
-- never mason.nvim's runtime.
--
---@module "lvim-pkg.registry"

local config = require("lvim-pkg.config")
local paths = require("lvim-pkg.paths")
local purl = require("lvim-pkg.registry.purl")
local util = require("lvim-pkg.install.util")

local M = {}

local URL = "https://github.com/mason-org/mason-registry/releases/latest/download/registry.json.zip"

---@type table[]|nil          Decoded registry array
local cache = nil
---@type table<string, table>|nil  name → package spec
local index = nil
---@type table<string, string>|nil  bin name → owning package name
local bin_index = nil

--- Load and cache the registry array (empty table when no index is found).
---@param force? boolean  Re-read from disk
---@return table[]
function M.load(force)
    if cache and not force then
        return cache
    end
    cache, index, bin_index = {}, nil, nil
    local f = io.open(paths.registry_file(), "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(vim.json.decode, content)
        if ok and type(data) == "table" then
            cache = data
        end
    end
    return cache
end

--- True when the cache file exists and is younger than `config.registry_ttl` (a ttl of 0 or
--- less disables the age check, so any existing cache counts as fresh).
---@param path string
---@return boolean
local function fresh(path)
    local st = vim.uv.fs_stat(path)
    if not st then
        return false
    end
    local ttl = config.registry_ttl
    if type(ttl) ~= "number" or ttl <= 0 then
        return true
    end
    return (os.time() - st.mtime.sec) < ttl
end

--- Fetch the Mason registry (registry.json.zip from the latest release), extract it to our
--- own cache (root/registry.json), and reload. Fetches on first-run bootstrap (no cache),
--- when the cache is older than `config.registry_ttl`, or when `force` is set (the explicit
--- :LvimInstaller update-registry command). A fresh cache is used as-is; a failed fetch keeps
--- the old copy.
---@param cb? fun()
---@param force? boolean  Re-fetch now even if a fresh cache exists
---@return nil
function M.ensure(cb, force)
    cb = cb or function() end
    if not force and fresh(paths.registry_file()) then
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
