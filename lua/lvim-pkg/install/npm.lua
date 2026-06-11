-- lvim-pkg: npm source installer.
-- Installs the package (and any extra_packages) into the package directory with
-- `npm install --prefix`, then links the executables from node_modules/.bin.
--
---@module "lvim-pkg.install.npm"

local util = require("lvim-pkg.install.util")

local M = {}

---@param ctx table  Install context
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
	local pkgs = { ctx.purl.name .. "@" .. (ctx.purl.version or "latest") }
	for _, extra in ipairs(ctx.spec.source.extra_packages or {}) do
		pkgs[#pkgs + 1] = extra
	end
	ctx.progress("npm install")
	local args = { "npm", "install", "--no-audit", "--no-fund", "--prefix", ctx.dir }
	vim.list_extend(args, pkgs)
	util.run(args, { cwd = ctx.dir }, function(err)
		if err then
			cb("npm: " .. err)
			return
		end
		for binname, target in pairs(ctx.spec.bin or {}) do
			local rel = tostring(target):gsub("^npm:", "")
			if util.symlink(ctx.dir .. "/node_modules/.bin/" .. rel, ctx.bin_dir .. "/" .. binname) then
				ctx.add_bin(binname)
			end
		end
		cb(nil)
	end)
end

return M
