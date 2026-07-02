-- lvim-pkg: Mason-registry package backend (self-contained installer).
-- Resolves package metadata from the Mason registry index and installs via our
-- own engine (lvim-pkg.install) — no dependency on mason.nvim.  Install progress
-- is surfaced through an optional on_progress callback that lvim-installer renders.
-- `is_installed` counts ONLY our own install path; tools left over in an old
-- mason.nvim tree are not consulted (no migration — see the README).
--
---@module "lvim-pkg.backends.mason"

local registry = require("lvim-pkg.registry")
local install = require("lvim-pkg.install")
local config = require("lvim-pkg.config")
local snapshot = require("lvim-pkg.snapshot")

local B = { kind = "mason" }

--- Resolve the registry package name for a dep (generic bin → package lookup;
--- no hardcoded aliases).
---@param dep string
---@return string
local function pkg_name(dep)
    return registry.resolve(dep)
end
B.pkg_name = pkg_name

---@return string[]
function B.available()
    return registry.names()
end

---@return string[]
function B.installed()
    return install.installed()
end

---@param name string
---@return boolean
function B.is_installed(name)
    -- Only our own install path counts as installed (no mason.nvim tree lookup).
    return install.is_installed(pkg_name(name))
end

--- Install one or more registry packages via the own engine, at most
--- `config.max_concurrency` at a time (a worker pool, so a big batch does not fork dozens of
--- processes at once).
---@param names string[]
---@param cb? fun(results: table<string, string|true>)  name → true (ok) | error string
---@param opts? { on_progress?: fun(name: string, status: string, action: string) }
function B.install(names, cb, opts)
    opts = opts or {}
    local results = {}
    local total = #names
    if total == 0 then
        if cb then
            cb(results)
        end
        return
    end
    -- Mark the whole batch queued up front so the UI can show every pending row.
    if opts.on_progress then
        for _, name in ipairs(names) do
            opts.on_progress(name, "pending", "Queued...")
        end
    end
    local cap = math.max(1, config.max_concurrency or 4)
    local next_idx, done = 0, 0
    local function start_next()
        next_idx = next_idx + 1
        local name = names[next_idx]
        if not name then
            return
        end
        install.install(pkg_name(name), {
            on_progress = function(_, status, action)
                if opts.on_progress then
                    opts.on_progress(name, status, action)
                end
            end,
        }, function(err)
            if opts.on_progress then
                opts.on_progress(name, err and "fail" or "ok", err or "Installed")
            end
            results[name] = err and err or true
            done = done + 1
            if done == total then
                if cb then
                    cb(results)
                end
            else
                start_next() -- pull the next queued package into the freed slot
            end
        end)
    end
    for _ = 1, math.min(cap, total) do
        start_next()
    end
end

--- Update packages by reinstalling them — but ONLY the ones whose installed version differs
--- from the version that would be installed now (the active snapshot's pin, else the
--- catalogue's current version). Up-to-date packages are skipped (reported as ok) instead of
--- being recompiled/redownloaded for nothing.
---@param names string[]
---@param cb? fun(results: table<string, string|true>)
function B.update(names, cb)
    local stale, uptodate = {}, {}
    for _, name in ipairs(names) do
        local r = install.receipt(pkg_name(name))
        local pin = snapshot.get("mason", name)
        local src = registry.source(name)
        local target = (pin and pin ~= "") and pin or (src and src.version) or nil
        if r and r.version and target and r.version == target then
            uptodate[name] = true
        else
            stale[#stale + 1] = name
        end
    end
    B.install(stale, function(results)
        if cb then
            for name in pairs(uptodate) do
                results[name] = true
            end
            cb(results)
        end
    end)
end

--- Uninstall one or more packages.
---@param names string[]
---@param cb? fun(err: string|nil)
function B.remove(names, cb)
    -- err contract (nil on success, error string on failure) — matches the pack
    -- backend so callers can use a single `function(err)` callback.
    local err
    for _, name in ipairs(names) do
        local ok, e = pcall(install.remove, pkg_name(name))
        if not ok then
            err = tostring(e)
        end
    end
    if cb then
        cb(err)
    end
end

return B
