-- lvim-pkg: public API entry point — the single data + operations hub.
-- Provides a uniform interface over three backends (Mason binaries, treesitter
-- parsers, vim.pack plugins) plus a requirement registry that lets domain
-- plugins (lvim-lsp, lvim-ts) declare what a filetype needs.  No UI — that is
-- the concern of lvim-installer.
--
---@module "lvim-pkg"

local state = require("lvim-pkg.state")
local loader = require("lvim-pkg.loader")
local pins = require("lvim-pkg.pins")
local data = require("lvim-pkg.data")
local cli = require("lvim-pkg.core.cli")
local db = require("lvim-pkg.db")
local registry = require("lvim-pkg.registry")
local registry_ts = require("lvim-pkg.registry.ts")

local M = {}

---@type table<string, table>  kind → backend module
local backends = {
    mason = require("lvim-pkg.backends.mason"),
    parser = require("lvim-pkg.backends.ts"),
    plugin = require("lvim-pkg.backends.pack"),
}

--- Resolve a backend by kind, or nil when unknown.
---@param kind string
---@return table|nil
function M.backend(kind)
    return backends[kind]
end

--- Configure lvim-pkg.  Optionally ensures the tree-sitter CLI is present.
---@param opts? LvimPkgConfig
---@return nil
function M.setup(opts)
    local config = require("lvim-pkg.config")
    -- Merge user overrides into the live config (in place, so require()ers see them).
    for k, v in pairs(opts or {}) do
        if type(v) == "table" and type(config[k]) == "table" then
            config[k] = vim.tbl_deep_extend("force", config[k], v)
        else
            config[k] = v
        end
    end
    -- Make our installer's bin directory available to spawned tools/LSP servers.
    local paths = require("lvim-pkg.paths")
    paths.ensure()
    paths.ensure_path()
    -- Put our parser/query dir on the rtp and kick off the ts registry refresh.
    backends.parser.ensure_install_dir()
    -- Silently refresh the Mason catalogue (TTL-gated; no-op when fresh / disabled).
    registry.ensure()
    if config.ensure_cli then
        cli.ensure(function() end)
    end
end

-- ── Uniform backend operations ────────────────────────────────────────────────

--- Names the backend is able to install.
---@param kind string
---@return string[]
function M.available(kind)
    local b = backends[kind]
    return b and b.available() or {}
end

--- Names the backend has installed.
---@param kind string
---@return string[]
function M.installed(kind)
    local b = backends[kind]
    return b and b.installed() or {}
end

---@param kind string
---@param name string
---@return boolean
function M.is_installed(kind, name)
    local b = backends[kind]
    return b ~= nil and b.is_installed(name)
end

--- Whether a package is installed in our managed path (has our receipt).
---@param name string
---@return boolean
function M.is_managed(name)
    local ok, install = pcall(require, "lvim-pkg.install")
    return ok and install.is_installed(name) or false
end

--- Install directory of a package, under our managed root.
---@param name string
---@return string
function M.package_path(name)
    return require("lvim-pkg.paths").package_dir(name)
end

--- Plugin pin-menu git data (cascading: tags by branch, commits by ref).
---@param name string
---@return string[]
function M.plugin_branches(name)
    return loader.plugin_branches(name)
end

---@param name string
---@return string|nil
function M.plugin_default_branch(name)
    return loader.plugin_default_branch(name)
end

---@param name string
---@return { kind: string, value: string }|nil
function M.plugin_current(name)
    return loader.plugin_current(name)
end

---@param name string
---@return string|nil
function M.plugin_newest_tag(name)
    return loader.plugin_newest_tag(name)
end

---@param name string
---@param prefix string
---@return string|nil
function M.plugin_resolve_tag(name, prefix)
    return loader.plugin_resolve_tag(name, prefix)
end

---@param name string
---@param branch string
---@return string|nil
function M.plugin_branch_tip(name, branch)
    return loader.plugin_branch_tip(name, branch)
end

---@param name string
---@param cb? fun()
---@return nil
function M.plugin_fetch(name, cb)
    return loader.plugin_fetch(name, cb)
end

---@param name string
---@param ref string
---@return string|nil
function M.plugin_checkout(name, ref)
    return loader.plugin_checkout(name, ref)
end

