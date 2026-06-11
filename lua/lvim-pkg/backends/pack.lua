-- lvim-pkg: vim.pack plugin backend.
-- Thin wrapper over Neovim's built-in vim.pack manager.  Plugin "availability"
-- comes from registered specs (the config), not a remote registry, so available()
-- mirrors installed().
--
---@module "lvim-pkg.backends.pack"

local B = { kind = "plugin" }

---@return boolean
local function has_pack()
	return vim.pack ~= nil
end

---@return string[]
function B.installed()
	local names = {}
	if has_pack() then
		for _, plugin in ipairs(vim.pack.get()) do
			local name = (plugin.spec and plugin.spec.name) or plugin.name
			if name then
				names[#names + 1] = name
			end
		end
	end
	return names
end

---@return string[]
function B.available()
	return B.installed()
end

---@param name string
---@return boolean
function B.is_installed(name)
	for _, installed in ipairs(B.installed()) do
		if installed == name then
			return true
		end
	end
	return false
end

--- Add plugins. `specs` are vim.pack spec tables: { src = "owner/repo"|url, version?, name? }.
---@param specs table[]
---@param cb? fun(err: string|nil)
function B.install(specs, cb)
	if not has_pack() then
		if cb then
			cb("vim.pack unavailable")
		end
		return
	end
	local ok, err = pcall(vim.pack.add, specs)
	if cb then
		cb(ok and nil or tostring(err))
	end
end

--- Update plugins (all when `names` is nil).
---@param names? string[]
---@param cb? fun(err: string|nil)
function B.update(names, cb)
	if not has_pack() then
		if cb then
			cb("vim.pack unavailable")
		end
		return
	end
	-- force = true applies updates right away (no confirmation buffer / separate
	-- tabpage), so progress can be shown inside the installer instead.
	local ok, err = pcall(vim.pack.update, names, { force = true })
	if cb then
		cb(ok and nil or tostring(err))
	end
end

--- Remove plugins by name.
---@param names string[]
---@param cb? fun(err: string|nil)
function B.remove(names, cb)
	if not has_pack() then
		if cb then
			cb("vim.pack unavailable")
		end
		return
	end
	-- force=true: our plugins are all "active" (added at startup); without force
	-- vim.pack.del skips active plugins and errors out.
	local ok, err = pcall(vim.pack.del, names, { force = true })
	if ok then
		-- Drop the removed plugins from the data store so the installer list updates.
		local loader = require("lvim-pkg.loader")
		for _, name in ipairs(names) do
			loader.unregister(name)
		end
	end
	if cb then
		cb(ok and nil or tostring(err))
	end
end

return B
