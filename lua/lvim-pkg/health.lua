-- lvim-pkg: :checkhealth lvim-pkg
--
-- Verifies the pieces lvim-pkg needs to install and run packages without
-- mason.nvim / nvim-treesitter: a writable install root wired onto PATH +
-- runtimepath, the download/extract + compiler toolchain, the per-source
-- install toolchains (npm / pip / go / cargo / git) and the cached catalogues.
-- lvim-pkg has no Lua-plugin dependencies (state is plain JSON, not sqlite).
--
---@module "lvim-pkg.health"

local config = require("lvim-pkg.config")
local paths = require("lvim-pkg.paths")

local M = {}

--- Report an executable: ok when present, otherwise `level` (warn/error) with `why`.
---@param h table              vim.health
---@param exe string           executable name
---@param why string           what it enables / why it matters
---@param level? "warn"|"error"  severity when missing (default "warn")
local function tool(h, exe, why, level)
    if vim.fn.executable(exe) == 1 then
        h.ok(("%s — %s"):format(exe, why))
    elseif level == "error" then
        h.error(("%s missing — %s"):format(exe, why))
    else
        h.warn(("%s missing — %s"):format(exe, why))
    end
end

function M.check()
    local h = vim.health

    -- ── core ──────────────────────────────────────────────────────────────────
    h.start("lvim-pkg: core")

    if vim.fn.has("nvim-0.10") == 1 then
        h.ok("Neovim >= 0.10")
    else
        h.error("Neovim >= 0.10 is required (vim.system, vim.uv, vim.fs)")
    end

    -- Install state is plain JSON under the root (state.json + snapshot files); a readable
    -- vim.json + the writable-root check below are all that is needed — no sqlite, no deps.
    if type(vim.json) == "table" then
        h.ok("state store: JSON under the install root (no external dependency)")
    end

    -- ── install root: layout, write access, PATH, runtimepath ─────────────────
    h.start("lvim-pkg: install root")

    local root = config.root
    if vim.fn.isdirectory(root) == 1 then
        h.ok("root: " .. root)
    else
        h.info("root not created yet (made on first setup): " .. root)
    end

    -- Writability probe in the configured root's parent (root itself may be absent).
    local probe = (vim.fn.isdirectory(root) == 1 and root or vim.fn.fnamemodify(root, ":h")) .. "/.lvim-pkg-health"
    local fd = io.open(probe, "w")
    if fd then
        fd:close()
        os.remove(probe)
        h.ok("install root is writable")
    else
        h.error("install root is NOT writable: " .. root)
    end

    local sep = vim.fn.has("win32") == 1 and ";" or ":"
    local bin = paths.bin()
    if ("" .. sep .. (vim.env.PATH or "") .. sep):find(sep .. bin .. sep, 1, true) then
        h.ok("bin/ is on $PATH: " .. bin)
    else
        h.warn("bin/ not on $PATH — installed tools will not resolve (setup() calls paths.ensure_path)")
    end

    local ts_parser = paths.ts() .. "/parser"
    if (vim.o.runtimepath .. ","):find(vim.pesc(paths.ts()) .. ",", 1, false) or vim.fn.isdirectory(ts_parser) == 1 then
        h.ok("treesitter install dir on runtimepath: " .. paths.ts())
    else
        h.info("treesitter install dir not on runtimepath yet (added on setup): " .. paths.ts())
    end

    -- ── download / extract / compile toolchain ────────────────────────────────
    h.start("lvim-pkg: toolchain")

    tool(h, "curl", "downloads every catalogue, archive and binary", "error")
    tool(h, "tar", "extracts .tar.gz / .tar.xz / .tar archives")
    tool(h, "unzip", "extracts .zip archives (registry catalogue, some packages)")
    tool(h, "cc", "compiles treesitter grammars (parser.c -> .so)")
    tool(h, "tree-sitter", "generates parser.c for grammars that ship only grammar.js (auto-installed by ensure_cli)")

    -- ── per-source install toolchains (Mason packages) ────────────────────────
    h.start("lvim-pkg: package sources")

    tool(h, "git", "github-source packages and all plugin (vim.pack) operations", "error")
    tool(h, "npm", "npm-source packages (many LSP servers / formatters)")
    if vim.fn.executable("python3") == 1 or vim.fn.executable("python") == 1 then
        h.ok("python3/python — pypi-source packages (pip install)")
    else
        h.warn("python3/python missing — pypi-source packages cannot be installed")
    end
    tool(h, "go", "golang-source packages")
    tool(h, "cargo", "cargo-source packages (Rust tools)")

    -- ── catalogues ────────────────────────────────────────────────────────────
    h.start("lvim-pkg: catalogues")

    local mason_cat = paths.registry_file()
    if vim.fn.filereadable(mason_cat) == 1 then
        h.ok("mason catalogue cached: " .. mason_cat)
    else
        h.info("mason catalogue not cached yet — downloaded on demand")
    end

    local ts_cat = paths.ts_registry_file()
    if vim.fn.filereadable(ts_cat) == 1 then
        h.ok("parser catalogue cached: " .. ts_cat)
    else
        h.info("parser catalogue not cached yet — downloaded on demand")
    end
end

return M
