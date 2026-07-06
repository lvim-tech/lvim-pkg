-- lvim-pkg: platform target resolution for GitHub release assets.
-- Maps the current OS/arch/libc to Mason's target strings (e.g. "linux_x64_gnu")
-- and picks the best-matching asset entry from a package's asset matrix.
--
---@module "lvim-pkg.install.target"

local M = {}

--- Detect (os, arch) using Mason's vocabulary.
---@return string osname  linux | darwin | win | <raw>
---@return string arch    x64 | arm64 | arm | x86 | <raw>
local function detect()
    local uname = vim.uv.os_uname()
    local sysname = (uname.sysname or ""):lower()
    local machine = (uname.machine or ""):lower()
    local osname
    if sysname:find("linux") then
        osname = "linux"
    elseif sysname:find("darwin") then
        osname = "darwin"
    elseif sysname:find("windows") then
        osname = "win"
    else
        osname = sysname
    end
    local arch
    if machine == "x86_64" or machine == "amd64" then
        arch = "x64"
    elseif machine == "aarch64" or machine == "arm64" then
        arch = "arm64"
    elseif machine:find("arm") then
        arch = "arm"
    elseif machine == "i386" or machine == "i686" then
        arch = "x86"
    else
        arch = machine
    end
    return osname, arch
end

---@type string|nil  memoized libc kind (cannot change within a session)
local libc_cache = nil

--- Detect the C library on Linux (gnu vs musl). Memoized — the first call spawns `ldd
--- --version`; every later call (once per install target resolution) returns the cached value.
---@return string  "gnu" | "musl"
local function libc()
    if libc_cache then
        return libc_cache
    end
    local kind = "gnu"
    if vim.fn.executable("ldd") == 1 then
        local out = vim.fn.system({ "ldd", "--version" })
        if type(out) == "string" and out:lower():find("musl") then
            kind = "musl"
        end
    end
    if kind == "gnu" and vim.fn.glob("/lib/ld-musl*") ~= "" then
        kind = "musl"
    end
    libc_cache = kind
    return kind
end

--- Current (os, arch).
---@return string osname
---@return string arch
function M.current()
    return detect()
end

--- Acceptable target strings for this platform, most specific first.
---@return string[]
function M.acceptable()
    local osname, arch = detect()
    if osname == "linux" then
        if libc() == "musl" then
            return { osname .. "_" .. arch .. "_musl", osname .. "_" .. arch .. "_gnu", osname .. "_" .. arch, osname }
        end
        return { osname .. "_" .. arch .. "_gnu", osname .. "_" .. arch, osname }
    end
    return { osname .. "_" .. arch, osname }
end

--- Pick the asset entry matching the current platform from an asset matrix, or a single
--- platform-independent asset object. Each entry's `target` may be a string or a list.
---@param assets table[]|table|nil
---@return table|nil  The chosen asset entry
function M.pick_asset(assets)
    if type(assets) ~= "table" then
        return nil
    end
    -- A single asset object (e.g. { file = ... }) rather than a per-platform list:
    -- platform-independent packages (e.g. node-based adapters) ship one asset.
    if assets.file or assets.target then
        assets = { assets }
    end
    local prio = {}
    for i, t in ipairs(M.acceptable()) do
        prio[t] = i
    end
    local best, best_p = nil, math.huge
    local untargeted = nil
    for _, entry in ipairs(assets) do
        local targets = entry.target
        if targets == nil then
            -- No target → usable on any platform; keep as a fallback.
            untargeted = untargeted or entry
        else
            if type(targets) == "string" then
                targets = { targets }
            end
            for _, t in ipairs(targets) do
                local p = prio[t]
                if p and p < best_p then
                    best_p = p
                    best = entry
                end
            end
        end
    end
    return best or untargeted
end

return M
