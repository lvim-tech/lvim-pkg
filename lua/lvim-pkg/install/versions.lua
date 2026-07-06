-- lvim-pkg: available-version queries for a Mason package's source.
-- Each ecosystem is asked for the package's full version list (newest first), so the
-- installer can offer all versions — not just the single one the Mason registry pins.
-- Network, async, best-effort: cb(nil) on any failure (the caller falls back to the
-- registry's latest). No external tools — plain HTTP via curl (lvim-pkg.install.util).
--
---@module "lvim-pkg.install.versions"

local util = require("lvim-pkg.install.util")

local M = {}

---@param path string
---@return table|nil
local function read_json(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    return ok and data or nil
end

--- Descending best-effort semver compare (newest first) on the numeric groups.
---@param a string
---@param b string
---@return boolean
local function newer(a, b)
    local function nums(v)
        local t = {}
        for n in tostring(v):gmatch("%d+") do
            t[#t + 1] = tonumber(n)
        end
        return t
    end
    local pa, pb = nums(a), nums(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then
            return x > y
        end
    end
    return tostring(a) > tostring(b)
end

---@param list string[]
---@return string[]
local function sorted(list)
    table.sort(list, newer)
    return list
end

--- Download `url` to a temp file; cb(path|nil).
---@param url string
---@param cb fun(path: string|nil)
local function fetch(url, cb)
    local tmp = vim.fn.tempname()
    util.download(url, tmp, function(err)
        cb(err and nil or tmp)
    end)
end

---@type table<string, fun(p: table, cb: fun(list: string[]|nil))>
local QUERY = {
    npm = function(p, cb)
        fetch("https://registry.npmjs.org/" .. p.name, function(path)
            local d = path and read_json(path)
            if type(d) ~= "table" or type(d.versions) ~= "table" then
                return cb(nil)
            end
            local out = {}
            for v in pairs(d.versions) do
                out[#out + 1] = v
            end
            cb(sorted(out))
        end)
    end,
    pypi = function(p, cb)
        fetch("https://pypi.org/pypi/" .. p.name .. "/json", function(path)
            local d = path and read_json(path)
            if type(d) ~= "table" or type(d.releases) ~= "table" then
                return cb(nil)
            end
            local out = {}
            for v in pairs(d.releases) do
                out[#out + 1] = v
            end
            cb(sorted(out))
        end)
    end,
    github = function(p, cb)
        fetch("https://api.github.com/repos/" .. p.name .. "/tags?per_page=100", function(path)
            local d = path and read_json(path)
            if type(d) ~= "table" then
                return cb(nil)
            end
            local out = {}
            for _, t in ipairs(d) do
                if type(t) == "table" and t.name then
                    out[#out + 1] = t.name
                end
            end
            cb(#out > 0 and sorted(out) or nil)
        end)
    end,
    cargo = function(p, cb)
        fetch("https://crates.io/api/v1/crates/" .. p.name, function(path)
            local d = path and read_json(path)
            if type(d) ~= "table" or type(d.versions) ~= "table" then
                return cb(nil)
            end
            local out = {}
            for _, v in ipairs(d.versions) do
                if type(v) == "table" and v.num then
                    out[#out + 1] = v.num
                end
            end
            cb(#out > 0 and out or nil) -- crates.io returns newest-first
        end)
    end,
    golang = function(p, cb)
        local escaped = p.name:gsub("%u", function(c)
            return "!" .. c:lower()
        end)
        fetch("https://proxy.golang.org/" .. escaped .. "/@v/list", function(path)
            local f = path and io.open(path, "r")
            if not f then
                return cb(nil)
            end
            local out = {}
            for line in f:lines() do
                if line ~= "" then
                    out[#out + 1] = line
                end
            end
            f:close()
            cb(#out > 0 and sorted(out) or nil)
        end)
    end,
}

--- Available versions for a parsed purl, newest first. cb(list) or cb(nil).
---@param p table|nil  parsed purl ({ type, name, … })
---@param cb fun(list: string[]|nil)
---@return nil
function M.fetch(p, cb)
    local q = p and QUERY[p.type]
    if not q then
        return cb(nil)
    end
    local ok = pcall(q, p, cb)
    if not ok then
        cb(nil)
    end
end

return M
