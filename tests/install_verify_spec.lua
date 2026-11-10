-- An install that reports success but installed nothing is a failure, and such a receipt is not "installed".
--
-- On a shared host, npm exited 0 and left an empty package directory. The receipt said installed with
-- `bins = {}`, so the package was never retried, and the editor reported the server as missing forever.

local install = require("lvim-pkg.install")
local registry = require("lvim-pkg.registry")
local store = require("lvim-pkg.store")
local paths = require("lvim-pkg.paths")
local util = require("lvim-pkg.install.util")

--- Run `fn` with a registry that knows one npm package declaring one executable.
local function with_fake_registry(name, fn)
    local saved = { get = registry.get, source = registry.source }
    registry.get = function(n)
        if n == name then
            return { name = name, source = { id = "pkg:npm/" .. name .. "@1.0.0" }, bin = { [name] = "npm:" .. name } }
        end
        return saved.get(n)
    end
    registry.source = function(n)
        if n == name then
            return { type = "npm", name = name, version = "1.0.0", qualifiers = {} }
        end
        return saved.source(n)
    end
    local ok, err = pcall(fn)
    registry.get, registry.source = saved.get, saved.source
    if not ok then
        error(err, 0)
    end
end

describe("lvim-pkg: an install is checked, not trusted")

it("npm exiting 0 with nothing installed is a failure, with no receipt", function()
    local name = "lvim-test-empty-" .. vim.uv.hrtime()
    with_fake_registry(name, function()
        local saved_run = util.run
        util.run = function(_, _, cb)
            cb(nil) -- "success", and nothing written
        end
        local done, err = false, nil
        local ok, e = pcall(install.install, name, {}, function(x)
            done, err = true, x
        end)
        util.run = saved_run
        assert(ok, e)
        vim.wait(2000, function()
            return done
        end, 10)
        truthy(err and err:find("none of its executables", 1, true), tostring(err))
        truthy(err:find(name, 1, true), "names the missing executable")
        eq(nil, store.receipt_get(name), "no receipt")
        eq(false, install.is_installed(name))
    end)
end)

it("the receipts the server was left with do not count as installed", function()
    local name = "lvim-test-receipt-" .. vim.uv.hrtime()
    with_fake_registry(name, function()
        local dir = paths.package_dir(name)
        vim.fn.mkdir(dir, "p")
        store.receipt_set(name, { type = "npm", version = "1.0.0", bins = {} })
        eq(false, install.is_installed(name), "empty directory")

        vim.fn.writefile({ "{}" }, dir .. "/package.json")
        eq(false, install.is_installed(name), "files, but a declared executable was never linked")

        store.receipt_set(name, { type = "npm", version = "1.0.0", bins = { name } })
        eq(false, install.is_installed(name), "a listed executable that does not resolve")

        vim.fn.mkdir(paths.bin(), "p")
        local target = dir .. "/run"
        vim.fn.writefile({ "#!/bin/sh" }, target)
        vim.uv.fs_symlink(target, paths.bin() .. "/" .. name)
        eq(true, install.is_installed(name), "directory, receipt and executable all there")

        store.receipt_remove(name)
    end)
end)

it("a non-npm package whose declared entries are not linked by design still counts", function()
    local name = "lvim-test-pypi-" .. vim.uv.hrtime()
    local dir = paths.package_dir(name)
    vim.fn.mkdir(dir .. "/venv", "p")
    local saved = registry.get
    registry.get = function(n)
        if n == name then
            return { name = name, bin = { [name] = "pyvenv:" .. name } }
        end
        return saved(n)
    end
    store.receipt_set(name, { type = "pypi", version = "1", bins = {} })
    local ok = install.is_installed(name)
    registry.get = saved
    store.receipt_remove(name)
    eq(true, ok, "pyvenv: entries run through the venv, they are not linked")
end)