---@param name string
---@param branch string
---@return string|nil
function M.plugin_update_branch(name, branch)
    return loader.plugin_update_branch(name, branch)
end

---@param name string
---@param branch? string
---@return string[]
function M.plugin_tags(name, branch)
    -- `branch` is accepted for API symmetry but ignored: tags are not branch-scoped.
    local _ = branch
    return loader.plugin_tags(name)
end

---@param name string
---@param ref? string
---@return string[]
function M.plugin_commits(name, ref)
    return loader.plugin_commits(name, ref)
end

--- The recorded version of an installed Mason package, or nil when unknown.
---@param name string
---@return string|nil
function M.installed_version(name)
    local ok, install = pcall(require, "lvim-pkg.install")
    if ok then
        local r = install.receipt(name)
        if r and r.version then
            return r.version
        end
    end
    return nil
end

--- Available versions of a package (newest first), queried from its source. Currently
--- only Mason packages are versioned this way (plugins use git refs, parsers have no
--- version). Async; cb(list) or cb(nil) on failure.
---@param kind string
---@param name string
---@param cb fun(list: string[]|nil)
---@return nil
function M.available_versions(kind, name, cb)
    if kind ~= "mason" then
        return cb(nil)
    end
    local ok, install = pcall(require, "lvim-pkg.install")
    if not ok then
        return cb(nil)
    end
    install.versions(name, cb)
end

--- Install items via the backend for `kind`.  Argument shapes are
--- backend-specific (Mason/parser take names, plugin takes vim.pack specs).
---@param kind  string
---@param items table[]|string[]
---@param cb?   function
---@param opts? table
---@return nil
function M.install(kind, items, cb, opts)
    local b = backends[kind]
    if not b then
        if cb then
            cb(nil)
        end
        return
    end
    b.install(items, cb, opts)
end

---@param kind  string
---@param names? string[]
---@param cb?   function
---@return nil
function M.update(kind, names, cb)
    local b = backends[kind]
    if not b then
        if cb then
            cb(nil)
        end
        return
    end
    b.update(names, cb)
end

---@param kind  string
---@param names string[]
---@param cb?   function
---@return nil
function M.remove(kind, names, cb)
    local b = backends[kind]
    if not b then
        if cb then
            cb(nil)
        end
        return
    end
    b.remove(names, cb)
end

-- ── Plugin introspection (reported by the host loader) ────────────────────────

--- Register the full plugin set (static spec info). Host loader calls this once.
---@param map table<string, LvimPkgPluginReg>
---@return nil
function M.register_plugins(map)
    loader.register(map)
end

--- Record that a plugin loaded. Host loader calls this on each load.
---@param name string
---@param reason string
---@param time_ms number
---@return nil
function M.record_load(name, reason, time_ms)
    loader.record(name, reason, time_ms)
end

--- Rich info for every known plugin (load time, reason, path, version, deps…).
---@return table[]
function M.plugins()
    return loader.plugins()
end

--- Rich info for one plugin, or nil.
---@param name string
---@return table|nil
function M.plugin_info(name)
    return loader.info(name)
end

--- Loaded/total plugin counts (for the dashboard startup stat).
---@return { loaded: integer, total: integer }
function M.plugin_stats()
    return loader.stats()
end

--- Asynchronously check which plugins have an upstream update available.
---@param cb? fun(outdated_names: string[])
---@param on_progress? fun(done: integer, total: integer)
---@return nil
function M.check_outdated(cb, on_progress)
    loader.check_outdated(cb, on_progress)
end

--- The grammar revision an installed parser was built at, or nil when unknown.
---@param lang string
---@return string|nil
function M.parser_installed_version(lang)
    return backends.parser.installed_version(lang)
end

--- Whether the last parser check found `lang` behind the registry's current version.
---@param lang string
---@return boolean
function M.parser_outdated(lang)
    return backends.parser.is_outdated(lang)
end

--- Asynchronously check which installed parsers are behind the registry's current
--- versions (the parser equivalent of check_outdated).
---@param cb? fun(outdated_names: string[])
---@param on_progress? fun(done: integer, total: integer)
---@return nil
function M.check_parsers_outdated(cb, on_progress)
    backends.parser.check_outdated(cb, on_progress)
end

