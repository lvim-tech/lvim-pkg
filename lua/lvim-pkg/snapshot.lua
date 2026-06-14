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

--- The snapshots directory (holds the snapshot files + the `active` marker).
---@return string
function M.dir()
    if type(config.snapshot_dir) == "string" and config.snapshot_dir ~= "" then
        return config.snapshot_dir
    end
    return vim.fn.stdpath("config") .. "/.snapshots"
end

--- Name of the active snapshot (from <dir>/active), defaulting to "default".
---@return string
function M.active()
    local f = io.open(M.dir() .. "/active", "r")
    if f then
        local name = vim.trim(f:read("*a") or "")
        f:close()
        if name ~= "" then
            return name
        end
    end
    return "default"
end

--- Available snapshot names (every file in the dir except the `active` marker).
---@return string[]
function M.list()
    local out = {}
    local d = M.dir()
    if vim.fn.isdirectory(d) == 1 then
        for name, t in vim.fs.dir(d) do
            if t == "file" and name ~= "active" then
                out[#out + 1] = name
            end
        end
    end
    table.sort(out)
    return out
end

--- Set the active snapshot (writes <dir>/active). Switches the whole version set.
---@param name string
---@return boolean
function M.select(name)
    local d = M.dir()
    vim.fn.mkdir(d, "p")
    local f = io.open(d .. "/active", "w")
    if not f then
        return false
    end
    f:write(name)
    f:close()
    return true
end

--- Absolute path of the active snapshot file.
---@return string
local function path()
    return M.dir() .. "/" .. M.active()
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

--- Normalize a raw entry to { version, reftype, branch, pinned }. `pinned` is true only
--- when the entry was written by an explicit user pin (entry.pin == true); plain commits
--- recorded for reproducibility (e.g. a lazy-lock-style snapshot) are not pins.
---@param entry table|nil
---@return { version: string, reftype: string, branch: string|nil, pinned: boolean }|nil
local function normalize(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local pinned = entry.pin == true
    if entry.commit then
        return { version = entry.commit, reftype = "commit", branch = entry.branch, pinned = pinned }
    elseif entry.tag then
        return { version = entry.tag, reftype = "tag", branch = entry.branch, pinned = pinned }
    elseif entry.branch then
        return { version = entry.branch, reftype = "branch", pinned = pinned }
    elseif entry.version then
        return { version = entry.version, reftype = "version", pinned = pinned }
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
--- (defaults: "version" for mason, "commit" for plugins). `explicit` records an explicit
--- user pin (entry.pin == true), which is what the installer markers reflect; reproducibility
--- writes leave it false so the recorded commit alone does not count as a pin.
---@param kind string
---@param name string
---@param version string
---@param reftype? string
---@param branch? string
---@param explicit? boolean
---@return nil
function M.set(kind, name, version, reftype, branch, explicit)
    local sec = SECTION[kind]
    if not sec or not version or version == "" then
        return
    end
    reftype = reftype or (sec == "mason" and "version" or "commit")
    local entry = { [reftype] = version }
    if branch and branch ~= "" then
        entry.branch = branch
    end
    if explicit then
        entry.pin = true
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

--- Write a full version set to a named snapshot file in the snapshots dir (creating it).
--- `data` is { plugins = {name = entry}, mason = {name = entry} }; used by snapshot_save
--- to materialise the current state as a reusable snapshot.
---@param name string
---@param data table
---@return boolean
function M.write_file(name, data)
    if not name or name == "" or name == "active" then
        return false
    end
    local d = M.dir()
    vim.fn.mkdir(d, "p")
    data.plugins = data.plugins or {}
    data.mason = data.mason or {}
    local f = io.open(d .. "/" .. name, "w")
    if not f then
        return false
    end
    f:write(pretty(data))
    f:close()
    return true
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
