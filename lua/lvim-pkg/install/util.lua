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
        -- POSIX-escape both paths: Lua's %q quotes for LUA, not sh, so a registry-supplied
        -- filename containing $, backtick or \ could still expand / inject into `sh -c`.
        M.run(
            { "sh", "-c", string.format("gunzip -c %s > %s", vim.fn.shellescape(archive), vim.fn.shellescape(out)) },
            {},
            cb
        )
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
    if not vim.uv.fs_stat(src) then
        return false
    end
    local ok, err = vim.uv.fs_symlink(src, link_path)
    return ok == true and err == nil
end

--- Mark a file executable (0755).  Best-effort.
---@param path string
---@return nil
function M.chmod_x(path)
    pcall(vim.uv.fs_chmod, path, 493)
end

--- Link a RESOLVED bin `val` (a path RELATIVE to `ctx.dir`, optionally prefixed with "<runner>:") into
--- `ctx.bin_dir` as `binname`, and record it via `ctx.add_bin`. Mason bin templates carry an optional
--- interpreter prefix: no prefix / "exec:" → a plain executable (chmod + symlink); "python:" / "node:"
--- / … → a script run through that interpreter, so we write a tiny `exec <runner> <script> "$@"`
--- launcher. Shared by every download-and-link source (github / generic / …), so the wrapper semantics
--- are identical across sources. `val` must already have its template tokens substituted by the caller.
---@param ctx table    the install context ({ dir, bin_dir, add_bin, … })
---@param binname string
---@param val string   e.g. "stylua" or "python:bin/jdtls"
---@return nil
--- A runner prefix that is not a bare command name: what to actually exec, in argv order. The
--- registry writes `java-jar:` for a runnable jar, which is `java -jar <path>` — spelled as one
--- token it looked like a command called "java-jar" and the launcher it produced could never run.
---@type table<string, string[]>
local RUNNERS = {
    ["java-jar"] = { "java", "-jar" },
}

function M.link_bin(ctx, binname, val)
    -- HYPHENS BELONG IN A RUNNER NAME. The pattern used to accept letters, digits and underscores
    -- only, so `java-jar:` never matched as a prefix at all: the whole `java-jar:foo.jar` string
    -- was taken for a PATH, the symlink pointed at a file that cannot exist, and the install
    -- reported success with nothing in `bin/` (measured on ktfmt; 10 registry entries write it).
    local runner, path = val:match("^(%a[%w_%-]*):(.+)$")
    path = path or val
    local src = ctx.dir .. "/" .. path
    if runner == nil or runner == "exec" then
        M.chmod_x(src)
        if M.symlink(src, ctx.bin_dir .. "/" .. binname) then
            ctx.add_bin(binname)
        end
    else
        local launcher = ctx.bin_dir .. "/" .. binname
        local fh = io.open(launcher, "w")
        if fh then
            local argv = RUNNERS[runner] or { runner }
            local head = {}
            for _, word in ipairs(argv) do
                head[#head + 1] = vim.fn.shellescape(word)
            end
            fh:write(('#!/bin/sh\nexec %s %s "$@"\n'):format(table.concat(head, " "), vim.fn.shellescape(src)))
            fh:close()
            M.chmod_x(launcher)
            ctx.add_bin(binname)
        end
    end
end

--- Remove a file/directory WITHOUT blocking the main thread on a large tree (a
--- node_modules-sized package can hold thousands of files — deleting it synchronously froze
--- the otherwise-async install pipeline for seconds). The path is renamed to a unique sibling
--- (instant, same filesystem) so it disappears from its original location immediately, then the
--- rename target is removed by a background `rm -rf`. Falls back to a synchronous delete when
--- the rename fails (e.g. nothing there).
---@param path string
---@return nil
function M.rm_rf_async(path)
    if vim.fn.isdirectory(path) == 0 and vim.fn.filereadable(path) == 0 then
        return
    end
    local trash = path .. ".trash-" .. tostring(vim.uv.hrtime())
    if vim.uv.fs_rename(path, trash) then
        M.run({ "rm", "-rf", trash }, {}, function() end)
    else
        vim.fn.delete(path, "rf")
    end
end

return M
