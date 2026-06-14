-- lvim-pkg: JSON-backed install state (no external dependency — no sqlite.lua).
-- One file (root/state.json) holds what is actually installed and what the user skipped:
--   receipts  name → { version, type, bins, installed_at }  (the real install: which
--             binaries a Mason package provided, its version, when — needed for PATH
--             linking and uninstall)
--   declines  [ { ft, name } ]  packages declined for a filetype
-- Version CHOICES (pins) are NOT here — they live in the switchable snapshot file
-- (see lvim-pkg.snapshot). receipts/declines are install STATE, not switchable.
--
---@module "lvim-pkg.db"

local paths = require("lvim-pkg.paths")

local M = {}

---@type { receipts: table, declines: table[] }|nil  loaded once, written through
local state = nil

---@return string
local function file()
    return paths.root() .. "/state.json"
end

--- Load the state file once (defaults to empty when absent or unreadable).
---@return { receipts: table, declines: table[] }
local function load()
    if state then
        return state
    end
    state = { receipts = {}, declines = {} }
    local f = io.open(file(), "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(vim.json.decode, content)
        if ok and type(data) == "table" then
            state.receipts = type(data.receipts) == "table" and data.receipts or {}
            state.declines = type(data.declines) == "table" and data.declines or {}
        end
    end
    return state
end

--- Persist the current state to disk.
local function save()
    if not state then
        return
    end
    paths.ensure()
    local ok, encoded = pcall(vim.json.encode, state)
    if not ok then
        return
    end
    local f = io.open(file(), "w")
    if f then
        f:write(encoded)
        f:close()
    end
end

-- ── receipts ──────────────────────────────────────────────────────────────────

--- Install receipt for a package, or nil.
---@param name string
---@return { name: string, version: string, type: string, bins: string[] }|nil
function M.receipt_get(name)
    local r = load().receipts[name]
    if not r then
        return nil
    end
    return { name = name, version = r.version, type = r.type, bins = r.bins or {} }
end

--- Upsert a package's install receipt.
---@param name string
---@param receipt { version?: string, type?: string, bins?: string[] }
---@return nil
function M.receipt_set(name, receipt)
    load().receipts[name] = {
        version = receipt.version,
        type = receipt.type,
        bins = receipt.bins or {},
        installed_at = os.time(),
    }
    save()
end

--- Remove a package's receipt.
---@param name string
---@return nil
function M.receipt_remove(name)
    if load().receipts[name] ~= nil then
        load().receipts[name] = nil
        save()
    end
end

--- Names of all packages with a receipt.
---@return string[]
function M.receipt_names()
    local out = {}
    for name in pairs(load().receipts) do
        out[#out + 1] = name
    end
    return out
end

-- ── declines ──────────────────────────────────────────────────────────────────

--- Record that `name` was declined for filetype `ft` (idempotent).
---@param ft string
---@param name string
---@return nil
function M.decline_add(ft, name)
    local d = load().declines
    for _, e in ipairs(d) do
        if e.ft == ft and e.name == name then
            return
        end
    end
    d[#d + 1] = { ft = ft, name = name }
    save()
end

--- Remove a decline (re-enable `name` for `ft`).
---@param ft string
---@param name string
---@return nil
function M.decline_remove(ft, name)
    local d = load().declines
    for i, e in ipairs(d) do
        if e.ft == ft and e.name == name then
            table.remove(d, i)
            save()
            return
        end
    end
end

--- Names declined for `ft`, as a set.
---@param ft string
---@return table<string, boolean>
function M.declines_for_ft(ft)
    local out = {}
    for _, e in ipairs(load().declines) do
        if e.ft == ft then
            out[e.name] = true
        end
    end
    return out
end

--- Every decline as a { ft, name } list.
---@return { ft: string, name: string }[]
function M.declines_all()
    local out = {}
    for _, e in ipairs(load().declines) do
        out[#out + 1] = { ft = e.ft, name = e.name }
    end
    return out
end

--- The store is always usable (plain file, no external dependency).
---@return boolean
function M.available()
    return true
end

return M
