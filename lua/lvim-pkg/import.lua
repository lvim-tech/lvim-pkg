-- lvim-pkg: adopt packages another machine copied in because this one cannot build them.
--
-- A server reached through `:connect ssh://` installs its own tools, but some installs compile: a
-- tree-sitter parser needs a C compiler, a Go or Rust package needs `go` or `cargo`. A server without
-- the toolchain cannot produce them. lvim-pack then copies the client's built files into this root (the
-- same layout: `ts/parser/<lang>.so`, `ts/queries/<lang>/`, `packages/<name>/`) and writes
-- `import.json`: per package its receipt and, for each executable, the file under the root it runs.
-- `adopt` turns that into an ordinary install here: the links in `bin/` and the receipts, so nothing
-- tries to compile them again.
--
---@module "lvim-pkg.import"

local paths = require("lvim-pkg.paths")
local store = require("lvim-pkg.store")
local util = require("lvim-pkg.install.util")

local M = {}

M.FILE = "import.json"

--- Packages this machine tried to install and could not build (its toolchain is missing): the client copies
--- them on the next connect. name → true.
M.WANTED = "wanted.json"

---@return table<string, boolean>
local function read_wanted()
    local fd = io.open(paths.root() .. "/" .. M.WANTED, "r")
    if not fd then
        return {}
    end
    local raw = fd:read("*a")
    fd:close()
    local ok, data = pcall(vim.json.decode, raw or "")
    return (ok and type(data) == "table") and data or {}
end

---@param data table<string, boolean>
local function write_wanted(data)
    local file = paths.root() .. "/" .. M.WANTED
    if vim.tbl_isempty(data) then
        os.remove(file)
        return
    end
    vim.fn.mkdir(paths.root(), "p")
    local fd = io.open(file, "w")
    if fd then
        fd:write(vim.json.encode(data))
        fd:close()
    end
end

--- Whether an install error says a build tool is missing here (see install.util.run and the parser compile).
---@param err string|nil
---@return boolean
function M.missing_tool(err)
    err = tostring(err or "")
    return err:find("is not installed on this machine", 1, true) ~= nil
        or err:find("compiler on this machine", 1, true) ~= nil
end

--- Remember that `name` could not be built here, so a client copies it.
---@param name string
function M.want(name)
    local data = read_wanted()
    if not data[name] then
        data[name] = true
        write_wanted(data)
    end
end

-- ── Asking the client while the session runs ─────────────────────────────────
--
-- On the server end of `:connect ssh://`, the client that connected is still running (it holds the
-- tunnel) and follows `requests` (lvim-pack's `serve_requests`). A package this server cannot build is
-- offered to the user at once; a "yes" appends its name there, the client builds it and copies it in,
-- and the `import.json` it writes is adopted here as soon as it appears. A client that failed writes
-- `failed.json` instead (name → reason).

M.REQUESTS = "requests"
M.FAILED = "failed.json"

--- Why this Neovim started (`v:startreason`), or nil. Tests replace it.
---@return string|nil
function M.start_reason()
    local ok, reason = pcall(function()
        return vim.v.startreason
    end)
    return ok and reason or nil
end

--- Ask the user. Tests replace it.
---@param message string
---@return boolean
function M.confirm(message)
    return vim.fn.confirm(message, "&Yes\n&No", 1) == 1
end

local asked = {} ---@type table<string, boolean>  offered in this session (yes or no)
local queue = {} ---@type string[]
local queued_at = nil ---@type uv.uv_timer_t|nil

--- Append names to the requests the client follows.
---@param names string[]
local function request(names)
    vim.fn.mkdir(paths.root(), "p")
    local fd = io.open(paths.root() .. "/" .. M.REQUESTS, "a")
    if fd then
        fd:write(table.concat(names, "\n") .. "\n")
        fd:close()
    end
end

--- Offer what is queued, in one question (several parsers fail together when a file opens).
local function offer()
    local names = queue
    queue = {}
    if #names == 0 then
        return
    end
    table.sort(names)
    local msg = ("This server has no toolchain to build: %s.\nBuild on your machine and send it now?"):format(
        table.concat(names, ", ")
    )
    if M.confirm(msg) then
        request(names)
        vim.notify("lvim-pkg: building on your machine: " .. table.concat(names, ", "), vim.log.levels.INFO)
    end
end

--- `name` (a package, or `ts:<lang>`) could not be built here for want of a tool: remember it for the next
--- connect, and on a remote-ssh server offer to have the client build and send it now.
---@param name string
function M.missing(name)
    pcall(M.want, name)
    if M.start_reason() ~= "remote-ssh" or asked[name] then
        return
    end
    asked[name] = true
    queue[#queue + 1] = name
    if queued_at then
        return
    end
    queued_at = vim.defer_fn(function()
        queued_at = nil
        offer()
    end, 300)
end

--- Report what a client could not build, once.
local function read_failed()
    local file = paths.root() .. "/" .. M.FAILED
    local fd = io.open(file, "r")
    if not fd then
        return
    end
    local raw = fd:read("*a")
    fd:close()
    os.remove(file)
    local ok, data = pcall(vim.json.decode, raw or "")
    if not ok or type(data) ~= "table" then
        return
    end
    for name, reason in pairs(data) do
        vim.notify(
            ("lvim-pkg: your machine could not build %s: %s"):format(name, tostring(reason)),
            vim.log.levels.ERROR
        )
    end
end

--- Adopt now, and let what was adopted take effect in the open buffers: FileType runs again, which
--- starts a parser or a language server that was missing when the buffer opened.
local function adopt_and_apply()
    local adopted = M.adopt()
    if #adopted == 0 then
        return
    end
    vim.notify("lvim-pkg: received from your machine: " .. table.concat(adopted, ", "), vim.log.levels.INFO)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" and vim.bo[buf].buftype == "" then
            pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = buf, modeline = false })
        end
    end
