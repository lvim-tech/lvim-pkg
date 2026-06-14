-- lvim-pkg: tree-sitter CLI bootstrap.
-- The treesitter backend compiles parsers locally and needs the `tree-sitter`
-- CLI on PATH.  When it is missing we install the `tree-sitter-cli` package
-- through OUR OWN Mason backend — which resolves it from the mason-registry
-- CATALOGUE lvim-pkg fetches itself and installs via lvim-pkg.install.  We never
-- touch mason.nvim's runtime (`require("mason-registry")`), so there is no
-- dependency on the mason.nvim plugin.  Our bin/ is already on PATH
-- (paths.ensure_path), so the freshly linked binary resolves after the install.
--
---@module "lvim-pkg.core.cli"

local M = {}

--- Ensure the tree-sitter CLI is available, then invoke `cb`.
--- Never blocks: if the CLI is missing and cannot be installed, `cb` still runs
--- so already-compiled parsers keep working.
---@param cb fun()
function M.ensure(cb)
    if vim.fn.executable("tree-sitter") == 1 then
        return cb()
    end
    local ok, mason = pcall(require, "lvim-pkg.backends.mason")
    if not ok then
        return cb()
    end
    -- Already installed into our own path (perhaps not yet resolvable this session).
    if mason.is_installed("tree-sitter-cli") then
        return cb()
    end
    mason.install({ "tree-sitter-cli" }, function()
        cb()
    end)
end

return M
