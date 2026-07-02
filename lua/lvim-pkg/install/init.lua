-- lvim-pkg: install dispatcher.
-- Routes a registry package to the installer for its source type, records a
-- receipt on success (name, version, type, linked bins), and supports listing
-- installed packages and removing them.  This is the self-contained replacement
-- for mason.nvim's install engine.
--
---@module "lvim-pkg.install"

local paths = require("lvim-pkg.paths")
local registry = require("lvim-pkg.registry")
local store = require("lvim-pkg.store")
local snapshot = require("lvim-pkg.snapshot")
local purl = require("lvim-pkg.registry.purl")
local versions = require("lvim-pkg.install.versions")

local M = {}

---@type table<string, table>  source type → handler module
local handlers = {
    npm = require("lvim-pkg.install.npm"),
    pypi = require("lvim-pkg.install.pypi"),
    golang = require("lvim-pkg.install.golang"),
    cargo = require("lvim-pkg.install.cargo"),
    github = require("lvim-pkg.install.github"),
}

--- Is the source type installable by this engine?
---@param typ string
---@return boolean
function M.supported(typ)
    return handlers[typ] ~= nil
end

---@param name string
---@return string  Receipt path for a package
local function receipt_path(name)
    return paths.package_dir(name) .. "/.lvim-pkg-receipt.json"
end

--- Read a package's install receipt, or nil when not installed by us.
--- Receipts live in the JSON state store (lvim-pkg.store); a legacy on-disk receipt is
--- imported on read.
---@param name string
---@return table|nil
function M.receipt(name)
    local r = store.receipt_get(name)
    if r then
        return r
    end
    -- Legacy: import an on-disk receipt into the store, then return it.
    local f = io.open(receipt_path(name), "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    if not (ok and type(data) == "table") then
        return nil
    end
    store.receipt_set(name, data)
    return data
end

--- Was `name` installed by this engine?
---@param name string
---@return boolean
function M.is_installed(name)
    return M.receipt(name) ~= nil
end

--- Names of all packages installed by this engine.
---@return string[]
function M.installed()
    local names = {}
    local dir = paths.packages()
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
        return names
    end
    while true do
        local entry = vim.uv.fs_scandir_next(handle)
        if not entry then
            break
        end
        if M.is_installed(entry) then
            names[#names + 1] = entry
        end
    end
    return names
end

--- Install a registry package by name.
---@param name string
---@param opts { on_progress?: fun(name: string, status: string, action: string) }|nil
---@param cb   fun(err: string|nil)
---@return nil
function M.install(name, opts, cb)
    opts = opts or {}
    local spec = registry.get(name)
    if not spec then
        cb("not in registry: " .. name)
        return
    end
    local p = registry.source(name)
    local handler = p and handlers[p.type]
    if not handler then
        cb("unsupported source: " .. (p and p.type or "?"))
        return
    end
    ---@cast p table -- guaranteed non-nil: `handler` is only set when `p` is a table

    -- Honour the active snapshot's recorded version (the full set, not just explicit
    -- pins), so a reproducibility record installs that exact version. Falls back to the
    -- registry default when the snapshot tracks latest (no entry).
    local recorded = snapshot.get("mason", name)
    if recorded and recorded ~= "" then
        p = vim.tbl_extend("force", p, { version = recorded })
    end

    paths.ensure()
    local dir = paths.package_dir(name)
    -- Keep the working install as a sibling backup while the new one builds, so a failed
    -- update restores the previous version instead of leaving the package uninstalled.
    local bak = dir .. ".bak"
    vim.fn.delete(bak, "rf")
    local backed_up = false
    if vim.fn.isdirectory(dir) == 1 then
        backed_up = pcall(vim.uv.fs_rename, dir, bak) and vim.fn.isdirectory(bak) == 1
        if not backed_up then
            vim.fn.delete(dir, "rf") -- couldn't back up; fall back to a clean reinstall
        end
    end
    vim.fn.mkdir(dir, "p")

    local bins = {}
    local ctx = {
        name = name,
        dir = dir,
        bin_dir = paths.bin(),
        purl = p,
        spec = spec,
        add_bin = function(binname)
            bins[#bins + 1] = binname
        end,
        progress = function(action)
            if opts.on_progress then
                opts.on_progress(name, "pending", action)
            end
        end,
    }

    handler.install(ctx, function(err)
        if err then
            vim.fn.delete(dir, "rf")
            if backed_up then
                pcall(vim.uv.fs_rename, bak, dir) -- restore the previous working install
            end
            cb(err)
            return
        end
        vim.fn.delete(bak, "rf") -- success: drop the backup
        store.receipt_set(name, { type = p.type, version = p.version, bins = bins })
        cb(nil)
    end)
end

--- Remove a package: unlink its bins and delete its directory.
---@param name string
---@return nil
function M.remove(name)
    local receipt = M.receipt(name)
    if receipt then
        for _, binname in ipairs(receipt.bins or {}) do
            vim.fn.delete(paths.bin() .. "/" .. binname)
        end
    end
    store.receipt_remove(name)
    vim.fn.delete(paths.package_dir(name), "rf")
end

--- Available versions of a Mason package (newest first), queried from its source's
--- ecosystem (npm / pypi / github / cargo / golang). Async; cb(list) or cb(nil) on any
--- failure (the caller falls back to the registry's pinned version).
---@param name string
---@param cb fun(list: string[]|nil)
---@return nil
function M.versions(name, cb)
    local spec = registry.get(name)
    local id = spec and spec.source and spec.source.id
    if not id then
        return cb(nil)
    end
    local p = purl.parse(id)
    versions.fetch(p, cb)
end

return M
