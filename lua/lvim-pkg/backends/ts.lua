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
-- lang → { waiters: fun(err)[] }, the parsers whose install is in flight right now. A parser
-- pulled in as a shared `requires` dependency by two concurrent install chains must compile
-- ONCE to its single .so path; a second requester subscribes to the first install's completion
-- instead of racing a torn write to the same file.
---@type table<string, { waiters: fun(err: string|nil)[] }>
local in_flight = {}

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

--- Drop the in-memory catalogue so the next read rebuilds it — the seam a newly registered
--- parser needs (`lvim-pkg.register_parser`). Nothing is re-downloaded: the on-disk copy is
--- re-decoded and the configured extras merged over it again.
---@return nil
function B.invalidate_registry()
    registry.invalidate()
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

--- The newest SEMVER TAG of a git repo (`v0.63.5` beats `v0.63.4`), or nil when it has none.
---
--- A registry entry that declares `semver` is released through tags, and fetching such a repo at a branch
--- name is not merely less precise — it can be impossible: tree-sitter-zsh carries BOTH a branch and a tag
--- called `main`, which makes GitHub's archive URL ambiguous (HTTP 300, an HTML body, "not in gzip format").
--- An explicit tag has no such ambiguity, and it is also the version worth recording as installed.
---@param url string
---@param cb fun(tag: string|nil)
local function latest_tag(url, cb)
    vim.system(
        { "git", "ls-remote", "--tags", "--refs", url },
        { text = true },
        vim.schedule_wrap(function(r)
            local best, best_parts
            for name in (r.stdout or ""):gmatch("refs/tags/([^\n]+)") do
                local parts = {}
                for n in name:gmatch("%d+") do
                    parts[#parts + 1] = tonumber(n)
                end
                -- Only tags that actually carry a version; `main`, `latest` and friends have no numbers.
                if #parts > 0 then
                    local newer = best_parts == nil
                    if not newer then
                        for i = 1, math.max(#parts, #best_parts) do
                            local a, b = parts[i] or 0, best_parts[i] or 0
                            if a ~= b then
                                newer = a > b
                                break
                            end
                        end
                    end
                    if newer then
                        best, best_parts = name, parts
                    end
                end
            end
            cb(best)
        end)
    )
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
    elseif src.parser_url or src.url then
        -- `parser_url` belongs to the external_queries shape (parser and queries in separate repos); a
        -- SELF-CONTAINED entry ships both from ONE repo and names it in `source.url`. Either is the grammar.
        --
        -- It must answer in the SAME CURRENCY the installer records, or the outdated check never settles: a
        -- semver entry is installed at a tag, so comparing it against remote HEAD's sha marks it outdated
        -- forever — and an auto-update then rebuilds the parser under a running editor, which drops the
        -- highlighting of every open buffer of that language.
        local url = src.parser_url or src.url
        if src.semver or src.parser_semver then
            return latest_tag(url, cb)
        end
        vim.system(
            { "git", "ls-remote", url, "HEAD" },
            { text = true },
            vim.schedule_wrap(function(r)
                cb((r.stdout or ""):match("^(%x+)"))
            end)
        )
    else
        cb(nil)
    end
end

--- Record `lang`'s installed version, so it is comparable to what the outdated check
--- resolves as latest. When the caller already knows the built revision (the queries repo's
--- pinned `parser_version`), record THAT — it is exactly the value resolve_latest would refetch,
--- minus a redundant network round-trip AND minus the race where the recorded version is remote
--- HEAD taken *after* the compile. Falls back to resolve_latest only when the version is unknown
--- (e.g. a self-contained, main-tracked parser). Clears any stale outdated flag. `cb()` always.
---@param lang string
---@param known string|nil  the revision actually built, when the installer knows it
---@param cb fun()
local function record_installed(lang, known, cb)
    if known and known ~= "" then
        store.receipt_set(RECEIPT_PREFIX .. lang, { type = "parser", version = known })
        outdated[lang] = nil
        return cb()
    end
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
    ---@return boolean copied  whether `d` held any `.scm` at all
    local function copy_from(d)
        if not d or vim.fn.isdirectory(d) == 0 then
            return false
        end
        local copied = false
        for name, t in vim.fs.dir(d) do
            if t == "file" and name:match("%.scm$") then
                pcall(vim.fn.writefile, vim.fn.readfile(d .. "/" .. name), dest .. "/" .. name)
                copied = true
            end
        end
        return copied
    end
    -- Both layouts occur in the wild: the queries sitting directly in the named folder, and a Neovim RUNTIME
    -- tree with a directory per language (`<dir>/<lang>/*.scm`) — tree-sitter-zsh ships `nvim-queries/zsh/`,
    -- and copying the folder itself found no `.scm` at all, so the parser installed without highlights. The
    -- language-scoped path is tried first and the flat one is the fallback, in both shapes.
    if subdir and subdir ~= "" then
        local root = qroot .. "/" .. subdir
        if not copy_from(root .. "/" .. lang) then
            copy_from(root)
        end
    else
        local copied = copy_from(qroot)
        copied = copy_from(qroot .. "/queries") or copied
        if not copied then
            copy_from(qroot .. "/queries/" .. lang)
        end
    end
end

--- Remove the temp extraction tree a fetch_repo dir lives in (its parent), once its files
--- have been copied/compiled out — so a long session of parser installs does not accumulate
--- tarball extractions under the private tmp dir.
---@param dir string|nil  a directory returned by fetch_repo (repo root under a tmp dir)
local function discard_extract(dir)
    if dir then
        pcall(vim.fn.delete, vim.fn.fnamemodify(dir, ":h"), "rf")
    end
end

--- Install one language: its `requires` dependencies first, then its parser (.so)
--- and queries (.scm). `seen` guards against dependency cycles / repeats within ONE chain;
--- the module-level `in_flight` guard coalesces the SAME parser requested by concurrent chains.
---@param lang string
---@param cb fun(err: string|nil)
---@param seen? table<string, boolean>
local function install_one(lang, cb, seen)
    seen = seen or {}
    if seen[lang] then
        return cb(nil)
    end
    seen[lang] = true
    -- Another concurrent chain is already installing this exact parser: wait for its single
    -- compile rather than racing a second one onto the same .so path.
    local fl = in_flight[lang]
    if fl then
        fl.waiters[#fl.waiters + 1] = cb
        return
    end
    in_flight[lang] = { waiters = {} }
    -- Central completion: publish the result to this parser's waiters and release the guard,
    -- so every path below finishes through `finish` instead of a bare `cb`.
    local function finish(err)
        local waiters = in_flight[lang] and in_flight[lang].waiters or {}
        in_flight[lang] = nil
        cb(err)
        for _, w in ipairs(waiters) do
            w(err)
        end
    end

    local entry = registry.get(lang)
    if not entry then
        return finish("unknown parser: " .. lang)
    end
    local src = entry.source

    -- The parser + queries install for `lang`, run once its dependencies are present.
    local function do_install()
        -- queries_only: a dialect reusing another parser (installed via `requires`); queries only.
        if src.type == "queries_only" then
            return fetch_repo(src.url, "main", function(err, qdir)
                if err then
                    return finish(err)
                end
                ---@cast qdir string  fetch_repo guarantees a dir when err is nil
                copy_queries(qdir, lang)
                discard_extract(qdir)
                finish(nil)
            end)
        end
        -- external_queries / self_contained: queries repo (for the pinned version) → parser → compile.
        local function with_queries(qdir)
            local pj = qdir and read_json(qdir .. "/parser.json") or {}
            -- Where the GRAMMAR lives, in the registry's own three shapes: a pinned `parser.json` from the
            -- queries repo wins; otherwise `parser_url` for an external_queries entry, and `url` for a
            -- SELF-CONTAINED one, which ships parser and queries from a single repo (zsh is such an entry —
            -- reading only `parser_url` made it fail with "missing repository url").
            local purl = pj.url or src.parser_url or src.url

            -- What to fetch, and what to record as installed. A queries repo PINS the grammar revision, which
            -- always wins. Otherwise an entry that declares `semver` is released through tags — take the newest
            -- one; anything else tracks the default branch.
            local function with_ref(ref, version)
                fetch_repo(purl, ref, function(e2, pdir)
                    if e2 then
                        discard_extract(qdir)
                        return finish(e2)
                    end
                    ---@cast pdir string  fetch_repo guarantees a dir when err is nil
                    local grammar = src.parser_location and (pdir .. "/" .. src.parser_location) or pdir
                    compile(grammar, parser_dir() .. "/" .. lang .. ".so", function(e3)
                        if e3 then
                            discard_extract(qdir)
                            discard_extract(pdir)
                            return finish("compile " .. lang .. ": " .. e3)
                        end
                        -- external_queries: `qdir` is the queries repo. self_contained: no queries repo (qdir
                        -- nil), so queries live in the parser repo — under `source.queries_dir` if named.
                        local sub = (not qdir) and src.queries_dir or nil
                        copy_queries(qdir or grammar, lang, sub)
                        discard_extract(qdir)
                        discard_extract(pdir)
                        -- The revision actually built, when we know it (the queries repo's pin or the tag we
                        -- chose); record_installed falls back to resolve_latest when we do not.
                        record_installed(lang, version, function()
                            finish(nil)
                        end)
                    end)
                end)
            end

            if pj.parser_version then
                with_ref(pj.parser_version, pj.parser_version)
            elseif src.semver or src.parser_semver then
                latest_tag(purl or "", function(tag)
                    -- No tag means the lookup failed (network, moved repo) — for a semver repo the literal
                    -- `main` is no fallback: on one like tree-sitter-zsh (branch AND tag `main`) the archive
                    -- URL is ambiguous, so fail plainly instead of degrading into the HTTP 300.
                    if not tag then
                        discard_extract(qdir)
                        return finish("no release tag found for " .. lang .. " at " .. (purl or "?"))
                    end
                    with_ref(tag, tag)
                end)
            else
                with_ref("main", nil)
            end
        end
        if src.queries_url then
            fetch_repo(src.queries_url, "main", function(err, qdir)
                if err then
                    return finish(err)
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
                return finish(err)
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
        -- self_contained: queries live in the parser repo — which such an entry names in `source.url`
        -- (`parser_url` is the external_queries shape), so both spellings are accepted.
        local purl = src.parser_url or src.url
        if purl then
            -- Same ref rules as the full install: a semver entry is released through tags, and fetching a
            -- repo like tree-sitter-zsh (branch AND tag `main`) at the literal `main` is ambiguous (HTTP 300).
            local function fetch_at(ref)
                fetch_repo(purl, ref, function(err, pdir)
                    if err then
                        return cb(err)
                    end
                    ---@cast pdir string  fetch_repo guarantees a dir when err is nil
                    local grammar = src.parser_location and (pdir .. "/" .. src.parser_location) or pdir
                    -- honour a self_contained entry's `source.queries_dir` here too (the full-install path
                    -- already does) — else a queries-only migration copies the grammar's own .scm, not the
                    -- Neovim set.
                    copy_queries(grammar, name, src.queries_dir)
                    discard_extract(pdir)
                    cb(nil)
                end)
            end
            if src.semver or src.parser_semver then
                return latest_tag(purl, function(tag)
                    if not tag then
                        return cb("no release tag found for " .. name .. " at " .. purl)
                    end
                    fetch_at(tag)
                end)
            end
            return fetch_at("main")
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
        -- Build into a LOCAL result set, published to the module `outdated` only at completion,
        -- so an overlapping second run cannot corrupt this run's partial state mid-flight.
        local result = {}
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
            if done == total then
                outdated = result
                if cb then
                    vim.schedule(function()
                        cb(found)
                    end)
                end
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
                elseif latest and cur ~= latest then
                    result[lang] = true
                    found[#found + 1] = lang
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