--- Asynchronously read git tags for plugins (commit/branch are cheap; tag needs git).
---@param cb? fun()
---@return nil
function M.load_tags(cb)
    loader.load_tags(cb)
end

--- Cached recent git-log lines for a plugin (nil until load_git_log has run).
---@param name string
---@return string[]|nil
function M.git_log(name)
    return loader.git_log(name)
end

--- Asynchronously read the recent git log for one plugin (cached).
---@param name string
---@param cb? fun(lines: string[])
---@return nil
function M.load_git_log(name, cb)
    loader.load_git_log(name, cb)
end

-- ── Requirement registry ──────────────────────────────────────────────────────

--- Register a provider that maps a filetype to the items it needs installed.
--- Called by domain plugins (lvim-lsp, lvim-ts) during their setup.
---@param name string
---@param fn fun(ft: string): LvimPkgItem[]
---@return nil
function M.register_provider(name, fn)
    state.providers[name] = fn
end

--- Subscribe to an installer event (decoupling — domains never get called directly).
--- Events: "installing" (active: boolean).
---@param event string
---@param fn fun(...)
function M.on(event, fn)
    state.hooks[event] = state.hooks[event] or {}
    table.insert(state.hooks[event], fn)
end

--- Fire all subscribers of an installer event.
---@param event string
function M.emit(event, ...)
    for _, fn in ipairs(state.hooks[event] or {}) do
        pcall(fn, ...)
    end
end

--- Aggregate every provider's missing items for `ft` (for the unified prompt).
---@param ft string
---@return LvimPkgItem[]
function M.missing_for_ft(ft)
    return data.missing_for_ft(ft)
end

-- ── Version pins ──────────────────────────────────────────────────────────────

--- Pin `name` (of `kind`) to a specific version/commit (applied on next install).
---@param kind string
---@param name string
---@param version string
---@return nil
function M.pin(kind, name, version, reftype, branch)
    pins.set(kind, name, version, reftype, branch)
end

--- Full pin record (version + reftype tag|branch + branch context), or nil.
---@param kind string
---@param name string
---@return { version: string, reftype: string|nil, branch: string|nil }|nil
function M.get_pin_full(kind, name)
    return pins.get_full(kind, name)
end

--- All pins of a kind with full records (one query), or empty.
---@param kind string
---@return table<string, table>
function M.pins_full(kind)
    return pins.all_full()[kind] or {}
end

--- Remove a pin.
---@param kind string
---@param name string
---@return nil
function M.unpin(kind, name)
    pins.unset(kind, name)
end

--- The pinned version for `name`, or nil.
---@param kind string
---@param name string
---@return string|nil
function M.get_pin(kind, name)
    return pins.get(kind, name)
end

--- All pins (kind → name → version).
---@return table<string, table<string, string>>
function M.pins()
    return pins.all()
end

-- ── snapshots (switchable version sets) ───────────────────────────────────────

--- Available snapshot names.
---@return string[]
function M.snapshots()
    return require("lvim-pkg.snapshot").list()
end

--- The active snapshot name.
---@return string
function M.active_snapshot()
    return require("lvim-pkg.snapshot").active()
end

--- Make `name` the active snapshot (switches the whole version set).
---@param name string
---@return boolean
function M.select_snapshot(name)
    return require("lvim-pkg.snapshot").select(name)
end

--- Capture the current state into a named snapshot file: each installed plugin's live
--- git HEAD and each Mason package's installed version. Explicit pins from the active
--- snapshot are carried over (kept flagged); everything else is a plain reproducibility
--- record. Overwrites an existing file of the same name.
---@param name string
---@return boolean ok, string? err
function M.snapshot_save(name)
    if not name or name == "" then
        return false, "snapshot name required"
    end
    local snap = require("lvim-pkg.snapshot")
    local active = require("lvim-pkg.pins").all_full()
    local data = { plugins = {}, mason = {} }
    for _, info in ipairs(M.plugins()) do
        local commit
        if info.path then
            local head = vim.trim(vim.fn.system({ "git", "-C", info.path, "rev-parse", "HEAD" }))
            if vim.v.shell_error == 0 and head ~= "" then
                commit = head
            end
        end
        commit = commit or (info.commit ~= "" and info.commit or nil)
        if commit then
            local entry = { commit = commit }
            if active.plugin[info.name] then
                entry.pin = true
            end
            data.plugins[info.name] = entry
        end
    end
    local ok, install = pcall(require, "lvim-pkg.install")
    if ok then
        for _, mname in ipairs(install.installed()) do
            local v = M.installed_version(mname)
            if v and v ~= "" then
                local entry = { version = v }
                if active.mason[mname] then
                    entry.pin = true
                end
                data.mason[mname] = entry
            end
        end
    end
    if not snap.write_file(name, data) then
        return false, "could not write snapshot file"
    end
    return true
