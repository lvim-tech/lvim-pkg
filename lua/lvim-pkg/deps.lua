-- lvim-pkg: dependency graph resolver (lazy.nvim-style).
-- Expands the `dependencies` declared on plugin specs into the flat module map the
-- loader installs from: every dependency — recursively — becomes its own module entry
-- so vim.pack clones it (vim.pack does NOT auto-install dependencies), while load order
-- is preserved through the normalized `dependencies` name list.
--
-- A dependency may be a bare "owner/repo" string, or a spec table carrying its own
-- config/opts and version pin:
--     dependencies = {
--       "owner/repo",
--       { "owner/repo2", opts = {...}, config = fn, commit = "abc123" },
--     }
-- Its config/opts run when it loads (deps load before their parent), and any pin
-- (commit/version/branch) is kept. A dependency can also be pinned by name through the
-- snapshot, exactly like a top-level plugin (applied by the loader, not here).
--
-- Plugins that exist ONLY as a dependency are tagged `dependency = true` + `dep_of` so
-- the installer can mark them in the browser; plugins also declared at top level keep
-- their own (authoritative) spec and are never tagged.
--
---@module "lvim-pkg.deps"

local M = {}

--- Normalize one dependency entry to (repo, spec-without-the-repo).
---@param dep string|table
---@return string|nil repo, table spec
local function normalize(dep)
    if type(dep) == "string" then
        return dep, {}
    end
    if type(dep) == "table" and type(dep[1]) == "string" then
        local spec = {}
        for k, v in pairs(dep) do
            if k ~= 1 then
                spec[k] = v
            end
        end
        return dep[1], spec
    end
    return nil, {}
end

--- Expand every spec's `dependencies` into top-level module entries (recursively).
--- Mutates and returns `modules` (repo → spec). Cycle-safe.
---@param modules table<string, table>
---@return table<string, table>
function M.resolve(modules)
    local seen = {}

    local function visit(repo, spec)
        if seen[repo] then
            return
        end
        seen[repo] = true
        local deps = spec.dependencies
        if type(deps) ~= "table" or #deps == 0 then
            return
        end
        -- Normalize spec.dependencies to a flat list of repo strings, so the loader's
        -- existing `dep:match("([^/]+)$")` load-order walk keeps working.
        local names = {}
        for _, dep in ipairs(deps) do
            local drepo, dspec = normalize(dep)
            if drepo then
                names[#names + 1] = drepo
                if not modules[drepo] then
                    -- Pulled in only as a dependency: register it so vim.pack installs it.
                    dspec.dependency = true
                    dspec.dep_of = repo
                    modules[drepo] = dspec
                end
                visit(drepo, modules[drepo]) -- recurse (its own deps); seen-guarded
            end
        end
        spec.dependencies = names
    end

    -- Snapshot the original keys first; visit() inserts new ones as it goes.
    local roots = {}
    for repo, spec in pairs(modules) do
        if type(spec) == "table" then
            roots[#roots + 1] = repo
        end
    end
    for _, repo in ipairs(roots) do
        visit(repo, modules[repo])
    end
    return modules
end

return M
