-- How a dev checkout stands against its remote.
--
-- The 65 dev checkouts were skipped by the update check, so the panel could not show that one was behind
-- GitHub, or carried commits nobody had pushed. L.check_local answers that without touching the repository
-- (no fetch). Real repositories: a bare "origin", a clone, and a second clone that pushes to it.

local loader = require("lvim-pkg.loader")

if vim.fn.executable("git") ~= 1 then
    skip("dev checkouts against their remote", "git is needed")
    return
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

--- Run git in `dir`, failing loudly.
local function git(dir, ...)
    local r = vim.system(
        vim.list_extend({ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t" }, { ... }),
        { text = true }
    ):wait()
    assert(r.code == 0, table.concat({ ... }, " ") .. ": " .. (r.stderr or ""))
    return vim.trim(r.stdout or "")
end

local origin, here, other = root .. "/origin.git", root .. "/here", root .. "/other"
vim.system({ "git", "init", "-q", "--bare", "-b", "main", origin }):wait()
vim.system({ "git", "clone", "-q", origin, here }):wait()
git(here, "checkout", "-q", "-b", "main")
vim.fn.writefile({ "1" }, here .. "/f")
git(here, "add", "f")
git(here, "commit", "-qm", "one")
git(here, "push", "-q", "origin", "main")
vim.system({ "git", "clone", "-q", origin, other }):wait()

--- check_local, waited for.
local function state()
    local got, done = nil, false
    loader.check_local(here, function(st)
        got, done = st, true
    end)
    vim.wait(10000, function()
        return done
    end, 10)
    return got
end

describe("lvim-pkg: a dev checkout against its remote")

it("level with its remote and clean", function()
    eq({ behind = 0, ahead = 0, dirty = false }, state())
end)

it("uncommitted changes, and commits nobody pushed", function()
    vim.fn.writefile({ "2" }, here .. "/f")
    eq(true, state().dirty)
    git(here, "commit", "-qam", "two")
    git(here, "commit", "-q", "--allow-empty", "-m", "three")
    eq({ behind = 0, ahead = 2, dirty = false }, state())
end)

it("new commits on the remote it has not fetched: behind, count unknown", function()
    vim.fn.writefile({ "x" }, other .. "/g")
    git(other, "add", "g")
    git(other, "commit", "-qm", "upstream")
    git(other, "push", "-q", "origin", "HEAD:main")
    local st = state()
    eq("?", st.behind)
    eq(2, st.ahead, "still counted against the last fetched origin/main")
end)

it("once fetched, the exact counts, and the repository was not touched by the check", function()
    local before = git(here, "rev-parse", "origin/main")
    state()
    eq(before, git(here, "rev-parse", "origin/main"), "the check fetched nothing")
    git(here, "fetch", "-q", "origin")
    eq({ behind = 1, ahead = 2, dirty = false }, state())
end)

it("a detached HEAD or no origin: nothing to report", function()
    local lone = root .. "/lone"
    vim.fn.mkdir(lone, "p")
    git(lone, "init", "-q", "-b", "main")
    git(lone, "commit", "-q", "--allow-empty", "-m", "x")
    local got, done = 1, false
    loader.check_local(lone, function(st)
        got, done = st, true
    end)
    vim.wait(5000, function()
        return done
    end, 10)
    eq(nil, got)
end)
