-- The plugin loader describes itself as it RUNS.
--
-- A host loads lvim-pack before it reads any spec, so a dev `dir=` entry for it never takes effect: the
-- installed copy keeps running. The browser used to list the checkout instead (lazy, never loaded, never
-- checked for updates), so an outdated loader was invisible and could not be updated. These specs plant a
-- fake `lvim-pack` module whose source lives where a real one would, and read the entry back.

local loader = require("lvim-pkg.loader")

--- Load a fake `lvim-pack` from `<root>/lua/lvim-pack/init.lua`, so debug info points into `root`.
---@param root string
local function plant(root)
    local file = root .. "/lua/lvim-pack/init.lua"
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    vim.fn.writefile({ "local M = {}", "function M.setup() end", "return M" }, file)
    package.loaded["lvim-pack"] = assert(loadfile(file))()
end

describe("lvim-pkg: the plugin loader in the plugin list")

local saved = package.loaded["lvim-pack"]

it("an installed loader replaces a dev entry for it: loaded, eager, git-managed", function()
    local root = vim.fn.tempname() .. "/site/pack/core/opt/lvim-pack"
    plant(root)
    loader.register({
        ["lvim-pack"] = {
            repo = "lvim-tech/lvim-pack",
            dir = "/dev/lua/lvim-pack",
            path = "/dev/lua/lvim-pack",
            lazy = true,
        },
        ["lvim-x"] = { repo = "lvim-tech/lvim-x", dir = "/dev/lua/lvim-x", path = "/dev/lua/lvim-x" },
    })
    local i = loader.info("lvim-pack")
    eq(vim.fs.normalize(root), i.path, "the copy that runs")
    eq(nil, i.dir, "an installed clone: the outdated check and Update reach it")
    eq(true, i.loaded)
    eq(false, i.lazy)
    eq("plugin loader", i.reason)
    eq("/dev/lua/lvim-x", loader.info("lvim-x").dir, "other entries are untouched")
end)

it("a loader bootstrapped from a checkout on purpose stays a local dir", function()
    local root = vim.fn.tempname() .. "/dev/lua/lvim-pack"
    plant(root)
    loader.register({})
    local i = loader.info("lvim-pack")
    eq(vim.fs.normalize(root), i.path)
    eq(vim.fs.normalize(root), i.dir)
end)

it("no loader, no rewrite", function()
    package.loaded["lvim-pack"] = nil
    loader.register({ ["lvim-pack"] = { repo = "lvim-tech/lvim-pack", dir = "/dev/lua/lvim-pack" } })
    eq("/dev/lua/lvim-pack", loader.info("lvim-pack").dir)
end)

package.loaded["lvim-pack"] = saved
