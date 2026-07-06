-- lvim-pkg: self-contained tree-sitter parser backend.
-- Installs parsers and their Neovim queries WITHOUT nvim-treesitter, from the
-- editor-agnostic treesitter-parser-registry (see lvim-pkg.registry.ts): it fetches
-- a parser's grammar repo at the version its queries are tested against, compiles
-- the parser with the system C/C++ compiler, drops the .so under root/ts/parser and
-- the query .scm files under root/ts/queries, and adds root/ts to the runtimepath so
-- Neovim's built-in vim.treesitter discovers both natively. No nvim-treesitter.
--
---@module "lvim-pkg.backends.ts"

local registry = require("lvim-pkg.registry.ts")
local util = require("lvim-pkg.install.util")
local paths = require("lvim-pkg.paths")
local store = require("lvim-pkg.store")
local config = require("lvim-pkg.config")

local B = { kind = "parser" }

local rtp_added = false

-- Receipt keys are namespaced so parser versions never collide with Mason packages.
local RECEIPT_PREFIX = "ts:"
-- name → true, the parsers a check found behind the registry's current version.
local outdated = {}

---@return string  parser .so output directory
local function parser_dir()
    return paths.ts() .. "/parser"
end

---@return string  query files directory
local function queries_dir()
    return paths.ts() .. "/queries"
end

--- Ensure root/ts exists and is on the runtimepath, and kick off a registry fetch.
--- Built-in vim.treesitter reads parser/<lang>.so and queries/<lang>/ from the rtp.
---@return nil
function B.ensure_install_dir()
    if rtp_added then
        return
    end
    rtp_added = true
    vim.fn.mkdir(parser_dir(), "p")
    vim.fn.mkdir(queries_dir(), "p")
    local dir = paths.ts()
    if not vim.tbl_contains(vim.opt.runtimepath:get(), dir) then
        vim.opt.runtimepath:prepend(dir)
    end
    registry.ensure() -- background; populates the catalogue for available()
end

-- ── install engine ────────────────────────────────────────────────────────────

---@param path string
---@return table|nil
local function read_json(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    return ok and data or nil
end

--- The authoritative current version string for `lang` — the same value that an install
--- now would build at. For external_queries that is the queries repo's pinned
--- `parser_version` (read cheaply from its raw parser.json on main); for a self-contained,
--- main-tracked parser it is the parser repo's default-branch tip commit. `cb(version|nil)`
--- — nil when the parser has no version concept (queries_only) or the lookup failed.
---@param lang string
---@param cb fun(version: string|nil)
local function resolve_latest(lang, cb)
    local entry = registry.get(lang)
    local src = entry and entry.source
    if not src or src.type == "queries_only" then
        return cb(nil)
    end
    if src.queries_url then
        -- Mirror install: the queries repo (always on main) pins the grammar revision.
        local raw = src.queries_url:gsub("github%.com", "raw.githubusercontent.com") .. "/main/parser.json"
        local tmp = vim.fn.tempname()
        util.download(raw, tmp, function(err)
            local pj = (not err) and read_json(tmp) or nil
            vim.fn.delete(tmp)
            cb(pj and pj.parser_version or nil)
        end)
    elseif src.parser_url then
        vim.system(
            { "git", "ls-remote", src.parser_url, "HEAD" },
            { text = true },
            vim.schedule_wrap(function(r)
                cb((r.stdout or ""):match("^(%x+)"))
            end)
        )
    else
        cb(nil)
    end
end

--- Record `lang`'s installed version (resolved the same way the outdated check resolves
--- the latest), so the two are comparable. Clears any stale outdated flag. `cb()` always.
---@param lang string
---@param cb fun()
local function record_installed(lang, cb)
    resolve_latest(lang, function(version)
        if version then
            store.receipt_set(RECEIPT_PREFIX .. lang, { type = "parser", version = version })
        end
        outdated[lang] = nil
        cb()
    end)
end

