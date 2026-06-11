-- lvim-pkg: PyPI source installer.
-- Creates a dedicated venv in the package directory, installs the package (and
-- any extra_packages) into it, then links the console scripts from venv/bin.
--
---@module "lvim-pkg.install.pypi"

local util = require("lvim-pkg.install.util")

local M = {}

---@param ctx table
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
	local venv = ctx.dir .. "/venv"
	local py = vim.fn.executable("python3") == 1 and "python3" or "python"
	ctx.progress("create venv")
	util.run({ py, "-m", "venv", venv }, {}, function(err)
		if err then
			cb("venv: " .. err)
			return
		end
		local pip = venv .. "/bin/pip"
		local pkgs = { ctx.purl.name .. (ctx.purl.version and ("==" .. ctx.purl.version) or "") }
		for _, extra in ipairs(ctx.spec.source.extra_packages or {}) do
			pkgs[#pkgs + 1] = extra
		end
		ctx.progress("pip install")
		local args = { pip, "install", "--upgrade" }
		vim.list_extend(args, pkgs)
		util.run(args, {}, function(e2)
			if e2 then
				cb("pip: " .. e2)
				return
			end
			for binname, target in pairs(ctx.spec.bin or {}) do
				local rel = tostring(target):gsub("^pypi:", "")
				if util.symlink(venv .. "/bin/" .. rel, ctx.bin_dir .. "/" .. binname) then
					ctx.add_bin(binname)
				end
			end
			cb(nil)
		end)
	end)
end

return M
