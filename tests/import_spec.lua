-- Packages copied in by another machine become ordinary installs.
--
-- A server without a C compiler (or go, or cargo) cannot build parsers and some packages. lvim-pack copies
-- the client's files into the root and writes import.json; `adopt` links the executables and records the
-- receipts, so nothing tries to build them again.

local paths = require("lvim-pkg.paths")
local store = require("lvim-pkg.store")
local import = require("lvim-pkg.import")

local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fd = assert(io.open(path, "w"))
    fd:write(text)
    fd:close()
end

describe("lvim-pkg: adopting copied packages")

it("links the executables, records the receipts, and removes import.json", function()
    local root = paths.root()
    write(root .. "/packages/sqls-test/sqls", "#!/bin/sh\n")
    write(root .. "/ts/parser/lvimtestlang.so", "")
    write(
        root .. "/" .. import.FILE,
        vim.json.encode({
            ["sqls-test"] = { type = "golang", version = "v0.2.28", links = { sqls = "packages/sqls-test/sqls" } },
            ["ts:lvimtestlang"] = { type = "parser", version = "abc123" },
        })
    )
    local adopted = import.adopt()
    eq({ "sqls-test", "ts:lvimtestlang" }, adopted)
    eq(root .. "/packages/sqls-test/sqls", vim.uv.fs_readlink(paths.bin() .. "/sqls"))
    local r = store.receipt_get("sqls-test")
    eq("golang", r.type)
    eq("v0.2.28", r.version)
    eq({ "sqls" }, r.bins)
    eq("abc123", store.receipt_get("ts:lvimtestlang").version)
    eq(0, vim.fn.filereadable(root .. "/" .. import.FILE), "adopted once")
    eq({}, import.adopt(), "nothing left to adopt")
end)

it("refuses links that leave the root or are not plain names", function()
    local root = paths.root()
    write(
        root .. "/" .. import.FILE,
        vim.json.encode({
            evil = {
                type = "golang",
                links = { ["../x"] = "packages/a/a", ok = "../../etc/passwd", abs = "/etc/passwd" },
            },
        })
    )
    eq({ "evil" }, import.adopt())
    eq({}, store.receipt_get("evil").bins)
    eq(nil, vim.uv.fs_lstat(paths.bin() .. "/ok"))
    eq(nil, vim.uv.fs_lstat(paths.bin() .. "/abs"))
end)

it("ignores a broken file", function()
    write(paths.root() .. "/" .. import.FILE, "{not json")
    eq({}, import.adopt())
    eq(0, vim.fn.filereadable(paths.root() .. "/" .. import.FILE))
end)

describe("lvim-pkg: finding a compiler, and saying when there is none")

it("takes the first C compiler there is, and a missing tool is named plainly", function()
    local ts = require("lvim-pkg.backends.ts")
    local saved = ts.CC
    ts.CC = { "lvim-no-such-cc", "sh" }
    eq("sh", ts.compiler(false))
    ts.CC = { "lvim-no-such-cc" }
    eq(nil, ts.compiler(false))
    ts.CC = saved

    local done, err = false, nil
    require("lvim-pkg.install.util").run({ "lvim-no-such-cc", "-v" }, { idle_timeout = 0 }, function(e)
        done, err = true, e
    end)
    vim.wait(5000, function()
        return done
    end, 10)
    eq("lvim-no-such-cc is not installed on this machine", err)
end)

describe("lvim-pkg: remembering what could not be built here")

it("a missing tool is wanted until a copy is adopted", function()
    local root = paths.root()
    eq(true, import.missing_tool("go is not installed on this machine"))
    eq(true, import.missing_tool("no C compiler on this machine (looked for cc, gcc, clang)"))
    eq(false, import.missing_tool("exit 1"))
    import.want("gopls-test")
    import.want("gopls-test")
    eq({ ["gopls-test"] = true }, vim.json.decode(table.concat(vim.fn.readfile(root .. "/" .. import.WANTED), "")))
    vim.fn.writefile(
        { vim.json.encode({ ["gopls-test"] = { type = "golang", version = "v1" } }) },
        root .. "/" .. import.FILE
    )
    eq({ "gopls-test" }, import.adopt())
    eq(0, vim.fn.filereadable(root .. "/" .. import.WANTED), "no longer wanted")
end)
