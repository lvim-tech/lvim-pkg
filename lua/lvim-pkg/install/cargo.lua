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
    -- A `repository_url` qualifier marks a crate the registry sources FROM GIT, not crates.io
    -- (mason semantics): the version is a git tag there, and the crates.io name may even belong
    -- to a different project (statix v0.5.8 is git-only; the crates.io "statix" is unrelated).
    local repo = (ctx.purl.qualifiers or {}).repository_url
    if repo then
        vim.list_extend(args, { "--git", repo })
        if ctx.purl.version then
            vim.list_extend(args, { "--tag", ctx.purl.version })
        end
    elseif ctx.purl.version then
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
