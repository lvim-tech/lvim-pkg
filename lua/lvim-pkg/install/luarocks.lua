-- lvim-pkg: LuaRocks source installer.
-- Runs `luarocks install --tree <dir>` for the rock, then links the binaries it produced.
--
-- A TREE OF ITS OWN, never the system rock tree: every other source here installs into the
-- package's own directory so an uninstall is a directory removal and two versions never fight over
-- one prefix. `--tree` is luarocks' way of saying the same thing, and it puts the executables in
-- `<tree>/bin` exactly where `bin/` entries expect them.
--
-- The `repository_url` query parameter a PURL may carry (the dev repository, for `scm-1` rocks)
-- becomes `--server`, so a package pinned to luarocks' dev channel resolves there instead of
-- failing to be found on the main one.
--
---@module "lvim-pkg.install.luarocks"

local util = require("lvim-pkg.install.util")

local M = {}

---@param ctx table
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
    if vim.fn.executable("luarocks") ~= 1 then
        cb("luarocks: not found on PATH — install luarocks to use this package")
        return
    end
    ctx.progress("luarocks install")
    local args = { "luarocks", "install", "--tree", ctx.dir }
    -- The dev channel, when the PURL asks for it: `?repository_url=https://luarocks.org/dev`.
    local server = ctx.purl.qualifiers and ctx.purl.qualifiers.repository_url
    if server then
        vim.list_extend(args, { "--server", server })
    end
    args[#args + 1] = ctx.purl.name
    if ctx.purl.version then
        args[#args + 1] = ctx.purl.version
    end
    util.run(args, {}, function(err)
        if err then
            cb("luarocks: " .. err)
            return
        end
        for binname, target in pairs(ctx.spec.bin or {}) do
            local rel = tostring(target):gsub("^luarocks:", "")
            if util.symlink(ctx.dir .. "/bin/" .. rel, ctx.bin_dir .. "/" .. binname) then
                ctx.add_bin(binname)
            end
        end
        cb(nil)
    end)
end

return M
