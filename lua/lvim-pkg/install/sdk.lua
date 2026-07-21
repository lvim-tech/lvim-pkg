-- lvim-pkg: SDK source installer.
-- Installs a language SDK that ships as a git repository (rather than a registry package) — the
-- Flutter SDK being the first consumer: a shallow clone of the SDK repo at a channel/tag, with the
-- SDK's own bins (flutter, dart) linked into the lvim-pkg bin dir. The SDK's bin scripts resolve
-- their root from their real path, so a symlink on PATH works. Reached through the dedicated
-- `install_sdk` entry (SDKs are not in the mason registry).
--
-- Expected source shape (ctx.purl / ctx.spec.source):
--   { repo = "https://github.com/flutter/flutter.git", ref = "stable", bins = { "flutter", "dart" } }
--
---@module "lvim-pkg.install.sdk"

local util = require("lvim-pkg.install.util")

local M = {}

--- Clone the SDK repo into ctx.dir and link its bins.
---@param ctx table  { name, dir, bin_dir, purl/spec.source, add_bin, progress }
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
    local src = ctx.purl or (ctx.spec and ctx.spec.source) or {}
    local url = src.repo or src.url
    if not url then
        cb("sdk: source needs a `repo` (git url)")
        return
    end

    ctx.progress("clone")
    local args = { "git", "clone", "--depth", "1" }
    if src.ref and src.ref ~= "" then
        vim.list_extend(args, { "--branch", src.ref })
    end
    vim.list_extend(args, { url, ctx.dir })

    util.run(args, {}, function(err)
        if err then
            cb("git clone failed: " .. err)
            return
        end
        ctx.progress("link")
        for _, bin in ipairs(src.bins or {}) do
            local target = ctx.dir .. "/bin/" .. bin
            util.chmod_x(target)
            util.symlink(target, ctx.bin_dir .. "/" .. bin)
            ctx.add_bin(bin)
        end
        cb(nil)
    end)
end

return M
