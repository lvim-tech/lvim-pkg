-- lvim-pkg: GitHub release source installer.
-- Resolves the asset for the current platform, downloads it from the release tag,
-- extracts it (into an optional subdirectory encoded as "file.tar.gz:subdir/"),
-- and links the executable named by the asset's `bin` field.
--
---@module "lvim-pkg.install.github"

local util = require("lvim-pkg.install.util")
local target = require("lvim-pkg.install.target")

local M = {}

--- Is `file` a recognised archive (vs a raw binary asset)?
---@param file string
---@return boolean
local function is_archive(file)
	local lower = file:lower()
	return lower:match("%.zip$") ~= nil
		or lower:match("%.tar%.?g?z?$") ~= nil
		or lower:match("%.tgz$") ~= nil
		or lower:match("%.txz$") ~= nil
		or lower:match("%.gz$") ~= nil
end

---@param ctx table
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
	local source = ctx.spec.source
	local asset = target.pick_asset(source.asset)
	if not asset then
		cb("no asset for platform: " .. table.concat(target.acceptable(), ", "))
		return
	end

	local owner_repo = ctx.purl.name
	local tag = ctx.purl.version or ""
	local ver_no_v = tag:gsub("^v", "")

	-- Mason template substitution: {{version}} is the version verbatim (e.g. "v0.0.56"),
	-- and {{ version | strip_prefix "v" }} drops a leading "v". Applied to both the
	-- asset filename and the bin path.
	local function subst(str)
		str = str:gsub('{{%s*version%s*|%s*strip_prefix%s*"v"%s*}}', ver_no_v)
		str = str:gsub("{{%s*version%s*}}", tag)
		return str
	end

	-- "file.tar.gz:libexec/" → file + extract subdirectory (relative to ctx.dir).
	local file_spec = asset.file
	local file, subdir = file_spec:match("^(.-):(.+)$")
	if not file then
		file = file_spec
	end
	file = subst(file)

	local url = string.format("https://github.com/%s/releases/download/%s/%s", owner_repo, tag, file)
	local download_path = ctx.dir .. "/" .. file

	local function finish_link()
		-- The authoritative bin list is the package's top-level `bin` map (name → template).
		-- Each template resolves to a path with an optional "<runner>:" prefix:
		--   no prefix / "exec:"      → a plain executable (chmod + symlink)
		--   "node:" / "python:" / …  → a script launched through an interpreter (wrapper)
		-- Templates: {{source.asset.bin}} (the chosen asset's bin, e.g. stylua) and
		-- {{source.bin}} (a source-level bin, e.g. node-based adapters).
		local bins = ctx.spec.bin or {}

		-- Fallback: no top-level map but the asset names a bin — link it under its basename.
		if next(bins) == nil and asset.bin then
			local rel = subst(tostring(asset.bin):gsub("^%a[%w_]*:", ""))
			bins = { [vim.fn.fnamemodify(rel, ":t"):gsub("%.exe$", "")] = "{{source.asset.bin}}" }
		end

		for binname, tmpl in pairs(bins) do
			local val = tostring(tmpl)
			val = val:gsub("{{%s*source%.bin%s*}}", source.bin or "")
			val = val:gsub("{{%s*source%.asset%.bin%s*}}", asset.bin or "")
			val = subst(val)

			local runner, path = val:match("^(%a[%w_]*):(.+)$")
			path = path or val
			local src = ctx.dir .. "/" .. path

			if runner == nil or runner == "exec" then
				util.chmod_x(src)
				if util.symlink(src, ctx.bin_dir .. "/" .. binname) then
					ctx.add_bin(binname)
				end
			else
				-- Interpreter launcher: `exec <runner> <script> "$@"`.
				local launcher = ctx.bin_dir .. "/" .. binname
				local fh = io.open(launcher, "w")
				if fh then
					fh:write(('#!/bin/sh\nexec %s %q "$@"\n'):format(runner, src))
					fh:close()
					util.chmod_x(launcher)
					ctx.add_bin(binname)
				end
			end
		end
		cb(nil)
	end

	ctx.progress("download " .. file)
	util.download(url, download_path, function(err)
		if err then
			cb("download: " .. err)
			return
		end
		if is_archive(file) then
			local extract_dir = ctx.dir .. (subdir and ("/" .. subdir:gsub("/$", "")) or "")
			ctx.progress("extract")
			util.extract(download_path, extract_dir, function(e2)
				if e2 then
					cb("extract: " .. e2)
					return
				end
				vim.fn.delete(download_path)
				finish_link()
			end)
		else
			-- Raw binary download: keep it in place and link.
			util.chmod_x(download_path)
			finish_link()
		end
	end)
end

return M
