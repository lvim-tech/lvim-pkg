-- An install command that hangs is stopped, one that keeps working is not.
--
-- A remote `npm install` once sat for ten minutes with no CPU time, no socket and no log, and its package
-- showed "installing" until the editor closed. `util.run` now stops a command that writes nothing for
-- `idle_timeout`; the clock restarts on every chunk of output.

local util = require("lvim-pkg.install.util")

--- Run `cmd` through util.run and wait for the answer.
local function run(cmd, idle)
    local done, err = false, nil
    util.run(cmd, { idle_timeout = idle }, function(e)
        done, err = true, e
    end)
    vim.wait(10000, function()
        return done
    end, 10)
    return done, err
end

describe("lvim-pkg: install commands and the idle timeout")

it("a silent command past the limit is stopped and named", function()
    local done, err = run({ "sh", "-c", "sleep 30" }, 300)
    eq(true, done, "it does not wait for the sleep to end")
    truthy(err and err:find("stopped as hung", 1, true), tostring(err))
    truthy(err:find("sleep 30", 1, true), "the message names the command")
end)

it("a command that keeps writing outlives the limit", function()
    local done, err = run({ "sh", "-c", "for i in 1 2 3 4 5 6; do echo $i; sleep 0.1; done" }, 300)
    eq(true, done)
    eq(nil, err)
end)

it("a command that ignores SIGTERM is still stopped", function()
    local t = vim.uv.hrtime()
    local done, err = run({ "sh", "-c", "trap '' TERM; sleep 30" }, 200)
    eq(true, done)
    truthy(err and err:find("stopped as hung", 1, true), tostring(err))
    truthy((vim.uv.hrtime() - t) / 1e9 < 9, "SIGKILL follows")
end)

it("failure and success are reported as before", function()
    local _, err = run({ "sh", "-c", "echo boom >&2; exit 3" }, 0)
    eq("boom", err)
    _, err = run({ "sh", "-c", "exit 4" }, 0)
    eq("exit 4", err)
    _, err = run({ "true" }, 0)
    eq(nil, err)
    _, err = run({ "lvim-no-such-command-xyz" }, 0)
    truthy(err and err ~= "", "a command that cannot start is an error")
end)

describe("lvim-pkg: install commands are stopped with everything they started")

--- Whether process `pid` is still alive.
local function alive(pid)
    return vim.system({ "kill", "-0", tostring(pid) }):wait().code == 0
end

--- Wait for a pid written by the command into `file`.
local function read_pid(file)
    local pid
    vim.wait(5000, function()
        local f = io.open(file)
        pid = f and tonumber(f:read("*l") or "")
        if f then
            f:close()
        end
        return pid ~= nil
    end, 10)
    return pid
end

it("a hung command's children are stopped too", function()
    local file = vim.fn.tempname()
    local done, err = false, nil
    -- The child sleeps on; npm's install scripts are such children.
    util.run({ "sh", "-c", "sleep 30 & echo $! > " .. file .. "; wait" }, { idle_timeout = 300 }, function(e)
        done, err = true, e
    end)
    local child = read_pid(file)
    truthy(child, "the child started")
    vim.wait(10000, function()
        return done
    end, 10)
    truthy(err and err:find("stopped as hung", 1, true), tostring(err))
    vim.wait(2000, function()
        return not alive(child)
    end, 20)
    eq(false, alive(child), "the child did not outlive the command")
end)

it("stop_all ends every running command and its children, and none counts as a success", function()
    local file = vim.fn.tempname()
    local done, err = false, nil
    util.run({ "sh", "-c", "sleep 30 & echo $! > " .. file .. "; wait" }, { idle_timeout = 0 }, function(e)
        done, err = true, e
    end)
    local child = read_pid(file)
    truthy(child, "the child started")
    util.stop_all()
    vim.wait(5000, function()
        return done
    end, 10)
    eq(true, done)
    truthy(err ~= nil, "a stopped install is not reported as installed")
    vim.wait(2000, function()
        return not alive(child)
    end, 20)
    eq(false, alive(child), "the child did not outlive the command")
end)

describe("lvim-pkg: how many packages install at once")

it("is max_concurrency here and remote_concurrency on a :connect ssh:// server", function()
    local config = require("lvim-pkg.config")
    local saved_max, saved_remote = config.max_concurrency, config.remote_concurrency
    config.max_concurrency, config.remote_concurrency = 4, 1
    local ok, reason = pcall(function()
        return vim.v.startreason
    end)
    if ok and reason == "remote-ssh" then
        eq(1, util.concurrency())
    else
        eq(4, util.concurrency())
    end
    config.max_concurrency = 0
    config.remote_concurrency = 0
    eq(1, util.concurrency(), "never less than one")
    config.max_concurrency, config.remote_concurrency = saved_max, saved_remote
end)
