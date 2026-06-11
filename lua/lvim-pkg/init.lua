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
local purl = require("lvim-pkg.registry.purl")
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

--- Whether a package is installed in OUR path (has our receipt), as opposed to
--- only existing in the legacy mason.nvim tree (which counts as installed for
--- runtime but should be reinstalled to migrate it into our path).
---@param name string
---@return boolean
function M.is_managed(name)
	local ok, install = pcall(require, "lvim-pkg.install")
	return ok and install.is_installed(name) or false
end

--- Install directory of a package: ours if present, else the legacy mason.nvim
--- package dir (so configs that point at auxiliary files keep working during the
--- transition). Falls back to our path when neither exists yet.
---@param name string
---@return string
function M.package_path(name)
	local lp = require("lvim-pkg.paths").package_dir(name)
	if vim.fn.isdirectory(lp) == 1 then
		return lp
	end
	local mp = vim.fn.stdpath("data") .. "/mason/packages/" .. name
	if vim.fn.isdirectory(mp) == 1 then
		return mp
	end
	return lp
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

function M.installed_version(name)
	local ok, install = pcall(require, "lvim-pkg.install")
	if ok then
		local r = install.receipt(name)
		if r and r.version then
			return r.version
		end
	end
	-- Fallback: read the old mason.nvim receipt file directly (no plugin dependency)
	-- so packages installed before the migration still show their version.
	local mp = vim.fn.stdpath("data") .. "/mason/packages/" .. name .. "/mason-receipt.json"
	local fh = io.open(mp, "r")
	if fh then
		local content = fh:read("*a")
		fh:close()
		local dok, data = pcall(vim.json.decode, content)
		if dok and type(data) == "table" and data.source and data.source.id then
			return (purl.parse(data.source.id) or {}).version
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

--- Refresh registry catalogues. With `force` (the manual command) it ignores the TTL
--- and the update_registry gate; without it (the on-open path) it only fetches when
--- the cache is missing/stale — closing the cold-start race where a catalogue is empty
--- until its first background fetch lands.
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
