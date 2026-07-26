-- lvim-pkg: plugin introspection store.
-- The host's plugin loader (e.g. the config's core.pack) reports two things here:
-- the static plugin registry (register) and per-plugin load events (record). This
-- module merges those with vim.pack.get() (path / source / version / active) to
-- expose rich, lazy.nvim-style data to the installer: load time, load reason,
-- path, source, version, dependencies, lazy triggers and an outdated indicator.
-- It stores DATA only — loading plugins is the host loader's job.
--
---@module "lvim-pkg.loader"

local L = {}

local GITHUB = "https://github.com/"

---@class LvimPkgPluginReg  Static spec info reported by the host loader.
---@field repo? string
---@field dir? string
---@field path? string
---@field src? string
---@field version? string
---@field branch? string
---@field lazy? boolean
---@field event? string|string[]
---@field ft? string|string[]
---@field cmd? string|string[]
---@field keys? any
---@field dependencies? string[]
---@field priority? integer
---@field dependency? boolean  True when pulled in only as another plugin's dependency
---@field dep_of? string       The plugin that required it (when `dependency`)

---@type table<string, LvimPkgPluginReg>  name → static spec info
local registry = {}
---@type table<string, { reason: string, time_ms: number }>  name → dynamic load info
local records = {}
---@type table<string, boolean>  name → an upstream update is available
local outdated = {}
---@type table<string, string|false>  name → tag at HEAD (false = none), nil = not read
local tags = {}
---@type table<string, string|false>  name → branch (current/default), false = none
local branches = {}
---@type table<string, string[]>  name → recent git log lines (cached on first request)
local git_log = {}
---@type table<string, string|false>  name → live HEAD sha (false = unresolved), nil = not read
local head_revs = {}

--- Read and trim the first line of a file, or nil when unreadable.
---@param file string
---@return string|nil
local function read_first_line(file)
    local f = io.open(file, "r")
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    return line and vim.trim(line) or nil
end

--- Resolve a git checkout's current HEAD commit by reading the repo's plumbing files
--- directly (no fork+exec): fast enough to call per plugin without freezing the UI, and
--- always reflects the LIVE checkout — including raw-git checkouts that vim.pack's lockfile
--- never records. Returns the full 40-char sha, or nil when it can't be resolved.
---@param path string  plugin worktree root
---@return string|nil
function L.head_commit(path)
    local gitdir = path .. "/.git"
    -- A WORKTREE or SUBMODULE checkout has `.git` as a FILE holding `gitdir: <real path>`, not a
    -- directory. Reading `<path>/.git/HEAD` then fails and the plugin's commit silently reads as nil
    -- (an empty column in the browser, an empty entry in a saved snapshot). vim.pack's own clones are
    -- ordinary repos, so this only bites a `dir=` dev setup — which is exactly where it is used.
    if (vim.uv.fs_stat(gitdir) or {}).type == "file" then
        local pointer = read_first_line(gitdir)
        local real = pointer and pointer:match("^gitdir:%s*(.+)%s*$")
        if not real then
            return nil
        end
        -- The recorded path may be relative to the checkout.
        gitdir = real:sub(1, 1) == "/" and real or (path .. "/" .. real)
        gitdir = vim.fs.normalize(gitdir)
    end
    local head = read_first_line(gitdir .. "/HEAD")
    if not head then
        return nil
    end
    local ref = head:match("^ref:%s*(%S+)")
    if not ref then
        return head:match("^(%x+)") -- detached HEAD: the line is the sha itself
    end
    -- Attached HEAD: read the loose ref, then fall back to packed-refs.
    local loose = read_first_line(gitdir .. "/" .. ref)
    if loose then
        return loose:match("^(%x+)")
    end
    local pf = io.open(gitdir .. "/packed-refs", "r")
    if pf then
        for line in pf:lines() do
            local sha, name = line:match("^(%x+)%s+(%S+)$")
            if name == ref then
                pf:close()
                return sha
            end
        end
        pf:close()
    end
    return nil
end

--- The plugin's live HEAD sha (cached; invalidated by a checkout/update or unregister).
---@param name string
---@return string|nil
local function head_rev(name)
    local cached = head_revs[name]
    if cached ~= nil then
        return cached or nil
    end
    local reg = registry[name]
    local p = reg and (reg.path or reg.dir) or nil
    local sha = p and L.head_commit(p) or nil
    head_revs[name] = sha or false
    return sha