end

--- What restoring the active snapshot would change — only entries whose currently
--- installed version differs from the snapshot's pinned version (latest entries are
--- left alone). Shape: { plugins = { {name, from, to} }, mason = { {name, from, to} } }.
---@return { plugins: table[], mason: table[] }
function M.snapshot_diff()
    local snap = require("lvim-pkg.snapshot")
    local out = { plugins = {}, mason = {} }
    for _, info in ipairs(M.plugins()) do
        local to = snap.get("plugin", info.name)
        local cur = info.commit
        if to and to ~= "" and cur and cur ~= "" and not vim.startswith(to, cur) and not vim.startswith(cur, to) then
            out.plugins[#out.plugins + 1] = { name = info.name, from = cur, to = to }
        end
    end
    local ok, install = pcall(require, "lvim-pkg.install")
    if ok then
        for _, name in ipairs(install.installed()) do
            local to = snap.get("mason", name)
            local cur = M.installed_version(name)
            if to and to ~= "" and to ~= cur then
                out.mason[#out.mason + 1] = { name = name, from = cur, to = to }
            end
        end
    end
    return out
end

--- Apply a snapshot diff: check out the pinned commit for each changed plugin (the
--- running Lua keeps the old code until a restart) and reinstall each changed Mason
--- package at its pinned version. `on_progress(kind, name, action)` is optional.
---@param diff { plugins: table[], mason: table[] }
---@param cb? fun()
---@param on_progress? fun(kind: string, name: string, action: string)
---@return nil
function M.snapshot_restore(diff, cb, on_progress)
    cb = cb or function() end
    for _, p in ipairs(diff.plugins or {}) do
        if on_progress then
            on_progress("plugin", p.name, "checkout")
        end
        M.plugin_checkout(p.name, p.to)
    end
    local names = {}
    for _, m in ipairs(diff.mason or {}) do
        names[#names + 1] = m.name
    end
    if #names == 0 then
        return cb()
    end
    M.install("mason", names, function()
        cb()
    end, {
        on_progress = on_progress and function(name, _, action)
            on_progress("mason", name, action)
        end or nil,
    })
end

-- ── Declines (per-filetype "do not offer these packages again") ───────────────

--- Decline `names` for filetype `ft`: the unified prompt stops offering them and
--- `missing_for_ft` filters them out.
---@param ft string
---@param names string[]
---@return nil
function M.decline(ft, names)
    for _, name in ipairs(names) do
        db.decline_add(ft, name)
    end
end

--- Re-enable a previously declined package for `ft`.
---@param ft string
---@param name string
---@return nil
function M.undecline(ft, name)
    db.decline_remove(ft, name)
end

--- Every decline as a { ft, name } list (for the management menu).
---@return { ft: string, name: string }[]
function M.declined()
    return db.declines_all()
end

-- ── Registry refresh ──────────────────────────────────────────────────────────

--- Refresh registry catalogues. With `force` (the manual command) it re-downloads now;
--- without it (the on-open / setup path) it only fetches on first-run bootstrap when the
--- cache is missing — there is no periodic refresh, so catalogues update only on demand.
---@param which? "mason"|"ts"|"all"  Default "all"
---@param cb? fun()
---@param force? boolean
---@return nil
function M.update_registry(which, cb, force)
    which = which or "all"
    cb = cb or function() end
    local pending = 0
    local function done()
        pending = pending - 1
        if pending <= 0 then
            cb()
        end
    end
    if which == "mason" or which == "all" then
        pending = pending + 1
        registry.ensure(done, force)
    end
    if which == "ts" or which == "all" then
        pending = pending + 1
        registry_ts.ensure(done, force)
    end
    if pending == 0 then
        cb()
    end
end

return M
