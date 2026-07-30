-- lvim-pkg: public API entry point — the single data + operations hub.
-- Provides a uniform interface over three backends (Mason binaries, treesitter
-- parsers, vim.pack plugins) plus a requirement registry that lets domain
-- plugins (lvim-lsp, lvim-ts) declare what a filetype needs.  No UI — that is
-- the concern of lvim-installer.
--
---@module "lvim-pkg"

local config = require("lvim-pkg.config")
local paths = require("lvim-pkg.paths")
local state = require("lvim-pkg.state")
local loader = require("lvim-pkg.loader")
local pins = require("lvim-pkg.pins")
local data = require("lvim-pkg.data")
local cli = require("lvim-pkg.core.cli")
local store = require("lvim-pkg.store")
local snapshot = require("lvim-pkg.snapshot")
local registry = require("lvim-pkg.registry")
local registry_ts = require("lvim-pkg.registry.ts")

-- lvim-pkg is deliberately zero-dependency: lvim-utils is an OPTIONAL soft dep, pcall'd so
-- the plugin still loads without it. When present, utils.merge gives the canonical in-place,
-- clean array-replace merge; the tbl_deep_extend fallback below is only used when it is absent.
local ok_utils, utils = pcall(require, "lvim-utils.utils")

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
    -- Merge user overrides into the live config IN PLACE, so every require("lvim-pkg.config")
    -- reader sees them. Prefer lvim-utils.utils.merge (clean array-replace per the merge
    -- convention); fall back to tbl_deep_extend only when lvim-utils is not available.
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    elseif opts then
        for k, v in pairs(opts) do
            if type(v) == "table" and type(config[k]) == "table" then
                config[k] = vim.tbl_deep_extend("force", config[k], v)
            else
                config[k] = v
            end
        end
    end
    -- Make our installer's bin directory available to spawned tools/LSP servers.
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
    return paths.package_dir(name)
end

--- The managed bin directory holding linked tool executables (added to PATH). Consumers
--- (e.g. lvim-ls) resolve a tool's binary here instead of assuming the Mason layout.
---@return string
function M.bin_dir()
    return paths.bin()
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
---@param cb fun(err: string|nil)
---@return nil
function M.plugin_checkout(name, ref, cb)
    return loader.plugin_checkout(name, ref, cb)
end

---@param name string
---@param branch string
---@param cb fun(err: string|nil)
---@return nil
function M.plugin_update_branch(name, branch, cb)
    return loader.plugin_update_branch(name, branch, cb)
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

--- Install a language SDK that is not a mason-registry package (a git-cloned SDK such as
--- Flutter), through the dedicated `sdk` handler. See lvim-pkg.install.install_sdk.
---@param spec { name: string, repo: string, ref?: string, bins?: string[], version?: string }
---@param cb?   fun(err: string|nil)
---@param opts? { on_progress?: fun(name: string, status: string, action: string) }
---@return nil
function M.install_sdk(spec, cb, opts)
    local ok, install = pcall(require, "lvim-pkg.install")
    if not ok then
        if cb then
            cb("lvim-pkg.install unavailable")
        end
        return
    end
    install.install_sdk(spec, opts, cb or function() end)
end

--- Install a LuaRocks rock that the mason registry does not carry — `busted` is one: a real,
--- everyday rock that simply is not in that catalogue, so `install("mason", …)` for it can only
--- report "no binary appeared". The rock goes into its own tree under the managed packages
--- directory and its executables are linked into `bin/`, exactly as a registry package would be.
---@param spec { name: string, version?: string, bins?: string[], server?: string }
---@param cb?   fun(err: string|nil)
---@param opts? { on_progress?: fun(name: string, status: string, action: string) }
---@return nil
function M.install_rock(spec, cb, opts)
    local ok, install = pcall(require, "lvim-pkg.install")
    if not ok then
        if cb then
            cb("lvim-pkg.install unavailable")
        end
        return
    end
    install.install_rock(spec, opts, cb or function() end)
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
    -- Notify subscribers BEFORE the files are deleted, so a domain (e.g. lvim-ls) can stop an
    -- LSP client whose tool is about to vanish — avoiding server crashes / stale in-flight
    -- responses. A matching "removed" fires after, for post-delete cleanup of any straggler.
    for _, name in ipairs(names) do
        M.emit("removing", kind, name)
    end
    b.remove(names, function(err)
        -- Only announce "removed" when the delete actually succeeded — on failure the files
        -- are still on disk, so post-delete cleanup subscribers must NOT run.
        if not err then
            for _, name in ipairs(names) do
                M.emit("removed", kind, name)
            end
        end
        if cb then
            cb(err)
        end
    end)
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

