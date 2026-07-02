-- lvim-pkg: filesystem layout for the self-contained installer.
-- Everything lvim-pkg manages lives under one configurable root (set via
-- require("lvim-pkg").setup({ root = ... })), with a subfolder per kind:
--   packages/  Mason-style binary packages (one subdir each)
--   bin/       linked executables (added to PATH)
--   ts/        OUR tree-sitter dir (ts/parser/*.so + ts/queries, added to rtp) —
--              it mirrors nvim-treesitter's install_dir layout, but lvim-pkg is
--              self-contained WITHOUT nvim-treesitter.
-- (Neovim plugins are NOT here — vim.pack owns them under site/pack/core/opt.)
--
---@module "lvim-pkg.paths"

local config = require("lvim-pkg.config")

local M = {}

--- The configured install root.
---@return string
local function root()
    return config.root
end

---@return string  Installer root directory
function M.root()
    return root()
end

---@return string  Directory holding one subdirectory per installed package
function M.packages()
    return root() .. "/packages"
end

---@return string  Directory holding linked executables (added to PATH)
function M.bin()
    return root() .. "/bin"
end

---@return string  Our tree-sitter dir (parsers under ts/parser, queries under ts/queries),
---                mirroring nvim-treesitter's install_dir layout but managed by lvim-pkg itself
function M.ts()
    return root() .. "/ts"
end

---@param name string
---@return string  Install directory for a package
function M.package_dir(name)
    return M.packages() .. "/" .. name
end

---@return string  Local cached Mason registry index
function M.registry_file()
    return root() .. "/registry.json"
end

---@return string  Local cached tree-sitter parser registry index
function M.ts_registry_file()
    return root() .. "/ts-registry.json"
end

--- Create the managed subdirectories if missing.
---@return nil
function M.ensure()
    vim.fn.mkdir(M.packages(), "p")
    vim.fn.mkdir(M.bin(), "p")
    vim.fn.mkdir(M.ts(), "p")
end

--- Prepend our bin/ to PATH for the current session so installed tools resolve.
---@return nil
function M.ensure_path()
    local bin = M.bin()
    if bin == "" or vim.fn.isdirectory(bin) == 0 then
        return
    end
    local sep = vim.fn.has("win32") == 1 and ";" or ":"
    local path = vim.env.PATH or ""
    if not ("" .. sep .. path .. sep):find(sep .. bin .. sep, 1, true) then
        vim.env.PATH = bin .. sep .. path
    end
end

return M
