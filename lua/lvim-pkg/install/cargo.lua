-- lvim-pkg: Cargo source installer.
-- Runs `cargo install --root <dir>` for the crate, then links bin/<crate>.
--
---@module "lvim-pkg.install.cargo"

local util = require("lvim-pkg.install.util")

local M = {}

---@param ctx table
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
    ctx.progress("cargo install")
    local args = { "cargo", "install", "--root", ctx.dir, "--locked", ctx.purl.name }
    if ctx.purl.version then
        vim.list_extend(args, { "--version", (ctx.purl.version:gsub("^v", "")) })
    end
    util.run(args, {}, function(err)
        if err then
            cb("cargo: " .. err)
            return
        end
        for binname, target in pairs(ctx.spec.bin or {}) do
            local rel = tostring(target):gsub("^cargo:", "")
            if util.symlink(ctx.dir .. "/bin/" .. rel, ctx.bin_dir .. "/" .. binname) then
                ctx.add_bin(binname)
            end
        end
        cb(nil)
    end)
end

return M
