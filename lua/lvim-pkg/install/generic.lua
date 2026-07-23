-- lvim-pkg: "generic" source installer.
-- Mason's `generic` source ships a tool from an arbitrary host (not a package registry). Its
-- `source.download` is a PER-PLATFORM list — each entry a `{ target, files, … }` where `files` maps a
-- local filename to a URL template (`{{version}}` / `{{ version | strip_prefix "v" }}`). We pick the
-- entry matching this platform, fetch every file (a tarball plus side files like `lombok.jar`), extract
-- the archives in place, and link the package's `bin` through the shared launcher logic. jdtls (the
-- Eclipse JDT language server) is the canonical case — a `.tar.gz` + `lombok.jar`, bin `python:bin/jdtls`.
--
---@module "lvim-pkg.install.generic"

local util = require("lvim-pkg.install.util")
local target = require("lvim-pkg.install.target")

local M = {}

--- Is `file` a recognised archive (vs a raw side file kept in place, e.g. lombok.jar)?
---@param file string
---@return boolean
local function is_archive(file)
    local l = file:lower()
    return l:match("%.zip$") ~= nil
        or l:match("%.tar%.gz$") ~= nil
        or l:match("%.tgz$") ~= nil
        or l:match("%.tar%.xz$") ~= nil
        or l:match("%.txz$") ~= nil
        or l:match("%.tar$") ~= nil
        or l:match("%.gz$") ~= nil
end

--- Pick the download entry for this platform: a bare object (no per-platform split) wins outright;
--- otherwise the first list entry whose `target` (a string or list) matches one of this platform's
--- acceptable target strings, else a target-less catch-all entry.
---@param download table
---@return table|nil
local function pick(download)
    if download.files or download.file then
        return download -- a single, platform-independent object
    end
    local ok = {}
    for _, t in ipairs(target.acceptable()) do
        ok[t] = true
    end
    local fallback
    for _, entry in ipairs(download) do
        local tg = entry.target
        if tg == nil then
            fallback = fallback or entry
        else
            for _, t in ipairs(type(tg) == "table" and tg or { tg }) do
                if ok[t] then
                    return entry
                end
            end
        end
    end
    return fallback
end

---@param ctx table
---@param cb  fun(err: string|nil)
---@return nil
function M.install(ctx, cb)
    local source = ctx.spec.source
    local entry = pick(source.download or {})
    if not entry then
        cb("no generic download for platform: " .. table.concat(target.acceptable(), ", "))
        return
    end

    local ver_no_v = (ctx.purl.version or ""):gsub("^v", "")
    local function subst(str)
        str = str:gsub('{{%s*version%s*|%s*strip_prefix%s*"v"%s*}}', ver_no_v)
        str = str:gsub("{{%s*version%s*}}", ctx.purl.version or "")
        return str
    end

    -- `files` = { localname = url-template }; a single-file entry is normalised to one pair.
    local files = entry.files
    if not files and entry.file then
        files = { [entry.out or vim.fn.fnamemodify(subst(entry.file), ":t")] = entry.file }
    end
    if not files or next(files) == nil then
        cb("generic source declares no files to download")
        return
    end
    local names = vim.tbl_keys(files)

    local function link_bins()
        for binname, tmpl in pairs(ctx.spec.bin or {}) do
            local val = tostring(tmpl):gsub("{{%s*source%.bin%s*}}", source.bin or "")
            util.link_bin(ctx, binname, subst(val))
        end
        cb(nil)
    end

    -- Fetch each file in turn (extract archives, keep side files); the last one links the bins.
    local i = 0
    local function next_file()
        i = i + 1
        local name = names[i]
        if not name then
            link_bins()
            return
        end
        local url = subst(tostring(files[name]))
        local dest = ctx.dir .. "/" .. name
        ctx.progress("download " .. name)
        util.download(url, dest, function(err)
            if err then
                cb("download " .. name .. ": " .. err)
                return
            end
            if is_archive(name) then
                ctx.progress("extract " .. name)
                util.extract(dest, ctx.dir, function(e2)
                    if e2 then
                        cb("extract " .. name .. ": " .. e2)
                        return
                    end
                    vim.fn.delete(dest)
                    next_file()
                end)
            else
                next_file() -- a raw side file (e.g. lombok.jar) — leave it in the package dir
            end
        end)
    end
    next_file()
end

return M
