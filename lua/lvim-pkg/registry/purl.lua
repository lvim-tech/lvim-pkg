-- lvim-pkg: package-URL (purl) parser for Mason registry source ids.
-- Mason sources look like "pkg:type/namespace/name@version" where the namespace
-- may itself contain slashes (e.g. golang "golang.org/x/tools/gopls") and the
-- name may be npm-scoped ("@vue/language-server").
--
---@module "lvim-pkg.registry.purl"

local M = {}

--- Percent-decode a purl component (e.g. "%40scope" → "@scope"). purl components are
--- percent-encoded; npm scopes in particular arrive as "%40tailwindcss/language-server".
---@param s string|nil
---@return string|nil
local function decode(s)
    if type(s) ~= "string" then
        return s
    end
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

---@class LvimPkgPurl
---@field type    string   Source type: npm | pypi | golang | cargo | github | ...
---@field name    string   Type-specific identifier (package / module / owner-repo)
---@field version string|nil  Pinned version, if present
---@field subpath string|nil  Subpath after '#' (e.g. golang "cmd/dlv" — the command
---                           package inside the module)

--- Parse a purl id into its components.
---@param id string  e.g. "pkg:github/owner/repo@v1.2.3"
---@return LvimPkgPurl|nil
function M.parse(id)
    if type(id) ~= "string" then
        return nil
    end
    local body = id:gsub("^pkg:", "")
    local typ, rest = body:match("^([^/]+)/(.+)$")
    if not typ then
        return nil
    end
    -- The subpath (#frag) is the command package inside a module (e.g. golang "cmd/dlv").
    local subpath = rest:match("#(.+)$")
    -- Strip qualifiers / subpath (?a=b or #frag) before reading the version.
    rest = rest:gsub("[?#].*$", "")
    local name, version = rest, nil
    -- The version separator is the last '@' (scoped npm names start with '@').
    local at = rest:find("@[^@/]*$")
    if at and at > 1 then
        name = rest:sub(1, at - 1)
        version = rest:sub(at + 1)
    end
    return { type = typ, name = decode(name), version = decode(version), subpath = decode(subpath) }
end

return M