end

local watcher = nil ---@type uv.uv_fs_event_t|nil

--- On a remote-ssh server: watch the root for what a client sends while the session runs.
---@return boolean watching
function M.watch()
    if watcher or M.start_reason() ~= "remote-ssh" then
        return watcher ~= nil
    end
    local root = paths.root()
    vim.fn.mkdir(root, "p")
    watcher = vim.uv.new_fs_event()
    if not watcher then
        return false
    end
    local pending = false
    local ok = watcher:start(root, {}, function(_, filename)
        if (filename ~= M.FILE and filename ~= M.FAILED) or pending then
            return
        end
        pending = true
        vim.defer_fn(function()
            pending = false
            read_failed()
            adopt_and_apply()
        end, 200)
    end)
    if ok ~= 0 then
        watcher:close()
        watcher = nil
        return false
    end
    return true
end

---@class LvimPkgImport
---@field type string
---@field version string|nil
---@field bins string[]|nil
---@field links table<string, string>|nil  executable name → file relative to the root

--- Adopt what was copied in, once: the file is removed afterwards.
---@return string[] adopted  the package names, sorted
function M.adopt()
    local file = paths.root() .. "/" .. M.FILE
    local fd = io.open(file, "r")
    if not fd then
        return {}
    end
    local raw = fd:read("*a")
    fd:close()
    local ok, data = pcall(vim.json.decode, raw or "")
    os.remove(file)
    if not ok or type(data) ~= "table" then
        return {}
    end
    paths.ensure()
    local adopted = {}
    for name, r in pairs(data) do
        if type(name) == "string" and type(r) == "table" and type(r.type) == "string" then
            local bins = {}
            for bin, rel in pairs(type(r.links) == "table" and r.links or {}) do
                -- Only names and paths inside the root: the file came over the network.
                if
                    type(bin) == "string"
                    and type(rel) == "string"
                    and bin:match("^[%w][%w%._%-]*$")
                    and not rel:find("%.%.")
                    and not vim.startswith(rel, "/")
                    and util.symlink(paths.root() .. "/" .. rel, paths.bin() .. "/" .. bin)
                then
                    bins[#bins + 1] = bin
                end
            end
            table.sort(bins)
            store.receipt_set(name, { type = r.type, version = r.version, bins = bins })
            adopted[#adopted + 1] = name
        end
    end
    table.sort(adopted)
    local wanted = read_wanted()
    for _, name in ipairs(adopted) do
        wanted[name] = nil
    end
    write_wanted(wanted)
    return adopted
end

return M