end

--- Register the full plugin set (static spec info). Called once by the host loader.
---@param map table<string, LvimPkgPluginReg>
---@return nil
function L.register(map)
    registry = map or {}
end

--- Drop a plugin from the data store (after it has been removed from disk), so the
--- installer stops listing it.
---@param name string
---@return nil
function L.unregister(name)
    registry[name] = nil
    records[name] = nil
    outdated[name] = nil
    tags[name] = nil
    branches[name] = nil
    git_log[name] = nil
    head_revs[name] = nil
end

--- Record that a plugin finished loading. Called by the host loader on each load.
---@param name string
---@param reason string
---@param time_ms number
---@return nil
function L.record(name, reason, time_ms)
    records[name] = { reason = reason, time_ms = time_ms }
end

--- Normalize a trigger field (string | list | function | nil) to a string list.
--- A function is evaluated first (lazy.nvim parity — `keys`/`event` may be given as a
--- function returning the specs); a failing one degrades to "no triggers" rather than
--- breaking the introspection UI.
---@param v any
---@return table
local function aslist(v)
    if type(v) == "function" then
        local ok, res = pcall(v)
        v = ok and res or nil
    end
    if v == nil then
        return {}
    end
    return type(v) == "table" and v or { v }
end

--- Build the human-readable lazy-load trigger list from a registry entry.
---@param reg LvimPkgPluginReg
---@return string[]
local function triggers_of(reg)
    local out = {}
    for _, e in ipairs(aslist(reg.event)) do
        out[#out + 1] = "event: " .. tostring(e)
    end
    for _, e in ipairs(aslist(reg.ft)) do
        out[#out + 1] = "ft: " .. tostring(e)
    end
    for _, e in ipairs(aslist(reg.cmd)) do
        out[#out + 1] = "cmd: " .. tostring(e)
    end
    for _, e in ipairs(aslist(reg.keys)) do
        out[#out + 1] = "keys: " .. (type(e) == "table" and tostring(e[1]) or tostring(e))
    end
    return out
end

--- Rich info for one plugin, or nil when unknown. Uses only the data reported by
--- the host loader (no vim.pack.get(), which is very slow).
---@param name string
---@return table|nil
function L.info(name)
    local reg = registry[name]
    if not reg then
        return nil
    end
    local rec = records[name]
    return {
        name = name,
        repo = reg.repo,
        src = reg.src or (reg.repo and (GITHUB .. reg.repo)),
        path = reg.path or reg.dir,
        dir = reg.dir,
        version = reg.version,
        branch = reg.branch or (branches[name] or nil),
        commit = (head_rev(name) or ""):sub(1, 7),
        tag = tags[name] or nil,
        lazy = reg.lazy == true,
        loaded = rec ~= nil,
        time_ms = rec and rec.time_ms,
        reason = (rec and rec.reason) or (reg.lazy and "lazy (not loaded)" or "eager"),
        triggers = triggers_of(reg),
        dependencies = reg.dependencies or {},
        priority = reg.priority,
        dependency = reg.dependency == true,
        dep_of = reg.dep_of,
        outdated = outdated[name] == true,
    }
end

--- Rich info for every known plugin, sorted by name.
---@return table[]
function L.plugins()
    local names = {}
    for n in pairs(registry) do
        names[#names + 1] = n
    end
    table.sort(names)
    local out = {}
    for _, n in ipairs(names) do
        out[#out + 1] = L.info(n)
    end
    return out
end

--- Loaded/total counts (for the dashboard startup stat).
---@return { loaded: integer, total: integer }
function L.stats()
    local total, loaded = 0, 0
    for n in pairs(registry) do
        total = total + 1
        if records[n] then
            loaded = loaded + 1
        end
    end
    return { loaded = loaded, total = total }
end

--- Whether an upstream update was detected for `name` (set by L.check_outdated).
---@param name string
---@return boolean
function L.is_outdated(name)
    return outdated[name] == true
end

--- Asynchronously check which git-managed plugins have an upstream update.
--- Best-effort: compares local HEAD against the remote default branch (origin HEAD)
--- via `git ls-remote`. Skips local dir= dev clones. Concurrency is capped.
---@param cb? fun(outdated_names: string[])
---@param on_progress? fun(done: integer, total: integer)
---@return nil
function L.check_outdated(cb, on_progress)
    ---@type { name: string, path: string }[]
    local targets = {}
    for name, reg in pairs(registry) do
        -- Only git-managed installs (skip local dir= dev clones).
        if reg.path and not reg.dir then
            targets[#targets + 1] = { name = name, path = reg.path, version = reg.version }
        end
    end

    local total = #targets
    if total == 0 then
        outdated = {}
        if cb then
            cb({})
        end
        return
    end

    -- Build into a LOCAL result set and publish it to the module `outdated` only at
    -- completion, so an overlapping second run never wipes this run's partial state
    -- mid-flight (each run keeps its own tally; the last to finish publishes cleanly).
    local result = {}
    local found = {}
    local done = 0
    local next_i = 0
    local limit = 8 -- concurrent git processes

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

    local start_next -- forward declaration
    local function check(t)
        -- Compare the installed HEAD to the remote tip of the TRACKED ref (the spec's
        -- branch/tag). A commit pin is a fixed SHA we can't ls-remote, so compare against
        -- the default branch tip instead: this only flags that a newer upstream commit
        -- exists (informative) — vim.pack still keeps the plugin at the pinned commit
        -- until you explicitly update it.
        local sha_pinned = t.version and t.version:match("^%x+$") and #t.version >= 7
        local ref = (t.version and t.version ~= "" and not sha_pinned) and t.version or "HEAD"
        -- ls-remote BOTH `ref` and its peeled `ref^{}`: an annotated tag lists the tag
        -- OBJECT sha first and the peeled COMMIT sha as `<ref>^{}` — HEAD is that commit,
        -- so prefer the peeled line (else a tag-pinned plugin reads outdated forever).
        vim.system({ "git", "-C", t.path, "ls-remote", "origin", ref, ref .. "^{}" }, { text = true }, function(r1)
            local out = r1.stdout or ""
            local remote = out:match("(%x+)%s+%S+%^{}") or out:match("^(%x+)")
            vim.system({ "git", "-C", t.path, "rev-parse", "HEAD" }, { text = true }, function(r2)
                local local_sha = (r2.stdout or ""):gsub("%s+", "")
                if remote and local_sha ~= "" and remote ~= local_sha then
                    result[t.name] = true
                    found[#found + 1] = t.name
                end
                finish_one()
                start_next()
            end)
        end)
    end

    function start_next()
        next_i = next_i + 1
        local t = targets[next_i]
        if t then
            check(t)
        end
    end

    for _ = 1, math.min(limit, total) do
        start_next()
    end
end

--- Asynchronously read the git tag at HEAD for each git-managed plugin (cached).
--- Only `tag` needs git; commit comes from the lockfile and branch from the spec.
---@param cb? fun()
---@return nil
function L.load_tags(cb)
    local targets = {}
    for name, reg in pairs(registry) do
        if reg.path and not reg.dir and (tags[name] == nil or branches[name] == nil) then
            targets[#targets + 1] = { name = name, path = reg.path }
        end
    end
    local total = #targets
    if total == 0 then
        if cb then
            cb()
        end
        return
    end
    local done, next_i, limit = 0, 0, 8
    local function finish_one()
        done = done + 1
        if done == total and cb then
            vim.schedule(cb)
        end
    end
    local start_next
    local function one(t)
        vim.system({ "git", "-C", t.path, "describe", "--tags", "--exact-match" }, { text = true }, function(res)
            local tag = (res.code == 0) and (res.stdout or ""):gsub("%s+", "") or ""
            tags[t.name] = (tag ~= "") and tag or false
            -- Then the branch: the current branch if on one, else the default (origin
            -- HEAD) — so detached checkouts still report the branch they track.
            vim.system({ "git", "-C", t.path, "symbolic-ref", "--short", "HEAD" }, { text = true }, function(rb)
                local b = (rb.code == 0) and (rb.stdout or ""):gsub("%s+", "") or ""
                if b ~= "" then
                    branches[t.name] = b
                    finish_one()
                    start_next()
                else
                    vim.system(
                        { "git", "-C", t.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" },
                        { text = true },
                        function(rd)
                            local d = (rd.code == 0) and (rd.stdout or ""):gsub("%s+", ""):gsub("^origin/", "") or ""
                            branches[t.name] = (d ~= "") and d or false
                            finish_one()
                            start_next()
                        end
                    )
                end
            end)
        end)
    end
    function start_next()
        next_i = next_i + 1
        local t = targets[next_i]
        if t then
            one(t)
        end
    end
    for _ = 1, math.min(limit, total) do
        start_next()
    end
end

--- Cached recent git-log lines for `name` (nil until L.load_git_log has run).
---@param name string
---@return string[]|nil
function L.git_log(name)
    return git_log[name]
end

--- Asynchronously read the recent git log for one plugin (cached).
---@param name string
---@param cb? fun(lines: string[])
---@return nil
function L.load_git_log(name, cb)
    if git_log[name] then
        if cb then
            cb(git_log[name])
        end
        return
    end
    local reg = registry[name]
    if not (reg and reg.path) then
        if cb then
            cb({})
        end
        return
    end
    vim.system({ "git", "-C", reg.path, "log", "-8", "--format=%h  %s  (%cr)" }, { text = true }, function(res)
        local lines = {}
        for line in (res.stdout or ""):gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
        git_log[name] = lines
        if cb then
            vim.schedule(function()
                cb(lines)
            end)
        end
    end)
end

--- Run a git command in a cloned plugin's dir, returning its output lines.
---@param name string
---@param args string[]
---@return string[]
local function git_lines(name, args)
    local reg = registry[name]
    if not reg or reg.dir or not reg.path or vim.fn.isdirectory(reg.path) == 0 then
        return {}
    end
    local res = vim.fn.systemlist(vim.list_extend({ "git", "-C", reg.path }, args))
    if vim.v.shell_error ~= 0 then
        return {}
    end
    return res
end

--- Fetch from origin (tags + branches) so the ref lists are fresh. Asynchronous —
--- calls `cb` (scheduled) when done so the UI never blocks on the network.
---@param name string
---@param cb? fun()
---@return nil
function L.plugin_fetch(name, cb)
    local reg = registry[name]
    if not reg or reg.dir or not reg.path then
        if cb then
            cb()
        end
        return
    end
    vim.system({ "git", "-C", reg.path, "fetch", "--quiet", "--tags", "--force", "origin" }, {}, function()
        if cb then
            vim.schedule(cb)
        end
    end)
end

--- Remote branches (origin/ stripped). Empty for dir= dev plugins.
---@param name string
---@return string[]
function L.plugin_branches(name)
    local out = {}
    for _, b in ipairs(git_lines(name, { "branch", "-r", "--format=%(refname:short)" })) do
        b = vim.trim(b):gsub("^origin/", "")
        if b ~= "" and b ~= "origin" and not b:find("HEAD") then
            out[#out + 1] = b
        end
    end
    return out
end

--- ALL tags, newest (highest version) first. Tags are NOT branch-scoped — a tag is
--- a label on a commit, so the full set is returned regardless of branch.
---@param name string
---@return string[]
function L.plugin_tags(name)
    return git_lines(name, { "tag", "--sort=-version:refname" })
end

--- The newest tag by version, or nil.
---@param name string
---@return string|nil
function L.plugin_newest_tag(name)
    return L.plugin_tags(name)[1]
end

--- Recent commits ("<sha> <subject>") of a branch (origin/<branch>), newest first.
---@param name string
---@param branch? string
---@return string[]
function L.plugin_commits(name, branch)
    local ref = (branch and branch ~= "") and ("origin/" .. branch) or "HEAD"
    return git_lines(name, { "log", ref, "-n", "50", "--format=%h %s" })
end

--- Remote tip sha of a branch (newest commit), short form, or nil.
---@param name string
---@param branch string
---@return string|nil
function L.plugin_branch_tip(name, branch)
    local out = git_lines(name, { "rev-parse", "--short", "origin/" .. branch })
    return out[1] and vim.trim(out[1]) or nil
end

--- The repo's default branch (origin HEAD), e.g. "main" / "master". Read locally.
---@param name string
---@return string|nil
function L.plugin_default_branch(name)
    local out = git_lines(name, { "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD" })
    if out[1] and vim.trim(out[1]) ~= "" then
        return (vim.trim(out[1]):gsub("^origin/", ""))
    end
    return nil
end

--- Newest tag whose version matches a lock prefix. prefix "1" matches the newest
--- "1.x.y"; "1.2" the newest "1.2.x"; a full version matches itself. Leading "v"
--- is ignored on both sides. nil when nothing matches.
---@param name string
---@param prefix string
---@return string|nil
function L.plugin_resolve_tag(name, prefix)
    local function norm(t)
        return (tostring(t):gsub("^v", ""))
    end
    local np = norm(prefix)
    for _, t in ipairs(L.plugin_tags(name)) do -- already newest-first
        local nt = norm(t)
        if nt == np or nt:sub(1, #np + 1) == (np .. ".") then
            return t
        end
    end
    return nil
end

--- Current checkout state: how the plugin is pinned right now (from git, not config).
--- kind = "branch" (HEAD attached to a branch — tracks it, advanceable), "tag" (DETACHED on an exact tag —
--- frozen), or "commit" (detached, no tag). BRANCH is checked FIRST: a head on a branch tracks that branch
--- even when its tip commit is also tagged (maintainers tag releases ON the branch), so update must still
--- advance it — only a detached head sitting on a tag is frozen. (The display's Tag […] still shows via the
--- separate `tags`/`branches` info, so a tagged tip is not lost.)
---@param name string
---@return { kind: "branch"|"tag"|"commit", value: string }|nil
function L.plugin_current(name)
    local reg = registry[name]
    if not reg or reg.dir or not reg.path then
        return nil
    end
    local br = git_lines(name, { "symbolic-ref", "--short", "-q", "HEAD" })
    if br[1] and vim.trim(br[1]) ~= "" then
        return { kind = "branch", value = vim.trim(br[1]) }
    end
    local tag = git_lines(name, { "describe", "--tags", "--exact-match" })
    if tag[1] and vim.trim(tag[1]) ~= "" then
        return { kind = "tag", value = vim.trim(tag[1]) }
    end
    local sha = git_lines(name, { "rev-parse", "--short", "HEAD" })
    return sha[1] and { kind = "commit", value = vim.trim(sha[1]) } or nil
end

--- Update a tracked branch to its remote tip (fetch already done by caller). Stays on the branch
--- (hard reset to origin/<branch>). ASYNChronous — the git runs off the main thread so the UI never
--- freezes on the reset; `cb(err)` fires (scheduled) when done (err = nil on success).
---@param name string
---@param branch string
---@param cb fun(err: string|nil)
---@return nil
function L.plugin_update_branch(name, branch, cb)
    local reg = registry[name]
    if not reg or reg.dir or not reg.path then
        cb("not a git plugin")
        return
    end
    -- The checkout result is ignored (as before — only the hard reset decides success/failure).
    vim.system({ "git", "-C", reg.path, "checkout", "--quiet", branch }, {}, function()
        vim.system({ "git", "-C", reg.path, "reset", "--hard", "--quiet", "origin/" .. branch }, {}, function(res)
            vim.schedule(function()
                if res.code ~= 0 then
                    cb(vim.trim((res.stderr ~= "" and res.stderr) or res.stdout or "reset failed"))
                else
                    outdated[name] = nil
                    head_revs[name] = nil -- HEAD moved; re-read the live sha on next info()
                    cb(nil)
                end
            end)
        end)
    end)
end

--- Check out `ref` (tag/branch/commit) in the plugin's dir. ASYNChronous (assumes the ref is already
--- fetched — call plugin_fetch first for newest); `cb(err)` fires (scheduled) when done.
---@param name string
---@param ref string
---@param cb fun(err: string|nil)
---@return nil
function L.plugin_checkout(name, ref, cb)
    local reg = registry[name]
    if not reg or reg.dir or not reg.path then
        cb("not a git plugin")
        return
    end
    vim.system({ "git", "-C", reg.path, "checkout", "--quiet", ref }, {}, function(res)
        vim.schedule(function()
            if res.code ~= 0 then
                cb(vim.trim((res.stderr ~= "" and res.stderr) or res.stdout or "checkout failed"))
            else
                outdated[name] = nil
                head_revs[name] = nil -- HEAD moved; re-read the live sha on next info()
                cb(nil)
            end
        end)
    end)
end

return L