--- Download a GitHub repo tarball at `ref` and extract it. `cb(err, dir)` where
--- `dir` is the extracted repo root.
---@param url string   https://github.com/owner/repo
---@param ref string   tag, branch or commit
---@param cb  fun(err: string|nil, dir: string|nil)
local function fetch_repo(url, ref, cb)
    if not url or url == "" then
        cb("missing repository url")
        return
    end
    local owner_repo = url:gsub("https://github.com/", ""):gsub("%.git$", "")
    local tarball = string.format("https://github.com/%s/archive/%s.tar.gz", owner_repo, ref)
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local archive = tmp .. "/repo.tar.gz"
    util.download(tarball, archive, function(err)
        if err then
            return cb(("download %s@%s: %s"):format(owner_repo, ref, err))
        end
        util.extract(archive, tmp, function(e2)
            if e2 then
                return cb("extract: " .. e2)
            end
            -- GitHub wraps the repo in a single <repo>-<ref> directory.
            local root
            for name, t in vim.fs.dir(tmp) do
                if t == "directory" then
                    root = tmp .. "/" .. name
                    break
                end
            end
            if not root then
                return cb("extract: no directory in archive")
            end
            cb(nil, root)
        end)
    end)
end

--- Compile a grammar directory's parser into `out` (.so), handling an optional
--- C or C++ external scanner, and running `tree-sitter generate` first when the
--- grammar ships no pre-generated src/parser.c.
---@param dir string  grammar root (contains src/ and/or grammar.js)
---@param out string  output .so path
---@param cb  fun(err: string|nil)
local function compile(dir, out, cb)
    local src = dir .. "/src"
    local function do_cc()
        local sources = { src .. "/parser.c" }
        local compiler = "cc"
        if vim.fn.filereadable(src .. "/scanner.c") == 1 then
            sources[#sources + 1] = src .. "/scanner.c"
        elseif vim.fn.filereadable(src .. "/scanner.cc") == 1 then
            sources[#sources + 1] = src .. "/scanner.cc"
            compiler = "c++"
        end
        vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
        local cmd = { compiler, "-o", out, "-shared", "-Os", "-fPIC", "-I" .. src }
        vim.list_extend(cmd, sources)
        util.run(cmd, {}, cb)
    end
    if vim.fn.filereadable(src .. "/parser.c") == 1 then
        return do_cc()
    end
    -- No committed parser.c: generate it from grammar.js with the tree-sitter CLI.
    if vim.fn.filereadable(dir .. "/grammar.js") == 0 or vim.fn.executable("tree-sitter") == 0 then
        return cb("no src/parser.c and cannot run `tree-sitter generate`")
    end
    util.run({ "tree-sitter", "generate" }, { cwd = dir }, function(gerr)
        if gerr then
            return cb("tree-sitter generate: " .. gerr)
        end
        if vim.fn.filereadable(src .. "/parser.c") == 0 then
            return cb("tree-sitter generate produced no parser.c")
        end
        do_cc()
    end)
end

--- Copy every .scm file into queries/<lang>/. When `subdir` is given (a `self_contained` entry's
--- `source.queries_dir`, e.g. zsh's "nvim-queries"), the Neovim queries live ONLY in that subdirectory of the
--- parser repo, so copy from there exclusively — the repo root / `queries/` may hold the grammar's own
--- upstream (non-Neovim) queries. Without a `subdir`, use the default heuristic: `qroot` and `qroot/queries`.
---@param qroot string
---@param lang string
---@param subdir? string  explicit queries subdirectory within `qroot` (registry `source.queries_dir`)
local function copy_queries(qroot, lang, subdir)
    if not qroot then
        return
    end
    local dest = queries_dir() .. "/" .. lang
    vim.fn.mkdir(dest, "p")
    local function copy_from(d)
        if not d or vim.fn.isdirectory(d) == 0 then
            return
        end
        for name, t in vim.fs.dir(d) do
            if t == "file" and name:match("%.scm$") then
                pcall(vim.fn.writefile, vim.fn.readfile(d .. "/" .. name), dest .. "/" .. name)
            end
        end
    end
    if subdir and subdir ~= "" then
        copy_from(qroot .. "/" .. subdir)
    else
        copy_from(qroot)
        copy_from(qroot .. "/queries")
    end
end

--- Install one language: its `requires` dependencies first, then its parser (.so)
--- and queries (.scm). `seen` guards against dependency cycles / repeats.
---@param lang string
---@param cb fun(err: string|nil)
---@param seen? table<string, boolean>
local function install_one(lang, cb, seen)
    seen = seen or {}
    if seen[lang] then
        return cb(nil)
    end
    seen[lang] = true
    local entry = registry.get(lang)
    if not entry then
        return cb("unknown parser: " .. lang)
    end
    local src = entry.source

    -- The parser + queries install for `lang`, run once its dependencies are present.
    local function do_install()
        -- queries_only: a dialect reusing another parser (installed via `requires`); queries only.
        if src.type == "queries_only" then
            return fetch_repo(src.url, "main", function(err, qdir)
                if err then
                    return cb(err)
                end
                ---@cast qdir string  fetch_repo guarantees a dir when err is nil
                copy_queries(qdir, lang)
                cb(nil)
            end)
        end
        -- external_queries / self_contained: queries repo (for the pinned version) → parser → compile.
        local function with_queries(qdir)
            local pj = qdir and read_json(qdir .. "/parser.json") or {}
            local purl = pj.url or src.parser_url
            local ref = pj.parser_version or "main"
            fetch_repo(purl, ref, function(e2, pdir)
                if e2 then
                    return cb(e2)
                end
                ---@cast pdir string  fetch_repo guarantees a dir when err is nil
                local grammar = src.parser_location and (pdir .. "/" .. src.parser_location) or pdir
                compile(grammar, parser_dir() .. "/" .. lang .. ".so", function(e3)
                    if e3 then
                        return cb("compile " .. lang .. ": " .. e3)
                    end
                    -- external_queries: `qdir` is the queries repo. self_contained: no queries repo (qdir nil),
                    -- so queries live in the parser repo — under `source.queries_dir` when the entry names one.
                    local sub = (not qdir) and src.queries_dir or nil
                    copy_queries(qdir or grammar, lang, sub)
                    record_installed(lang, function()
                        cb(nil)
                    end)
                end)
            end)
        end
        if src.queries_url then
            fetch_repo(src.queries_url, "main", function(err, qdir)
                if err then
                    return cb(err)
                end
                with_queries(qdir)
            end)
        else
            with_queries(nil)
        end
    end

    -- Install dependencies (e.g. jsx requires javascript) before the language itself.
    local reqs = entry.requires or {}
    local i = 0
    local function next_dep()
        i = i + 1
        if i > #reqs then
            return do_install()
        end
        install_one(reqs[i], function(err)
            if err then
                return cb(err)
            end
            next_dep()
        end, seen)
    end
    next_dep()
end

-- ── backend interface ─────────────────────────────────────────────────────────

---@return string[]
function B.available()
    B.ensure_install_dir()
    return registry.names()
end

---@return string[]
function B.installed()
    local out = {}
    for _, so in ipairs(vim.fn.glob(parser_dir() .. "/*.so", false, true)) do
        out[#out + 1] = vim.fn.fnamemodify(so, ":t:r")
    end
    table.sort(out)
    return out
end

---@param name string
---@return boolean
function B.is_installed(name)
    return vim.fn.filereadable(parser_dir() .. "/" .. name .. ".so") == 1
end

--- Whether `lang` has its Neovim queries installed (highlights.scm present).
---@param name string
---@return boolean
function B.has_queries(name)
    return vim.fn.filereadable(queries_dir() .. "/" .. name .. "/highlights.scm") == 1
end

--- Install ONLY the queries for `lang` (no parser compile). Used to migrate parsers
--- whose .so already exists (e.g. compiled by the old nvim-treesitter) but whose
--- queries are missing from our query dir.
---@param name string
---@param cb? fun(err: string|nil)
---@return nil
function B.install_queries(name, cb)
    cb = cb or function() end
    registry.ensure(function()
        local entry = registry.get(name)
        if not entry then
            return cb("unknown parser: " .. name)
        end
        local src = entry.source
        local qurl = src.queries_url or (src.type == "queries_only" and src.url) or nil
        if qurl then
            return fetch_repo(qurl, "main", function(err, qdir)
                if err then
                    return cb(err)
                end
                ---@cast qdir string  fetch_repo guarantees a dir when err is nil
                copy_queries(qdir, name)
                cb(nil)
            end)
        end
        -- self_contained: queries live in the parser repo.
        if src.parser_url then
            return fetch_repo(src.parser_url, "main", function(err, pdir)
                if err then
                    return cb(err)
                end
                ---@cast pdir string  fetch_repo guarantees a dir when err is nil
                local grammar = src.parser_location and (pdir .. "/" .. src.parser_location) or pdir
                copy_queries(grammar, name)
                cb(nil)
            end)
        end
        cb(nil)
    end)
end

--- Install parsers, at most `config.max_concurrency` compiling at once (a worker pool —
--- different languages write independent .so/query files, so they parallelise safely). Waits
--- for the whole batch; `cb(err)` reports the first error encountered (nil when all succeed).
---@param names string[]
---@param cb? fun(err: string|nil)
function B.install(names, cb)
    cb = cb or function() end
    B.ensure_install_dir()
    registry.ensure(function()
        local total = #names
        if total == 0 then
            return cb(nil)
        end
        local cap = math.max(1, config.max_concurrency or 4)
        local next_idx, done, first_err = 0, 0, nil
        local function start_next()
            next_idx = next_idx + 1
            local name = names[next_idx]
            if not name then
                return
            end
            install_one(name, function(err)
                first_err = first_err or err
                done = done + 1
                if done == total then
                    cb(first_err)
                else
                    start_next() -- pull the next queued parser into the freed slot
                end
            end)
        end
        for _ = 1, math.min(cap, total) do
            start_next()
        end
    end)
end

--- Update = reinstall at the current pinned version.
---@param names? string[]
---@param cb? fun(err: string|nil)
function B.update(names, cb)
    B.install(names or B.installed(), cb)
end

---@param names string[]
---@param cb? fun(err: string|nil)
function B.remove(names, cb)
    for _, lang in ipairs(names or {}) do
        vim.fn.delete(parser_dir() .. "/" .. lang .. ".so")
        vim.fn.delete(queries_dir() .. "/" .. lang, "rf")
        store.receipt_remove(RECEIPT_PREFIX .. lang)
        outdated[lang] = nil
    end
    if cb then
        cb(nil)
    end
end

-- ── version tracking ──────────────────────────────────────────────────────────

--- The grammar revision `lang`'s installed .so was built at (from its receipt), or nil
--- when unknown (e.g. a parser compiled before version tracking existed).
---@param lang string
---@return string|nil
function B.installed_version(lang)
    local r = store.receipt_get(RECEIPT_PREFIX .. lang)
    return r and r.version or nil
end

--- Whether the last check found `lang` behind the registry's current version. Cached;
--- populated by B.check_outdated.
---@param lang string
---@return boolean
function B.is_outdated(lang)
    return outdated[lang] == true
end

--- Check installed parsers against the registry's current versions, async with a small
--- concurrency cap. Updates the cached outdated set and calls `cb(outdated_names)`.
--- A parser with no recorded version is treated as up to date (nothing to compare).
---@param cb? fun(names: string[])
---@param on_progress? fun(done: integer, total: integer)
---@return nil
function B.check_outdated(cb, on_progress)
    registry.ensure(function()
        local langs = B.installed()
        local total = #langs
        local found = {}
        if total == 0 then
            outdated = {}
            if cb then
                cb(found)
            end
            return
        end
        local done, next_i = 0, 0
        local limit = 8
        local start_next
        local function finish_one()
            done = done + 1
            if on_progress then
                vim.schedule(function()
                    on_progress(done, total)
                end)
            end
            if done == total and cb then
                vim.schedule(function()
                    cb(found)
                end)
            end
        end
        local function check(lang)
            local cur = B.installed_version(lang)
            resolve_latest(lang, function(latest)
                if not cur then
                    -- No recorded build revision (installed before version tracking): baseline
                    -- it to the current version so future registry bumps are detected. We can't
                    -- know the real build revision, so treat it as up to date for now.
                    if latest then
                        store.receipt_set(RECEIPT_PREFIX .. lang, { type = "parser", version = latest })
                    end
                    outdated[lang] = nil
                elseif latest and cur ~= latest then
                    outdated[lang] = true
                    found[#found + 1] = lang
                else
                    outdated[lang] = nil
                end
                finish_one()
                start_next()
            end)
        end
        function start_next()
            next_i = next_i + 1
            local lang = langs[next_i]
            if lang then
                check(lang)
            end
        end
        for _ = 1, math.min(limit, total) do
            start_next()
        end
    end)
end

return B
