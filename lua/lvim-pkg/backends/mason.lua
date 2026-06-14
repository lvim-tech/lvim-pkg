-- lvim-pkg: Mason-registry package backend (self-contained installer).
-- Resolves package metadata from the Mason registry index and installs via our
-- own engine (lvim-pkg.install) — no dependency on mason.nvim.  Install progress
-- is surfaced through an optional on_progress callback that lvim-installer renders.
--
-- Transition note: is_installed also recognises tools still present in the old
-- mason.nvim bin directory, so already-installed tools are not re-offered while
-- migrating.
--
---@module "lvim-pkg.backends.mason"

local registry = require("lvim-pkg.registry")
local install = require("lvim-pkg.install")

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
    -- Only our own install path counts as installed. Tools that exist solely in the
    -- legacy mason.nvim tree are offered as fresh installs (no migration).
    return install.is_installed(pkg_name(name))
end

--- Install one or more registry packages in parallel via the own engine.
---@param names string[]
---@param cb? fun(results: table<string, string|true>)  name → true (ok) | error string
---@param opts? { on_progress?: fun(name: string, status: string, action: string) }
function B.install(names, cb, opts)
    opts = opts or {}
    local results = {}
    local remaining = #names
    if remaining == 0 then
        if cb then
            cb(results)
        end
        return
    end
    for _, name in ipairs(names) do
        if opts.on_progress then
            opts.on_progress(name, "pending", "Queued...")
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
            remaining = remaining - 1
            if remaining == 0 and cb then
                cb(results)
            end
        end)
    end
end

--- Update packages by reinstalling them (the engine always installs fresh).
---@param names string[]
---@param cb? fun(results: table<string, string|true>)
function B.update(names, cb)
    B.install(names, cb)
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
