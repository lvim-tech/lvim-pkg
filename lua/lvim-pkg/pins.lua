-- lvim-pkg: version pins. A pin is an explicit, user-chosen version of a plugin or Mason
-- package, recorded in the active snapshot file (see lvim-pkg.snapshot) with an explicit
-- pin flag. Installing "latest" leaves no pin (= track latest); installing a specific
-- version writes one. Plain commits recorded for reproducibility (e.g. a lazy-lock-style
-- snapshot) are NOT pins and are not reported here — only the host loader and snapshot
-- diff/restore read the full version set straight from lvim-pkg.snapshot.
-- Parsers are not versioned, so their pin operations are no-ops. This module is a thin,
-- stable façade over lvim-pkg.snapshot for the installer.
--
---@module "lvim-pkg.pins"

local snapshot = require("lvim-pkg.snapshot")

local M = {}

--- The explicitly-pinned version for a name, or nil (= not pinned / track latest).
--- A plain reproducibility commit is not a pin, so it returns nil here.
---@param kind string
---@param name string
---@return string|nil
function M.get(kind, name)
    local rec = snapshot.get_full(kind, name)
    return (rec and rec.pinned) and rec.version or nil
end

--- Record `name` (of `kind`) at `version` as an explicit pin in the active snapshot.
---@param kind string
---@param name string
---@param version string
---@param reftype? string
---@param branch? string
---@return nil
function M.set(kind, name, version, reftype, branch)
    snapshot.set(kind, name, version, reftype, branch, true)
end

--- Full record ({ version, reftype, branch, pinned }) for an explicit pin, or nil.
---@param kind string
---@param name string
---@return table|nil
function M.get_full(kind, name)
    local rec = snapshot.get_full(kind, name)
    return (rec and rec.pinned) and rec or nil
end

--- Remove a name's entry (= track latest).
---@param kind string
---@param name string
---@return nil
function M.unset(kind, name)
    snapshot.unset(kind, name)
end

--- All explicit pins as kind → name → version.
---@return table<string, table<string, string>>
function M.all()
    local out = {}
    for kind, names in pairs(snapshot.all_full()) do
        out[kind] = {}
        for name, rec in pairs(names) do
            if rec.pinned then
                out[kind][name] = rec.version
            end
        end
    end
    return out
end

--- All explicit pins with full records (kind → name → { version, reftype, branch, pinned }).
---@return table<string, table<string, table>>
function M.all_full()
    local out = {}
    for kind, names in pairs(snapshot.all_full()) do
        out[kind] = {}
        for name, rec in pairs(names) do
            if rec.pinned then
                out[kind][name] = rec
            end
        end
    end
    return out
end

return M