--- Contribute a tree-sitter parser the community catalogue does not carry, from a plugin's own
--- `setup()` — the same self-registration shape as `register_provider`, so installing the plugin
--- that needs the grammar is enough and no central config has to be edited for it. The entry uses
--- the registry's own shape (see LvimPkgTsEntry); it is merged over the catalogue and outranks it
--- on a name collision, exactly like a `config.extra_parsers` entry, which this writes into.
---
--- Safe in any load order relative to `setup()`: the registry re-reads the config on every load,
--- and this drops the in-memory copy so the next read picks the entry up.
---@param lang string
---@param entry LvimPkgTsEntry
---@return nil
function M.register_parser(lang, entry)
    if type(lang) ~= "string" or lang == "" or type(entry) ~= "table" or type(entry.source) ~= "table" then
        return
    end
    config.extra_parsers = config.extra_parsers or {}
    config.extra_parsers[lang] = entry
    backends.parser.invalidate_registry()
end

--- Subscribe to an installer event (decoupling — domains never get called directly).
--- Events: "installing" (active: boolean); "removing" (kind, name) — fired BEFORE a
--- package's files are deleted; "removed" (kind, name) — fired after.
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
    return snapshot.list()
end

--- The active snapshot name.
---@return string
function M.active_snapshot()
    return snapshot.active()
end

--- Make `name` the active snapshot (switches the whole version set).
---@param name string
---@return boolean
function M.select_snapshot(name)
    return snapshot.select(name)
end

--- Capture the current state into a named snapshot file: each installed plugin's live
--- git HEAD and each Mason package's installed version. Explicit pins from the active
--- snapshot are carried over (kept flagged); everything else is a plain reproducibility
--- record. Overwrites an existing file of the same name.
---
--- `opts.mason = false` records the PLUGINS ONLY. The two halves are reproducible in different
--- senses: a plugin commit is the same revision on every machine, while an installed tool's version
--- is whatever that machine's package source last offered — so a set meant to pin the distribution
--- often wants the first without the second.
---@param name string
---@param opts? { mason?: boolean }
---@return boolean ok, string? err
function M.snapshot_save(name, opts)
    if not name or name == "" then
        return false, "snapshot name required"
    end
    opts = opts or {}
    local active = pins.all_full()
    local snap = { plugins = {}, mason = {} }
    for _, info in ipairs(M.plugins()) do
        -- Resolve each plugin's HEAD by reading its .git plumbing (loader.head_commit) rather
        -- than forking `git rev-parse` per plugin — with 100+ plugins the sequential fork+exec
        -- froze the UI for up to a couple of seconds on every snapshot save.
        local commit = info.path and loader.head_commit(info.path) or nil
        commit = commit or (info.commit ~= "" and info.commit or nil)
        if commit then
            local entry = { commit = commit }
            if active.plugin[info.name] then
                entry.pin = true
            end
            snap.plugins[info.name] = entry
        end
    end
    local ok, install = pcall(require, "lvim-pkg.install")
    if ok and opts.mason ~= false then
        for _, mname in ipairs(install.installed()) do
            local v = M.installed_version(mname)
            if v and v ~= "" then
                local entry = { version = v }
                if active.mason[mname] then
                    entry.pin = true
                end
                snap.mason[mname] = entry
            end
        end
    end
    if not snapshot.write_file(name, snap) then
        return false, "could not write snapshot file"
    end
    return true
end

