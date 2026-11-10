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
