-- lvim-pkg: Go source installer.
-- Runs `go install module@version` with GOBIN pointed at the package directory,
-- then links the resulting binaries.
--
---@module "lvim-pkg.install.golang"

local util = require("lvim-pkg.install.util")

local M = {}

---@param ctx table
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
	-- Append the purl subpath (e.g. "cmd/dlv") so `go install` targets the command
	-- package inside the module, not the (non-main) module root.
	local mod = ctx.purl.name
	if ctx.purl.subpath and ctx.purl.subpath ~= "" then
		mod = mod .. "/" .. ctx.purl.subpath
	end
	local module = mod .. "@" .. (ctx.purl.version or "latest")
	ctx.progress("go install")
	local env = vim.tbl_extend("force", vim.fn.environ(), { GOBIN = ctx.dir, GO111MODULE = "on" })
	util.run({ "go", "install", module }, { env = env }, function(err)
		if err then
			cb("go: " .. err)
			return
		end
		for binname, target in pairs(ctx.spec.bin or {}) do
			local rel = tostring(target):gsub("^golang:", "")
			if util.symlink(ctx.dir .. "/" .. rel, ctx.bin_dir .. "/" .. binname) then
				ctx.add_bin(binname)
			end
		end
		cb(nil)
	end)
end

return M
