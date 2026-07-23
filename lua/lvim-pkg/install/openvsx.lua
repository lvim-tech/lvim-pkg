-- lvim-pkg: "openvsx" source installer.
-- Mason's `openvsx` source is a VS Code extension published to the Open VSX registry (open-vsx.org).
-- The purl `pkg:openvsx/<namespace>/<name>@<version>` + `source.download.file` (a `.vsix` filename
-- template) resolve to the Open VSX file API; a `.vsix` is a ZIP, so we download it and extract it into
-- the package dir. These extensions usually carry NO executable — they are jar BUNDLES a language
-- server loads (e.g. java-debug-adapter / java-test, whose jars jdtls loads through `init_options.bundles`)
-- — so the consumer globs the extracted jars from the package dir; a `bin` map, when present, is linked.
--
---@module "lvim-pkg.install.openvsx"

local util = require("lvim-pkg.install.util")

local M = {}

---@param ctx table
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
    local download = ctx.spec.source.download or {}
    local version = ctx.purl.version or ""
    local file = tostring(download.file or ""):gsub("{{%s*version%s*}}", version)
    if file == "" then
        cb("openvsx source declares no download file")
        return
    end
    -- purl.name carries the full "<namespace>/<name>" path.
    local namespace, name = (ctx.purl.name or ""):match("^(.-)/(.+)$")
    if not namespace then
        cb("openvsx: malformed package id '" .. tostring(ctx.purl.name) .. "' (expected namespace/name)")
        return
    end

    -- The Open VSX file API: /api/{namespace}/{name}/{version}/file/{filename}. Download the `.vsix` to a
    -- `.zip` local name so the shared extractor (which dispatches on extension) treats it as the zip it is.
    local url = ("https://open-vsx.org/api/%s/%s/%s/file/%s"):format(namespace, name, version, file)
    local dest = ctx.dir .. "/" .. file:gsub("%.vsix$", "") .. ".zip"

    ctx.progress("download " .. file)
    util.download(url, dest, function(err)
        if err then
            cb("download: " .. err)
            return
        end
        ctx.progress("extract")
        util.extract(dest, ctx.dir, function(e2)
            if e2 then
                cb("extract: " .. e2)
                return
            end
            vim.fn.delete(dest)
            -- Most bundles carry no bin; link one if the package declares it.
            for binname, tmpl in pairs(ctx.spec.bin or {}) do
                util.link_bin(ctx, binname, tostring(tmpl))
            end
            cb(nil)
        end)
    end)
end

return M
