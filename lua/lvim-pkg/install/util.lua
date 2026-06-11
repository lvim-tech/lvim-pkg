-- lvim-pkg: install helpers — async command runner, download, archive extraction
-- and symlinking.  Shared by every source installer.
--
---@module "lvim-pkg.install.util"

local M = {}

--- Run a command asynchronously; `cb(err)` with err=nil on success.
---@param cmd  string[]
---@param opts { cwd?: string, env?: table<string,string> }|nil
---@param cb   fun(err: string|nil)
---@return nil
function M.run(cmd, opts, cb)
	opts = opts or {}
	local ok, err = pcall(
		vim.system,
		cmd,
		{ cwd = opts.cwd, env = opts.env, text = true },
		vim.schedule_wrap(function(res)
			if res.code == 0 then
				cb(nil)
			else
				local msg = (res.stderr ~= nil and res.stderr ~= "" and res.stderr)
					or res.stdout
					or ("exit " .. res.code)
				cb(vim.trim(tostring(msg)))
			end
		end)
	)
	if not ok then
		cb(tostring(err))
	end
end

--- Download `url` to `dest` via curl.
---@param url  string
---@param dest string
---@param cb   fun(err: string|nil)
---@return nil
function M.download(url, dest, cb)
	M.run({ "curl", "-fsSL", "--retry", "2", "-o", dest, url }, {}, cb)
end

--- Extract a .zip / .tar.gz / .tgz / .tar / .gz archive into `dir`.
---@param archive string
---@param dir     string
---@param cb      fun(err: string|nil)
---@return nil
function M.extract(archive, dir, cb)
	vim.fn.mkdir(dir, "p")
	local lower = archive:lower()
	if lower:match("%.zip$") then
		M.run({ "unzip", "-o", "-q", archive, "-d", dir }, {}, cb)
	elseif lower:match("%.tar%.gz$") or lower:match("%.tgz$") then
		M.run({ "tar", "-xzf", archive, "-C", dir }, {}, cb)
	elseif lower:match("%.tar%.xz$") or lower:match("%.txz$") then
		M.run({ "tar", "-xJf", archive, "-C", dir }, {}, cb)
	elseif lower:match("%.tar$") then
		M.run({ "tar", "-xf", archive, "-C", dir }, {}, cb)
	elseif lower:match("%.gz$") then
		local out = dir .. "/" .. vim.fn.fnamemodify(archive, ":t:r")
		M.run({ "sh", "-c", string.format("gunzip -c %q > %q", archive, out) }, {}, cb)
	else
		cb("unknown archive type: " .. archive)
	end
end

--- Force-create a symlink `link_path` → `src`.
---@param src       string
---@param link_path string
---@return boolean  Success
function M.symlink(src, link_path)
	vim.fn.delete(link_path)
	return (pcall(vim.uv.fs_symlink, src, link_path))
end

--- Mark a file executable (0755).  Best-effort.
---@param path string
---@return nil
function M.chmod_x(path)
	pcall(vim.uv.fs_chmod, path, 493)
end

return M
