-- lvim-pkg.trace: a timestamped trace of the install, written to a file as it happens.
--
-- WHY A FILE AND NOT MESSAGES. What this exists to diagnose is the editor NOT ANSWERING — a stall
-- during a first install. Anything that renders (`:messages`, a notification, a panel) is exactly
-- what stops updating while the loop is blocked, so it cannot describe its own blockage. A line
-- appended to a file survives a freeze, a crash and a kill, and it carries the one number that
-- matters: the gap since the previous line.
--
-- OFF unless `LVIM_TRACE` is set, so it costs a single env lookup on a normal start:
--
--     LVIM_TRACE=1 nvim            → ~/.cache/nvim/lvim-install-trace.log
--     LVIM_TRACE=/tmp/t.log nvim   → that path
--
---@module "lvim-pkg.trace"

local M = {}

---@type string|nil  the resolved log path, or nil when tracing is off
local path = nil
---@type integer|nil  hrtime at the first call — everything is relative to it
local first = nil
---@type integer|nil  hrtime of the previous line, for the gap
local prev = nil
---@type boolean  the env has been consulted
local probed = false

--- Resolve the target once. An explicit value that is not "1"/"true"/"yes" is taken as a PATH, so
--- a trace can be dropped anywhere writable without touching the config.
---@return string|nil
local function target()
    if probed then
        return path
    end
    probed = true
    local v = vim.env.LVIM_TRACE
    if v == nil or v == "" or v == "0" or v == "false" then
        return nil
    end
    if v == "1" or v == "true" or v == "yes" then
        path = vim.fn.stdpath("cache") .. "/lvim-install-trace.log"
    else
        path = v
    end
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    -- Truncate: one run, one trace. An appended file from three runs ago is worse than none.
    pcall(vim.fn.writefile, {}, path)
    return path
end

--- Record one event. The line carries the time since the first event and the GAP since the
--- previous one — a gap is what a blocked loop looks like from the outside.
---@param fmt string
---@param ... any
---@return nil
function M.log(fmt, ...)
    local file = target()
    if file == nil then
        return
    end
    local now = vim.uv.hrtime()
    first = first or now
    local gap = prev and ((now - prev) / 1e6) or 0
    prev = now
    local ok, msg = pcall(string.format, fmt, ...)
    local line = ("%8.1f  +%7.1f  %s"):format((now - first) / 1e6, gap, ok and msg or fmt)
    -- Appended one line at a time and closed immediately: a trace that is buffered is a trace that
    -- is lost exactly when the process dies mid-freeze.
    local fh = io.open(file, "a")
    if fh then
        fh:write(line, "\n")
        fh:close()
    end
end

--- Is tracing on? For a caller that would otherwise build an expensive message.
---@return boolean
function M.enabled()
    return target() ~= nil
end

--- The path being written, for a message that tells the reader where to look.
---@return string|nil
function M.path()
    return target()
end

return M
