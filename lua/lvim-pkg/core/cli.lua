-- lvim-pkg: tree-sitter CLI bootstrap.
-- The nvim-treesitter rewrite compiles parsers locally and needs the
-- `tree-sitter` CLI on PATH.  When it is missing we install the Mason
-- `tree-sitter-cli` package directly (Mason prepends its bin dir to PATH), then
-- continue.
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
    local ok, registry = pcall(require, "mason-registry")
    if not ok then
        return cb()
    end
    local pok, pkg = pcall(registry.get_package, "tree-sitter-cli")
    if not pok then
        return cb()
    end
    if pkg:is_installed() then
        return cb()
    end
    local handle = pkg:install()
    handle:once("closed", vim.schedule_wrap(cb))
end

return M
