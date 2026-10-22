-- One configurable root, and every managed path derived from it.
--
-- Everything lvim-pkg installs lives under `config.root`: packages/ per package, bin/ for the
-- linked executables that go on PATH, ts/ for the parsers that go on the runtimepath. A derived
-- path that stops following a re-pointed root is how an installer writes outside the directory the
-- user gave it — so the whole point of the check is that NOTHING is remembered from load time.
--
-- The suite's XDG homes are a throwaway directory (see the Makefile), so the default root here is
-- already a sandbox, and the cases that re-point it clean up after themselves.

local paths = require("lvim-pkg.paths")
local config = require("lvim-pkg.config")

--- Run `fn` with `config.root` pointed at `dir`.
---@param dir string
---@param fn fun()
local function with_root(dir, fn)
    local saved = config.root
    config.root = dir
    local ok, err = pcall(fn)
    config.root = saved
    if not ok then
        error(err, 0)
    end
end

describe("lvim-pkg.paths")

it("puts every managed directory under the root", function()
    with_root("/tmp/lvim-pkg-test-root", function()
        eq("/tmp/lvim-pkg-test-root", paths.root())
        eq("/tmp/lvim-pkg-test-root/packages", paths.packages())
        eq("/tmp/lvim-pkg-test-root/bin", paths.bin())
        eq("/tmp/lvim-pkg-test-root/ts", paths.ts())
        eq("/tmp/lvim-pkg-test-root/registry.json", paths.registry_file())
        eq("/tmp/lvim-pkg-test-root/ts-registry.json", paths.ts_registry_file())
    end)
end)

it("follows the root when it is re-pointed, remembering nothing", function()
    with_root("/tmp/lvim-pkg-a", function()
        eq("/tmp/lvim-pkg-a/bin", paths.bin())
    end)
    with_root("/tmp/lvim-pkg-b", function()
        eq("/tmp/lvim-pkg-b/bin", paths.bin(), "a path cached at load time would still say /tmp/lvim-pkg-a")
    end)
end)

it("names a package's directory under packages/", function()
    with_root("/tmp/lvim-pkg-test-root", function()
        eq("/tmp/lvim-pkg-test-root/packages/lua-language-server", paths.package_dir("lua-language-server"))
    end)
end)

it("defaults the root inside the editor's data directory", function()
    -- Under `make test` that is the throwaway XDG home, which is also the proof that the suite
    -- cannot install into the real one.
    truthy(
        vim.startswith(vim.fs.normalize(config.root), vim.fs.normalize(vim.fn.stdpath("data"))),
        "the root is outside the data dir: " .. config.root
    )
end)

describe("lvim-pkg: what is installed")

it("answers about an unknown package without erroring", function()
    eq(false, require("lvim-pkg").is_installed("package", "lvim-no-such-package"))
    eq(false, require("lvim-pkg").is_installed("parser", "lvim_no_such_parser"))
end)

it("lists the installed names as a table, never nil", function()
    for _, kind in ipairs({ "package", "parser" }) do
        eq("table", type(require("lvim-pkg").installed(kind)), kind)
        eq("table", type(require("lvim-pkg").available(kind)), kind)
    end
end)

it("package_path points inside the managed packages directory", function()
    local p = require("lvim-pkg").package_path("some-package")
    truthy(
        p == nil or vim.startswith(vim.fs.normalize(p), vim.fs.normalize(paths.packages())),
        "got " .. tostring(p)
    )
end)
