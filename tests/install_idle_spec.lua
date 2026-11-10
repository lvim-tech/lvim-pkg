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