--- What restoring the active snapshot would change — only entries whose currently
--- installed version differs from the snapshot's pinned version (latest entries are
--- left alone). Shape: { plugins = { {name, from, to} }, mason = { {name, from, to} } }.
---@return { plugins: table[], mason: table[] }
function M.snapshot_diff()
    local out = { plugins = {}, mason = {} }
    for _, info in ipairs(M.plugins()) do
        local rec = snapshot.get_full("plugin", info.name)
        if rec and rec.version and rec.version ~= "" then
            local changed
            if rec.reftype == "commit" then
                -- Commit pin: prefix-compare the sha against the live short HEAD.
                local cur = info.commit
                changed = cur
                    and cur ~= ""
                    and not vim.startswith(rec.version, cur)
                    and not vim.startswith(cur, rec.version)
            else
                -- Tag/branch pin: a ref NAME never prefix-matches a sha, so compare against the
                -- live checkout's ref (kind/value) instead — a plugin sitting exactly on its
                -- pinned tag/branch is NOT a pending change.
                local curp = loader.plugin_current(info.name)
                changed = not (curp and curp.value == rec.version)
            end
            if changed then
                out.plugins[#out.plugins + 1] = { name = info.name, from = info.commit, to = rec.version }
            end
        end
    end
    local ok, install = pcall(require, "lvim-pkg.install")
    if ok then
        for _, name in ipairs(install.installed()) do
            local to = snapshot.get("mason", name)
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
---@param cb? fun(errs: string[]|nil)
---@param on_progress? fun(kind: string, name: string, action: string)
---@return nil
function M.snapshot_restore(diff, cb, on_progress)
    cb = cb or function() end
    local plugins = diff.plugins or {}
    -- Per-plugin checkout failures collected here so the caller can surface them rather than
    -- silently reporting a clean restore; nil is passed when everything succeeded.
    local errs = {}

    -- After every plugin checkout: reinstall the changed Mason packages, then finish.
    local function do_mason()
        local names = {}
        for _, m in ipairs(diff.mason or {}) do
            names[#names + 1] = m.name
        end
        if #names == 0 then
            return cb(#errs > 0 and errs or nil)
        end
        M.install("mason", names, function()
            cb(#errs > 0 and errs or nil)
        end, {
            on_progress = on_progress and function(name, _, action)
                on_progress("mason", name, action)
            end or nil,
        })
    end

    -- Check out each pinned plugin SEQUENTIALLY and asynchronously (plugin_checkout is async now),
    -- so a multi-plugin restore never blocks the UI on git; then run the Mason step.
    local i = 0
    local function next_plugin()
        i = i + 1
        local p = plugins[i]
        if not p then
            return do_mason()
        end
        if on_progress then
            on_progress("plugin", p.name, "checkout")
        end
        M.plugin_checkout(p.name, p.to, function(err)
            if err then
                errs[#errs + 1] = p.name .. ": " .. err
            end
            next_plugin()
        end)
    end
    next_plugin()
end

--- Export the active snapshot's full version set to a shareable lockfile.
---@param dest string  Absolute path to write
---@return boolean ok, string? err
function M.snapshot_export(dest)
    return snapshot.export(dest)
end

--- Import a lockfile into a new (non-active) snapshot; `select_snapshot` + `snapshot_restore`
--- it to apply.
---@param src string    Absolute path to read
---@param name? string  Snapshot name to create (default: basename of src)
---@return boolean ok, string? err
function M.snapshot_import(src, name)
    return snapshot.import(src, name)
end

-- ── Declines (per-filetype "do not offer these packages again") ───────────────

--- Decline `names` for filetype `ft`: the unified prompt stops offering them and
--- `missing_for_ft` filters them out.
---@param ft string
---@param names string[]
---@return nil
function M.decline(ft, names)
    for _, name in ipairs(names) do
        store.decline_add(ft, name)
    end
end

--- Re-enable a previously declined package for `ft`.
---@param ft string
---@param name string
---@return nil
function M.undecline(ft, name)
    store.decline_remove(ft, name)
end

--- Every decline as a { ft, name } list (for the management menu).
---@return { ft: string, name: string }[]
function M.declined()
    return store.declines_all()
end

-- ── Registry refresh ──────────────────────────────────────────────────────────

--- Refresh registry catalogues. With `force` (the manual command) it re-downloads now;
--- without it (the on-open / setup path) it fetches on first-run bootstrap (no cache) OR
--- when the cached copy is older than `config.registry_ttl` — a fresh cache is left as-is
--- (set registry_ttl to 0 to disable the age-based refresh and fetch only when missing).
---@param which? "mason"|"ts"|"all"  Default "all"
---@param cb? fun()
---@param force? boolean
---@return nil
function M.update_registry(which, cb, force)
    which = which or "all"
    cb = cb or function() end
    local jobs = {}
    if which == "mason" or which == "all" then
        jobs[#jobs + 1] = function(done)
            registry.ensure(done, force)
        end
    end
    if which == "ts" or which == "all" then
        jobs[#jobs + 1] = function(done)
            registry_ts.ensure(done, force)
        end
    end
    if #jobs == 0 then
        cb()
        return
    end
    local pending = #jobs
    local fired = false
    local function done()
        pending = pending - 1
        if pending <= 0 and not fired then
            fired = true
            cb()
        end
    end
    for _, job in ipairs(jobs) do
        job(done)
    end
end

return M
