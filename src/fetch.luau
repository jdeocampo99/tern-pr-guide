--!strict
-- Where the plugin reaches outside itself: `gh` for the PR's metadata and posting the
-- review, `git` in a checkout (the reader's own, or PR Guide's saved light copy of a repo) for the
-- PR's changes and files, the checkout's guide files, the review lens files, and the reader's AI
-- agent writing a guide. Each step starts the next from its callback; the first failure ends the
-- chain with a message naming the step.
local Agent = require("./agent")
local AgentFix = require("./hub/agent-fix")
local Fixes = require("./hub/fixes")
local Github = require("./github")
local GitOutput = require("./git-output")
local Guide = require("./guide")
local Lens = require("./lens")
local Links = require("./links")
local Model = require("./hub/model")
local Pr = require("./pr")
local Review = require("./review")
local ReviewFix = require("./hub/review-fix")
local Sync = require("./hub/sync")
local Text = require("./text")

-- A PR as the reader named it (number, URL or branch), the root of its repository's checkout, and
-- the repo's "owner/repo" when that checkout is PR Guide's own saved copy.
export type Target = { pr: string, repo: string, cache: string? }

-- A checkout: its root, and the directory holding guides for its PRs, shared by its worktrees.
-- `cache` is the repo's "owner/repo" when the checkout is PR Guide's saved copy: a bare clone
-- that has no files, only history, with file contents fetched as they are read.
export type Repo = { root: string, guides: string, cache: string? }

-- Where a submitted review goes: in a dry run, the file at `dryRunPath`; otherwise GitHub. Without
-- a `repo` (the bundled sample) there is no PR to check or post to.
export type Destination = { repo: string?, dryRunPath: string? }

type Fail = (message: string) -> ()
-- `partial` is set for a saved copy, whose fetches leave out trees and file contents.
type Job = { repo: string, fail: Fail, partial: boolean? }
type Meta = { number: number, title: string, body: string?, url: string, author: { login: string }?, baseRefName: string, headRefOid: string, mergeCommit: { oid: string }? }

local GH_MS = 30_000
local GIT_MS = 60_000
-- The first fetch of a big repo's history takes a while.
local GIT_FETCH_MS = 20 * 60_000

local AGENT_MS = 20 * 60_000

local PROMPT = "prompts/guide.md"
-- The plugin's own lenses, and the most a lens file may be.
local LENSES = "lenses"
local LENS_BYTES = 64 * 1024

-- What went wrong: stderr's first line, plus GitHub's own explanation, which `gh api` prints to stdout.
local function reason(result: ProcessResult): string
 if result.timed_out then return "timed out" end
 local line = string.match(result.stderr, "%S[^\r\n]*") or ("exit status " .. result.status)
 local decoded, body = pcall(tern.json.decode, result.stdout)
 if decoded and type(body) == "table" and type(body.errors) == "table" then
  local details = {}
  for _, err in body.errors do
   table.insert(details, if type(err) == "string" then err else tostring(err.message or err.code))
  end
  if #details > 0 then line ..= " — " .. table.concat(details, "; ") end
 end
 return line
end

-- Tern started from the Dock has a bare PATH, without Homebrew's `gh` or tools like `omp` that a
-- shell rc file adds. Every command runs with the PATH of the reader's interactive login shell,
-- read once and shared by the window's blocks; Homebrew's directories are added in case the shell
-- gives nothing.
local FALLBACK_DIRS = "/opt/homebrew/bin:/usr/local/bin"
local shellPath: string? = nil
local waitingForPath: { (path: string) -> () }? = nil

local function withShellPath(go: (path: string) -> ())
 if shellPath then return go(shellPath) end
 if waitingForPath then
  table.insert(waitingForPath, go)
  return
 end
 waitingForPath = { go }
 local function settle(path: string?)
  local base = if path and path ~= "" then path else (tern.getenv("PATH") or "/usr/bin:/bin")
  shellPath = base .. ":" .. FALLBACK_DIRS
  local waiting = waitingForPath :: { (path: string) -> () }
  waitingForPath = nil
  for _, resume in waiting do resume(shellPath :: string) end
 end
 local shell = tern.getenv("SHELL") or "/bin/zsh"
 local spawned = pcall(tern.process.run, { shell, "-lic", "printf '\\n%s%s' PRGUIDE_PATH= \"$PATH\"" }, { timeout_ms = 15_000 }, function(result: ProcessResult)
  settle(string.match(result.stdout, "PRGUIDE_PATH=([^\n]*)%s*$"))
 end)
 if not spawned then settle(nil) end
end

-- The first file named `program` in the directories of `path`; `program` itself when it already
-- names a path or nothing matches.
local function located(program: string, path: string): string
 if string.find(program, "/", 1, true) then return program end
 for dir in string.gmatch(path, "[^:]+") do
  local candidate = dir .. "/" .. program
  if tern.fs.exists(candidate) then return candidate end
 end
 return program
end

-- Runs `argv` and hands its stdout to `ok`; a failed run, or an error from `ok` reading unexpected
-- output, goes to `fail`.
local function run(argv: { string }, opts: ProcessOptions, fail: Fail, ok: (stdout: string) -> ())
 withShellPath(function(path)
  local resolved = table.clone(argv)
  resolved[1] = located(argv[1], path)
  local withPath = table.clone(opts)
  local env = if opts.env then table.clone(opts.env) else {}
  env.PATH = env.PATH or path
  withPath.env = env
  local spawned, err = pcall(tern.process.run, resolved, withPath, function(result: ProcessResult)
   if result.status ~= 0 then
    fail(reason(result))
    return
   end
   local handled, problem = pcall(ok, result.stdout)
   if not handled then fail(Text.errorLine(problem)) end
  end)
  if not spawned then fail(Text.errorLine(err)) end
 end)
end

-- `fail` with each message prefixed by the step that failed.
local function named(what: string, fail: Fail): Fail
 return function(message: string) fail(what .. ": " .. message) end
end

local function git(job: Job, what: string, args: { string }, stdin: string?, ok: (stdout: string) -> ())
 local argv = { "git", "--literal-pathspecs", "-C", job.repo }
 table.move(args, 1, #args, #argv + 1, argv)
 -- A git that needs a password must fail, not wait for one nobody can type.
 local opts = { stdin = stdin, timeout_ms = if args[1] == "fetch" then GIT_FETCH_MS else GIT_MS, env = { GIT_TERMINAL_PROMPT = "0" } }
 run(argv, opts, named(what, job.fail), ok)
end

local function trimmed(text: string): string
 return (string.gsub(text, "%s+$", ""))
end

local function readMeta(job: Job, pr: string, ok: (meta: Meta) -> ())
 local argv = { "gh", "pr", "view", pr, "--json", "number,title,body,url,author,baseRefName,headRefOid,mergeCommit" }
 run(argv, { cwd = job.repo, timeout_ms = GH_MS }, named("gh pr view", job.fail), function(stdout)
  ok(tern.json.decode(stdout))
 end)
end

-- Where the PR's head and base are fetched to.
local function refPrefix(number: number): string
 return "refs/prguide/" .. number
end

-- Fetches the PR's head and base into refs/prguide/<n>/*, leaving branches and the working tree
-- alone; hands on the head commit and where it branched from the base. Once a PR is merged with a
-- merge commit, its head is part of the base and the two meet at the head itself, which would show
-- no changes; it branched from where the merge commit's first parent meets the head instead.
local function fetchRefs(job: Job, meta: Meta, ok: (head: string, mergeBase: string) -> ())
 local prefix = refPrefix(meta.number)
 local fetch = {
  "fetch", "--no-tags", "--no-write-fetch-head", "origin",
  "+refs/pull/" .. meta.number .. "/head:" .. prefix .. "/head",
  "+refs/heads/" .. meta.baseRefName .. ":" .. prefix .. "/base",
 }
 -- Commits only: a saved copy reads the trees and files a PR changes in one batch, later.
 if job.partial then table.insert(fetch, 2, "--filter=tree:0") end
 git(job, "git fetch", fetch, nil, function()
  git(job, "git rev-parse", { "rev-parse", prefix .. "/head" }, nil, function(head)
   git(job, "git merge-base", { "merge-base", prefix .. "/head", prefix .. "/base" }, nil, function(mergeBase)
    head, mergeBase = trimmed(head), trimmed(mergeBase)
    local merge = if type(meta.mergeCommit) == "table" then meta.mergeCommit.oid else nil
    if mergeBase ~= head or not merge or merge == head then return ok(head, mergeBase) end
    git(job, "git merge-base", { "merge-base", head, merge .. "^1" }, nil, function(before)
     ok(head, trimmed(before))
    end)
   end)
  end)
 end)
end

-- The changes worth reviewing: every changed file but lockfiles and ones marked linguist-generated.
local function listChanges(job: Job, mergeBase: string, head: string, ok: (changes: { GitOutput.Change }) -> ())
 git(job, "git diff --name-status", { "diff", "--name-status", "-z", "--find-renames", mergeBase, head }, nil, function(stdout)
  local changes = {}
  for _, change in GitOutput.changes(stdout) do
   if not GitOutput.isLockfile(change.path) then table.insert(changes, change) end
  end
  if #changes == 0 then return ok(changes) end
  local paths = {}
  for _, change in changes do table.insert(paths, change.path) end
  local stdin = table.concat(paths, "\0") .. "\0"
  git(job, "git check-attr", { "check-attr", "--source=" .. head, "-z", "--stdin", "linguist-generated" }, stdin, function(attrs)
   local generated = GitOutput.generated(attrs)
   local kept = {}
   for _, change in changes do
    if not generated[change.path] then table.insert(kept, change) end
   end
   ok(kept)
  end)
 end)
end

-- One `git diff` of just the kept files, computed locally: GitHub refuses diffs of big PRs.
local function readPatches(job: Job, mergeBase: string, head: string, changes: { GitOutput.Change }, ok: (patches: { [string]: GitOutput.Patch }) -> ())
 if #changes == 0 then return ok({}) end
 local args = {
  "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--find-renames",
  "--src-prefix=a/", "--dst-prefix=b/", mergeBase, head, "--",
 }
 local paths = {}
 for _, change in changes do
  table.insert(paths, change.path)
  if change.oldPath then table.insert(args, change.oldPath) end
  table.insert(args, change.path)
 end
 git(job, "git diff", args, nil, function(stdout)
  ok(GitOutput.patches(stdout, paths))
 end)
end

-- Fetches the files `paths` have at `head` that a saved copy lacks, in one request: its `git diff`
-- fetches the changed files it shows in one batch, but a rename or a mode change shows none, and
-- `git cat-file` would fetch each of those on its own.
local function prefetchSources(job: Job, head: string, paths: { string }, ok: () -> ())
 if not job.partial or #paths == 0 then return ok() end
 local listing = { "ls-tree", "-z", head, "--" }
 table.move(paths, 1, #paths, #listing + 1, listing)
 git(job, "git ls-tree", listing, nil, function(tree)
  local oids = {}
  for oid in string.gmatch(tree, "%d+ blob (%x+)\t") do table.insert(oids, oid) end
  if #oids == 0 then return ok() end
  local wanted = table.concat(oids, "\n") .. "\n"
  git(job, "git cat-file", { "--no-lazy-fetch", "cat-file", "--batch-check" }, wanted, function(checked)
   local missing = {}
   for oid in string.gmatch(checked, "(%x+) missing") do table.insert(missing, oid) end
   if #missing == 0 then return ok() end
   local fetch = { "-c", "fetch.negotiationAlgorithm=noop", "fetch", "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", "--stdin", "origin" }
   git(job, "git fetch", fetch, table.concat(missing, "\n") .. "\n", function() ok() end)
  end)
 end)
end

-- The whole new side of `paths` at `head`, all through one `git cat-file --batch`.
local function readSources(job: Job, head: string, paths: { string }, ok: (blobs: { [string]: string }) -> ())
 if #paths == 0 then return ok({}) end
 local requests = {}
 for _, path in paths do table.insert(requests, head .. ":" .. path) end
 git(job, "git cat-file", { "cat-file", "--batch" }, table.concat(requests, "\n") .. "\n", function(stdout)
  ok(GitOutput.blobs(stdout, paths))
 end)
end

local function prOf(meta: Meta, head: string, files: { Pr.File }): Pr.PR
 return {
  repo = string.match(meta.url, "^https?://[^/]+/([^/]+/[^/]+)/pull/") or "",
  number = meta.number,
  title = meta.title,
  body = meta.body or "",
  url = meta.url,
  author = if meta.author then meta.author.login else "",
  baseRef = meta.baseRefName,
  head = head,
  files = files,
 }
end

-- The review as GitHub's create-review request body; `comments` stays an array when empty.
local function requestJson(payload: Review.Payload): string
 local body = table.clone(payload)
 body.comments = tern.json.array(table.clone(payload.comments))
 return tern.json.encode(body, true)
end

local function saveDryRun(path: string, payload: Review.Payload, done: (Review.Delivery?, string?) -> ())
 local written, err = pcall(tern.fs.write, path, requestJson(payload))
 if written then done({ kind = "saved", path = path }, nil) else done(nil, "saving " .. path .. ": " .. tostring(err)) end
end

local function post(repo: string, pr: Pr.PR, payload: Review.Payload, done: (Review.Delivery?, string?) -> ())
 local fail = function(message: string) done(nil, message) end
 local argv = { "gh", "api", "--method", "POST", "repos/" .. pr.repo .. "/pulls/" .. pr.number .. "/reviews", "--input", "-" }
 run(argv, { cwd = repo, stdin = requestJson(payload), timeout_ms = GH_MS }, named("gh api", fail), function(stdout)
  local review = tern.json.decode(stdout)
  done({ kind = "posted", url = review.html_url }, nil)
 end)
end

-- Work on one saved copy at a time: `go` gets a `release` to call when it is done with the copy
-- (calling it again does nothing); a `go` that arrives while another holds the copy waits its
-- turn. Two PR links into one repo then never fetch into it together.
local holders: { [string]: { (release: () -> ()) -> () } } = {}

local function acquire(key: string, go: (release: () -> ()) -> ())
 local waiting = holders[key]
 if waiting then
  table.insert(waiting, go)
  return
 end
 local queue: { (release: () -> ()) -> () } = {}
 holders[key] = queue
 local function hand(next: (release: () -> ()) -> ())
  local released = false
  next(function()
   if released then return end
   released = true
   local following = table.remove(queue, 1)
   if following then hand(following) else holders[key] = nil end
  end)
 end
 hand(go)
end

-- The file that says a saved copy is set up, and the one that says its first download finished.
local READY, DOWNLOADED = "/prguide-ready", "/prguide-downloaded"

-- Makes the bare repo at `root` for the GitHub repo `slug` if it isn't set up: an empty repo that
-- fetches from GitHub and asks `gh` for a login, so a private repo works as `gh` does. Setting up
-- again after an interrupted attempt does the same steps over. Calls `done` once, with why it
-- failed or nil.
local function prepareCache(root: string, slug: string, done: (err: string?) -> ())
 if tern.fs.exists(root .. READY) then return done(nil) end
 local made, err = pcall(tern.fs.mkdir, root)
 if not made then return done("making " .. root .. ": " .. Text.errorLine(err)) end
 local job: Job = { repo = root, fail = done }
 withShellPath(function(path)
  local helper = "!\"" .. located("gh", path) .. "\" auth git-credential"
  run({ "git", "init", "--bare", "-q", root }, { timeout_ms = GIT_MS }, named("git init", done), function()
   git(job, "git config", { "config", "remote.origin.url", "https://github.com/" .. slug .. ".git" }, nil, function()
    -- The empty value drops the reader's own credential helpers, which would ask for a password.
    git(job, "git config", { "config", "--replace-all", "credential.helper", "" }, nil, function()
     git(job, "git config", { "config", "--add", "credential.helper", helper }, nil, function()
      local marked, problem = pcall(tern.fs.write, root .. READY, "")
      done(if marked then nil else "writing " .. root .. READY .. ": " .. Text.errorLine(problem))
     end)
    end)
   end)
  end)
 end)
end

local M = {}

function M.dryRunPath(number: number): string
 return "/tmp/prguide-review-" .. number .. ".json"
end

function M.guidePath(repo: Repo, number: number): string
 return repo.guides .. "/" .. number .. ".json"
end

-- Finds the checkout `dir` is in. Calls `done` once, with it or with what failed.
function M.findRepo(dir: string, done: (repo: Repo?, err: string?) -> ())
 local job: Job = { repo = dir, fail = function(message: string) done(nil, message) end }
 if not tern.fs.exists(dir) then return job.fail("No checkout at " .. dir) end
 git(job, "git rev-parse", { "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir" }, nil, function(stdout)
  local root, common = string.match(stdout, "^([^\n]+)\n([^\n]+)")
  done({ root = root :: string, guides = (common :: string) .. "/prguide" }, nil)
 end)
end

local function parentOf(path: string): string?
 return string.match(path, "^(.+)/[^/]+$")
end

-- The "owner/repo" the `origin` remote of the checkout at `root` points at, or nil.
local function originOf(root: string, done: (slug: string?) -> ())
 run({ "git", "-C", root, "remote", "get-url", "origin" }, { timeout_ms = GIT_MS }, function() done(nil) end, function(stdout)
  done(Links.remoteRepo(stdout))
 end)
end

-- The "owner/repo" the checkout `repo` is a clone of, or nil when it isn't on GitHub.
function M.originOf(repo: Repo, done: (slug: string?) -> ())
 originOf(repo.root, done)
end

-- The most folders-worth of candidates whose origin is looked up.
local CANDIDATE_CAP = 40

-- A checkout of the GitHub repo `slug` ("owner/repo"), for a PR link: `near` when its origin is that
-- repo, else a checkout in the folder holding `near` or holding its main checkout, or, with no
-- `near`, in `dir` or the folder holding it; preferring one named like the repo. Calls `done`
-- once, with it, or with nil when there is none.
function M.checkoutFor(near: Repo?, dir: string, slug: string, done: (repo: Repo?) -> ())
 local function search()
  local candidates, seen = {}, {}
  local folders: { string? } = {}
  if near then
   seen[near.root] = true
   -- `guides` is <common git dir>/prguide; the main checkout holds the common git dir.
   local mainCheckout = parentOf(parentOf(near.guides) or "")
   folders = { parentOf(near.root), if mainCheckout then parentOf(mainCheckout) else nil }
  elseif dir ~= "" then
   folders = { dir, parentOf(dir) }
  end
  for _, folder in folders do
   if folder and not seen[folder] and tern.fs.exists(folder) then
    seen[folder] = true
    local listed, found = pcall(tern.fs.list, folder)
    local names: { string } = if listed then found else {}
    for _, name in names do
     local path = folder .. "/" .. name
     if not seen[path] and tern.fs.exists(path .. "/.git") then
      seen[path] = true
      table.insert(candidates, { path = path, name = name })
     end
    end
   end
  end
  local repoName = string.lower(string.match(slug, "/(.+)$") :: string)
  local function ranks(a: { name: string }, b: { name: string }): boolean
   local aNamed, bNamed = string.lower(a.name) == repoName, string.lower(b.name) == repoName
   if aNamed ~= bNamed then return aNamed end
   return a.name < b.name
  end
  table.sort(candidates, ranks)
  while #candidates > CANDIDATE_CAP do table.remove(candidates) end
  local matches, waiting = {}, #candidates
  local function finish()
   if #matches == 0 then return done(nil) end
   table.sort(matches, ranks)
   M.findRepo(matches[1].path, function(repo) done(repo) end)
  end
  if waiting == 0 then return finish() end
  for _, candidate in candidates do
   originOf(candidate.path, function(origin)
    if Links.sameRepo(origin, slug) then table.insert(matches, candidate) end
    waiting -= 1
    if waiting == 0 then finish() end
   end)
  end
 end
 if not near then return search() end
 originOf(near.root, function(own)
  if Links.sameRepo(own, slug) then done(near) else search() end
 end)
end

-- PR Guide's own saved copy of the GitHub repo `slug`, which a PR link on `host` names; nothing is
-- downloaded until a PR of it opens. Gives why when the link can't have one.
function M.savedCopy(host: string?, slug: string): (Repo?, string?)
 local owner, name = string.match(slug, "^(%w[%w._-]*)/(%w[%w._-]*)$")
 if not owner or not name or string.lower(host or "") ~= "github.com" then
  return nil, "No checkout of " .. slug .. " was found next to this one, and PR Guide only downloads its own copy of repos on github.com."
 end
 local root = tern.plugin.data .. "/repos/" .. string.lower(owner) .. "/" .. string.lower(name) .. ".git"
 return { root = root, guides = root .. "/prguide", cache = slug }, nil
end

-- What the fetch stage says: for a saved copy, whether it is the first download.
local function fetchStage(target: Target): string
 local slug = target.cache
 if not slug then return "Fetching its commits into " .. target.repo end
 if tern.fs.exists(target.repo .. DOWNLOADED) then return "Checking " .. slug .. " for new commits" end
 return "Downloading " .. slug .. " (first time only)"
end

-- Loads `target` from GitHub and its checkout, reporting each stage as it starts. Calls `done`
-- once, with the PR or with what failed. A saved copy is set up first if need be, and held while
-- its commits are fetched, so that PRs of one repo opening together take turns.
function M.openPr(target: Target, progress: (stage: string) -> (), done: (pr: Pr.PR?, err: string?) -> ())
 local function open(release: () -> ())
  local job: Job = {
   repo = target.repo,
   fail = function(message: string)
    release()
    done(nil, message)
   end,
   partial = target.cache ~= nil,
  }
  progress("Reading the PR from GitHub")
  readMeta(job, target.pr, function(meta)
   progress(fetchStage(target))
   fetchRefs(job, meta, function(head, mergeBase)
    if target.cache then pcall(tern.fs.write, target.repo .. DOWNLOADED, "") end
    release()
    progress("Reading the changes")
    listChanges(job, mergeBase, head, function(changes)
     readPatches(job, mergeBase, head, changes, function(patches)
      progress("Reading the changed files")
      local paths = GitOutput.textPaths(changes, patches)
      prefetchSources(job, head, paths, function()
       readSources(job, head, paths, function(blobs)
        done(prOf(meta, head, GitOutput.files(changes, patches, blobs)), nil)
       end)
      end)
     end)
    end)
   end)
  end)
 end
 local slug = target.cache
 if not slug then return open(function() end) end
 progress("Preparing a saved copy of " .. slug)
 acquire(target.repo, function(release)
  prepareCache(target.repo, slug, function(err)
   if err then
    release()
    done(nil, err)
   else
    open(release)
   end
  end)
 end)
end

-- PR Guide's saved copy of the GitHub repo `slug` when it is already set up (the fixes page never sets one up), else nil.
function M.readySavedCopy(slug: string): Repo?
 local copy = M.savedCopy("github.com", slug)
 if copy and tern.fs.exists(copy.root .. READY) then return copy end
 return nil
end

-- What the fixes page reads from local git, as text: `mergeTree` is `git merge-tree --write-tree --name-only`
-- of the PR's head into its base (nil when the page did not ask), `shown` each conflicted file as the merged
-- tree holds it (with markers), `logs` the last commit on the base touching it since the merge base, and
-- `files` the annotated files as the head commit has them.
export type FixRead = { mergeTree: string?, shown: { [string]: string }, logs: { [string]: string }, files: { [string]: string } }

-- Files read for conflicts and for annotations, at most.
local CONFLICT_FILES, ANNOTATED_FILES = 8, 6

-- `git` in `job`'s repo whose exit status the caller reads: `merge-tree` exits 1 for a merge with conflicts.
local function gitStatus(job: Job, args: { string }, done: (out: Github.Out) -> ())
 local argv = { "git", "--literal-pathspecs", "-C", job.repo }
 table.move(args, 1, #args, #argv + 1, argv)
 M.runner(argv, { timeout_ms = GIT_MS }, done)
end

-- Runs `step` on each of `items` in turn, then `done`.
local function eachInTurn(items: { string }, step: (item: string, next: () -> ()) -> (), done: () -> ())
 local at = 0
 local function advance()
  at += 1
  if at > #items then return done() end
  step(items[at], advance)
 end
 advance()
end

local function firstLines(paths: { string }, cap: number): { string }
 local out = {}
 for _, path in paths do
  if #out < cap then table.insert(out, path) end
 end
 return out
end

-- Reads what the fixes page needs from the checkout `repo` (its own, or PR Guide's saved copy): fetches the
-- PR's head and base into refs/prguide/<n>/*, merges them with `git merge-tree` when the PR conflicts, and
-- reads each conflicted file and its cause with `git show` and `git log`. `paths` are annotated files to
-- read at the head with `git show`; a missing one is left out. Calls `done` once.
function M.readFixes(repo: Repo, pr: Model.HubPR, paths: { string }, done: (read: FixRead?, err: string?) -> ())
 local function open(release: () -> ())
  local job: Job = {
   repo = repo.root,
   fail = function(message: string)
    release()
    done(nil, message)
   end,
   partial = repo.cache ~= nil,
  }
  local meta: Meta = {
   number = pr.number, title = pr.title, body = nil, url = pr.url, author = nil,
   baseRefName = pr.baseBranch, headRefOid = pr.headOid, mergeCommit = nil,
  }
  local read: FixRead = { mergeTree = nil, shown = {}, logs = {}, files = {} }
  fetchRefs(job, meta, function(head, mergeBase)
   release()
   local base = refPrefix(pr.number) .. "/base"
   local function annotated()
    eachInTurn(firstLines(paths, ANNOTATED_FILES), function(path, next)
     gitStatus(job, { "show", head .. ":" .. path }, function(out)
      if out.status == 0 then read.files[path] = out.stdout end
      next()
     end)
    end, function() done(read, nil) end)
   end
   if not pr.conflicts then return annotated() end
   gitStatus(job, { "merge-tree", "--write-tree", "--name-only", head, base }, function(out)
    -- 0 is a clean merge and 1 a merge with conflicts; anything else is git failing.
    if out.timed_out or (out.status ~= 0 and out.status ~= 1) then
     return job.fail("git merge-tree: " .. (if out.timed_out then "timed out" else (string.match(out.stderr, "%S[^\r\n]*") or ("exit status " .. out.status))))
    end
    read.mergeTree = out.stdout
    local tree = Fixes.parseMergeTree(out.stdout)
    if tree == nil then return annotated() end
    eachInTurn(firstLines(tree.files, CONFLICT_FILES), function(path, next)
     gitStatus(job, { "show", tree.tree .. ":" .. path }, function(shown)
      if shown.status == 0 then read.shown[path] = shown.stdout end
      local log = { "log", "-1", "--format=%H%x09%an%x09%s", mergeBase .. ".." .. base, "--", path }
      gitStatus(job, log, function(logged)
       if logged.status == 0 then read.logs[path] = logged.stdout end
       next()
      end)
     end)
    end, annotated)
   end)
  end)
 end
 local slug = repo.cache
 if not slug then return open(function() end) end
 acquire(repo.root, open)
end

-- Sends `payload` to `to` in one go, first checking the PR still has the head the page shows.
-- Calls `done` once, with where the review went or why it didn't.
function M.submitReview(pr: Pr.PR, payload: Review.Payload, to: Destination, done: (Review.Delivery?, string?) -> ())
 local repo = to.repo
 local function deliver()
  if to.dryRunPath then saveDryRun(to.dryRunPath, payload, done) else post(repo :: string, pr, payload, done) end
 end
 if not repo then return deliver() end
 local fail = function(message: string) done(nil, message) end
 run({ "gh", "pr", "view", pr.url, "--json", "headRefOid" }, { cwd = repo, timeout_ms = GH_MS }, named("gh pr view", fail), function(stdout)
  local head = tern.json.decode(stdout).headRefOid
  if head ~= pr.head then
   fail("The PR moved on to " .. string.sub(head, 1, 7) .. " since this page loaded, so nothing was sent. Reopen it to review the new commits.")
   return
  end
  deliver()
 end)
end

-- Where the model, effort and lens the reader last picked are kept, in the plugin's key/value store.
local CHOICE_KEY = "model"

local function savedChoice(): { [string]: any }
 local ok, saved = pcall(tern.kv.get, CHOICE_KEY)
 return if ok and type(saved) == "table" then saved else {}
end

-- The model the reader last picked, else the one of OMP's review role, else its default role, as
-- the model and its effort; nil when there is none.
local function chosenModel(config: string): (string?, string?)
 local saved = savedChoice()
 if type(saved.model) == "string" then
  return saved.model, if type(saved.effort) == "string" then saved.effort else nil
 end
 local raw = if tern.fs.exists(config) then Agent.reviewModel(tern.fs.read(config)) else nil
 if not raw then return nil, nil end
 return Agent.parseChoice(raw)
end

-- The reader's agent: `omp` on their shell's PATH with the model they last picked or OMP's review
-- model, and the lens they last picked. Calls `done` once, with nil and why when `omp` or the
-- model is missing. `omp` is looked up as a file because an interactive shell may define it as an alias.
function M.findAgent(done: (agent: Agent.Agent?, why: string?) -> ())
 local home = tern.getenv("HOME")
 if not home then return done(nil, "your home directory is unknown") end
 withShellPath(function(path)
  local command = Agent.findOnPath(path, tern.fs.exists)
  if not command then return done(nil, "omp isn't installed (it isn't on your shell's PATH)") end
  local model, effort = chosenModel(home .. Agent.CONFIG)
  if not model then return done(nil, "omp has no model set (pick one in omp first)") end
  local lens = savedChoice().lens
  local agent = Agent.new(command, path, model, effort, if type(lens) == "string" then lens else Lens.DEFAULT)
  M.refreshLenses(agent)
  done(agent)
 end)
end

-- Remembers `agent`'s model, effort and lens for every PR and the next start.
function M.saveChoice(agent: Agent.Agent)
 pcall(tern.kv.set, CHOICE_KEY, { model = agent.model, effort = agent.effort, lens = agent.lens })
end

-- The folder the reader's own lenses live in.
function M.lensFolder(): string
 return tern.plugin.data .. "/lenses"
end

-- The text of every lens file in `dir`: the `.md` files but the README, none when it can't be read.
local function lensTexts(dir: string): { string }
 local texts = {}
 if not tern.fs.exists(dir) then return texts end
 local listed, names = pcall(tern.fs.list, dir)
 if not listed then return texts end
 for _, name in names do
  if string.lower(string.sub(name, -3)) == ".md" and string.lower(name) ~= "readme.md" and string.sub(name, 1, 1) ~= "." then
   local read, text = pcall(tern.fs.read, dir .. "/" .. name, LENS_BYTES)
   if read then table.insert(texts, text) end
  end
 end
 return texts
end

-- Lists the lenses `agent` can review through again: the plugin's own and the reader's, which
-- may have changed since the last look.
function M.refreshLenses(agent: Agent.Agent)
 agent.lenses = Lens.assemble(lensTexts(LENSES), lensTexts(M.lensFolder()))
end

-- Makes sure the reader's lens folder exists, with the README explaining lenses in it, and gives
-- its path; or says why it can't.
function M.prepareLensFolder(): (string?, string?)
 local dir = M.lensFolder()
 local ok, err = pcall(function()
  tern.fs.mkdir(dir)
  local readme = dir .. "/README.md"
  if not tern.fs.exists(readme) then tern.fs.write(readme, tern.fs.read(LENSES .. "/README.md")) end
 end)
 if ok then return dir, nil end
 return nil, Text.errorLine(err)
end

-- How long the last finished run took, which the next run's progress is estimated from; three
-- minutes before there is one.
local RUN_SECONDS_KEY, DEFAULT_RUN_SECONDS = "runSeconds", 180

function M.expectedRunSeconds(): number
 local ok, seconds = pcall(tern.kv.get, RUN_SECONDS_KEY)
 return if ok and type(seconds) == "number" and seconds > 0 then seconds else DEFAULT_RUN_SECONDS
end

function M.saveRunSeconds(seconds: number)
 pcall(tern.kv.set, RUN_SECONDS_KEY, seconds)
end

-- The PRs the reader opened lately, newest first, which the hub lists under Review requests. They
-- live in `hub.recent`; the picker kept them in `recent`, which is read until the hub moves them.
local RECENT_KEY, LEGACY_RECENT_KEY = "hub.recent", "recent"

local function kvGet(key: string): any
 local ok, saved = pcall(tern.kv.get, key)
 return if ok then saved else nil
end

function M.recentPrs(): { Sync.Opened }
 local saved = kvGet(RECENT_KEY)
 if saved == nil then saved = kvGet(LEGACY_RECENT_KEY) end
 return Sync.openedList(saved)
end

-- Moves the picker's `recent` list to `hub.recent` (a list already there stands) and deletes it.
-- Run when the hub first loads; safe to run again.
function M.migrateRecent()
 local legacy = kvGet(LEGACY_RECENT_KEY)
 if legacy == nil then return end
 if kvGet(RECENT_KEY) == nil then pcall(tern.kv.set, RECENT_KEY, Sync.openedList(legacy)) end
 pcall(tern.kv.set, LEGACY_RECENT_KEY, nil)
end

-- Puts `pr` first in the recently opened list.
function M.rememberPr(pr: Pr.PR)
 if pr.repo == "" then return end
 local opened = { repo = pr.repo, number = pr.number, title = pr.title, author = pr.author, at = os.date("!%Y-%m-%dT%H:%M:%SZ") :: string }
 pcall(tern.kv.set, RECENT_KEY, Sync.remember(M.recentPrs(), opened))
end

-- The models `agent` can run with, from `omp models`. Calls `done` once; the list is empty when
-- listing fails, which leaves the current model as the only choice.
function M.listModels(agent: Agent.Agent, done: (models: { Agent.Model }) -> ())
 run({ agent.command, "models", "--json" }, { env = { PATH = agent.path }, timeout_ms = GH_MS }, function() done({}) end, function(stdout)
  local ok, raw = pcall(tern.json.decode, stdout)
  done(if ok then Agent.parseModels(raw) else {})
 end)
end

-- Has `agent` write the guide for `pr` into `repo`'s guides: the run's directory gets the numbered
-- diff and the filled-in prompt, then `omp -p` runs in the checkout. Calls `done` once, with the
-- guide or the first line of what went wrong. A file that isn't a usable guide moves to the run's
-- directory, so the checkout never keeps one.
function M.generateGuide(agent: Agent.Agent, repo: Repo, pr: Pr.PR, done: (Guide.Guide?, string?) -> ())
 local dir = Agent.workDir(pr)
 local diffPath, promptPath, guidePath = dir .. "/diff.txt", dir .. "/prompt.md", M.guidePath(repo, pr.number)
 M.refreshLenses(agent)
 local lens = Agent.currentLens(agent)
 local fail = function(message: string) done(nil, message) end
 local prepared, err = pcall(function()
  tern.fs.mkdir(dir)
  tern.fs.mkdir(repo.guides)
  tern.fs.write(diffPath, Agent.numberedDiff(pr.files))
  tern.fs.write(promptPath, Agent.prompt(tern.fs.read(PROMPT), {
   repo = pr.repo, number = tostring(pr.number), title = pr.title, head = pr.head,
   base = refPrefix(pr.number) .. "/base", diffPath = diffPath, guidePath = guidePath, author = Agent.name(agent),
   lens = tern.json.encode(lens.name), focus = Agent.focus(lens),
  }))
 end)
 if not prepared then return fail(Text.errorLine(err)) end
 run(Agent.argv(agent, promptPath), { cwd = repo.root, env = { PATH = agent.path }, timeout_ms = AGENT_MS }, fail, function()
  if not tern.fs.exists(guidePath) then return fail(Agent.name(agent) .. " finished without writing " .. guidePath) end
  local guide, problem = Guide.read(guidePath, pr)
  if guide then return done(guide, nil) end
  local kept = dir .. "/guide.json"
  tern.fs.write(kept, tern.fs.read(guidePath))
  tern.fs.remove(guidePath)
  fail("the guide it wrote isn't usable: " .. (problem :: string) .. " (kept at " .. kept .. ")")
 end)
end

-- `Github.Runner` over `tern.process.run`: `argv[1]` is found on the shell's PATH like `run` does,
-- and the result is always handed back, a failed spawn as status -1.
function M.runner(argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Github.Out) -> ())
 local called = false
 local function settle(out: Github.Out)
  if called then return end
  called = true
  done(out)
 end
 withShellPath(function(path)
  local resolved = table.clone(argv)
  resolved[1] = located(argv[1], path)
  local spawned, err = pcall(tern.process.run, resolved, { cwd = opts.cwd, stdin = opts.stdin, timeout_ms = opts.timeout_ms, env = { PATH = path } }, function(result: ProcessResult)
   settle({ status = result.status, stdout = result.stdout, stderr = result.stderr, timed_out = result.timed_out })
  end)
  if not spawned then settle({ status = -1, stdout = "", stderr = Text.errorLine(err), timed_out = false }) end
 end)
end

-- Executes the read-only command plan from Summary.argv. No cwd, worktree, file or kv write.
function M.summarizeFeedback(argv: { string }, done: (string?, string?) -> ())
 -- Fail closed if a caller stops supplying the feedback-only plan. The boundary accepts
 -- one ephemeral, tool-free omp invocation, with no workspace or additional option.
 local guards = { "-p", "--no-tools", "--no-session", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-title" }
 if (#argv ~= 14 and #argv ~= 16) or (argv[1] ~= "omp" and string.sub(argv[1], -4) ~= "/omp") then
  return done(nil, "Invalid read-only summary command")
 end
 for index, flag in guards do
  if argv[index + 1] ~= flag then return done(nil, "Invalid read-only summary command") end
 end
 if argv[10] ~= "--system-prompt" or argv[12] ~= "--model" or (#argv == 16 and argv[14] ~= "--thinking") then
  return done(nil, "Invalid read-only summary command")
 end
 local called = false
 local function finish(text: string?, err: string?)
  if called then return end
  called = true
  done(text, err)
 end
 local ok, err = pcall(M.runner, argv, { timeout_ms = AGENT_MS }, function(out)
  if out.status ~= 0 or out.timed_out then
   return finish(nil, if out.timed_out then "Summarizing feedback timed out" else Text.errorLine(out.stderr ~= "" and out.stderr or "The agent returned no answer"))
  end
  finish(out.stdout, nil)
 end)
 if not ok then finish(nil, Text.errorLine(err)) end
end

-- Agent fixes: only this boundary reads Tandem's database, hub.clones, local journals and
-- environment. The caller owns the folder question and card lifecycle. No UI effects here.
local CLONES_KEY = "hub.clones"

function M.agentClones(): { [string]: string }
 local raw = kvGet(CLONES_KEY)
 local clones = {}
 if type(raw) == "table" then
  for slug, path in raw do
   if type(slug) == "string" and type(path) == "string" then clones[slug] = path end
  end
 end
 return clones
end

function M.rememberAgentClone(slug: string, path: string): string?
 local clones = M.agentClones()
 clones[string.lower(slug)] = path
 local ok, err = pcall(tern.kv.set, CLONES_KEY, clones)
 return if ok then nil else "Couldn't save the clone folder: " .. Text.errorLine(err)
end

-- A read-only SELECT, with SQL quoting and no migration or write to Tandem's store.
function M.tandemClone(slug: string, done: (string?) -> ())
 local home = tern.getenv("TANDEM_HOME") or ((tern.getenv("HOME") or "") .. "/.tandem")
 local database = home .. "/state.sqlite"
 if not tern.fs.exists(database) then return done(nil) end
 local quoted = string.gsub(string.lower(slug), "'", "''")
 local sql = "SELECT path FROM repo_locations WHERE repo = '" .. quoted .. "' LIMIT 1;"
 M.runner({ "sqlite3", "-readonly", "-json", database, sql }, { timeout_ms = 15_000 }, function(out)
  if out.status ~= 0 then return done(nil) end
  local ok, rows = pcall(tern.json.decode, out.stdout)
  local path = if ok and type(rows) == "table" and type(rows[1]) == "table" then rows[1].path else nil
  done(if type(path) == "string" and path ~= "" then path else nil)
 end)
end

function M.findAgentClone(near: Repo?, dir: string, slug: string, ask: (string, (string?) -> ()) -> (), done: (string?, string?) -> ())
 local function validate(path: string, name: string, callback: (boolean) -> ())
  originOf(path, function(origin) callback(Links.sameRepo(origin, name)) end)
 end
 AgentFix.locateClone(slug, {
  existing = function(name, callback)
   M.checkoutFor(near, dir, name, function(repo)
    if repo then return callback(repo.root) end
    local ready = M.readySavedCopy(name)
    callback(if ready then ready.root else nil)
   end)
  end,
  tandem = M.tandemClone,
  saved = function(name) return M.agentClones()[string.lower(name)] end,
  validate = validate, ask = ask, remember = M.rememberAgentClone, runner = M.runner,
 }, done)
end

local activeAgentFix: AgentFix.Engine? = nil
local activeBotFix: AgentFix.Fix? = nil

export type AgentFixRequest = {
 key: string, clone: string, checkout: string, branch: string, base: string, headOid: string,
 number: number, regenerate: { [string]: { string } }?, input: AgentFix.Input?,
}

-- Start separately from clone lookup, so the glue can finish its folder question first.
-- A ready fix keeps the single-run slot until returnAgentFix succeeds after Push or Discard.
function M.startAgentFix(request: AgentFixRequest, agent: Agent.Agent, now: number, changed: (AgentFix.Outcome) -> (), done: (AgentFix.Fix?, string?) -> ()): AgentFix.Engine?
 if activeAgentFix and activeAgentFix.busy() then done(nil, "An agent fix already holds a worktree"); return nil end
 activeAgentFix = nil
 local home = tern.getenv("HOME")
 if not home then done(nil, "The home directory is unknown"); return nil end
 if request.number < 1 or request.number % 1 ~= 0 or not string.match(request.headOid, "^%x+$") or string.sub(request.base, 1, 1) == "-" or request.base == "" then
  done(nil, "Invalid PR refs"); return nil
 end
 local spec: AgentFix.Spec = {
  key = request.key, clone = request.clone, checkout = request.checkout,
  pool = tern.getenv("TANDEM_POOL_ROOT") or (home .. "/.tandem/pool"),
  branch = request.branch, base = request.base, headOid = request.headOid, number = request.number,
  tool = tern.plugin.dir .. "/tools/conflicts", omp = agent.command, model = agent.model,
  effort = agent.effort, regenerate = request.regenerate, input = request.input,
 }
 local function samePath(a: string, b: string, callback: (boolean?, string?) -> ())
  -- Physical paths protect /tmp versus /private/tmp and symlinked checkouts. Also reject
  -- the source clone itself, which can differ from the currently viewed checkout.
  M.runner({ "python3", "-c", "import os,sys; print('same' if os.path.realpath(sys.argv[1]) in [os.path.realpath(p) for p in sys.argv[2:]] else 'different')", a, b, spec.clone }, { timeout_ms = 15_000 }, function(out)
   if out.status ~= 0 then return callback(nil, "Couldn't verify the acquired worktree path") end
   local result = trimmed(out.stdout)
   callback(if result == "different" then false elseif result == "same" then true else nil, nil)
  end)
 end
 local function resolutions(path: string, callback: ({ { id: string, lines: { AgentFix.ResolvedLine } } }?, string?) -> ())
  M.runner({ "git", "-C", path, "rev-parse", "--absolute-git-dir" }, { timeout_ms = GIT_MS }, function(out)
   if out.status ~= 0 then return callback(nil, "Couldn't locate the conflict journal") end
   local ok, rows = pcall(function()
    local journal = tern.json.decode(tern.fs.read(trimmed(out.stdout) .. "/prguide-conflicts.json", 16 * 1024 * 1024))
    local resolved = {}
    for _, hunk in journal.hunks do
     if hunk.resolved then table.insert(resolved, { id = hunk.id, lines = hunk.resolved.lines }) end
    end
    return resolved
   end)
   callback(if ok then rows else nil, if ok then nil else Text.errorLine(rows))
  end)
 end
 local engine: AgentFix.Engine
 activeBotFix = nil
 engine = AgentFix.engine(spec, { runner = M.runner, decode = tern.json.decode, samePath = samePath, resolutions = resolutions }, now, changed, function(fix, err)
  if fix and request.input then activeBotFix = fix end
  if not fix and not engine.busy() then activeAgentFix = nil end
  done(fix, err)
 end)
 activeAgentFix = engine
 engine.begin()
 return engine
end

-- The later lifecycle calls this only after a successful Push or confirmed Discard. It runs
-- no Git write and never pushes; both ownership guards always reach treehouse.
function M.returnAgentFix(path: string, done: (boolean?, string?) -> ())
 local engine = activeAgentFix
 if not engine then return done(nil, "No agent fix holds a worktree") end
 local lease = engine.held()
 if not lease or lease.path ~= path then return done(nil, "The worktree does not belong to this agent fix") end
 engine.release(function(ok, err)
  if ok and (engine.held() ~= nil or engine.busy()) then ok, err = nil, "The engine still holds the worktree lease" end
  if ok and activeAgentFix == engine then activeAgentFix, activeBotFix = nil, nil end
  done(ok, err)
 end)
end

export type AgentFixRead = { files: { [string]: string }, diff: string, originals: { [string]: ReviewFix.Original }? }

local function ownsAgentFix(fix: AgentFix.Fix): boolean
 local engine = activeAgentFix
 local lease = if engine then engine.held() else nil
 return lease ~= nil and lease.path == fix.worktree
end

-- Read only paths with recorded conflicts, at the exact commit the reader will push.
function M.readAgentFix(fix: AgentFix.Fix, done: (AgentFixRead?, string?) -> ())
 if not ownsAgentFix(fix) then return done(nil, "The worktree does not belong to this agent fix") end
 local commands, problem = ReviewFix.readCommands(fix)
 if not commands then return done(nil, problem) end
 local result: AgentFixRead = { files = {}, diff = "" }
 local index = 0
 local nextCommand: () -> ()
 nextCommand = function()
  index += 1
  local command = (commands :: { ReviewFix.Command })[index]
  if not command then return done(result, nil) end
  local called = false
  local function read(out: Github.Out)
   if called then return end
   called = true
   if out.status ~= 0 or out.timed_out then return done(nil, if out.timed_out then "Reading the fix timed out" else Text.errorLine(if out.stderr ~= "" then out.stderr else "Git could not read the fix")) end
   if not ownsAgentFix(fix) then return done(nil, "The worktree lease changed") end
   if command.argv[4] == "rev-parse" then
    if activeBotFix == fix then
     -- Bot edits have exact original sides in the retained engine result, with no conflict journal.
     -- Only this exact ready result may use them; commit files still pass ReviewFix.build.
     local snapshots: { [string]: ReviewFix.Original } = {}
     for _, hunk in fix.hunks do
      snapshots[hunk.id] = { path = hunk.path, start = hunk.start, base = table.clone(hunk.base), ours = table.clone(hunk.ours), theirs = table.clone(hunk.theirs) }
     end
     result.originals = snapshots
     return nextCommand()
    end
    local ok, originals = pcall(function()
     local journal = tern.json.decode(tern.fs.read(trimmed(out.stdout) .. "/prguide-conflicts.json", 16 * 1024 * 1024))
     assert(type(journal.identity) == "string" and string.sub(journal.identity, 1, #fix.headOid + 1) == fix.headOid .. ":", "The conflict journal belongs to a different pull request head")
     local snapshots: { [string]: ReviewFix.Original } = {}
     local function lines(value: any): { string }
      assert(type(value) == "table", "The original conflict sides are missing")
      local exact: { string } = {}
      for _, line in value do
       assert(type(line) == "string", "The original conflict side is invalid")
       table.insert(exact, (string.gsub(line, "[\r\n]+$", "")))
      end
      return exact
     end
     for _, hunk in journal.hunks do
      assert(type(hunk.id) == "string" and not snapshots[hunk.id], "The conflict journal has missing or duplicate ids")
      snapshots[hunk.id] = { path = hunk.path, start = hunk.start, base = lines(hunk.base), ours = lines(hunk.ours), theirs = lines(hunk.theirs) }
     end
     return snapshots
    end)
    if not ok then return done(nil, Text.errorLine(originals)) end
    result.originals = originals
   elseif command.argv[5] == "diff" then result.diff = out.stdout
   else
    local ref = command.argv[#command.argv]
    result.files[string.sub(ref, #fix.commit + 2)] = out.stdout
   end
   nextCommand()
  end
  local ok, err = pcall(M.runner, command.argv, { cwd = command.cwd, timeout_ms = GIT_MS }, read)
  if not ok then read({ status = -1, stdout = "", stderr = tostring(err), timed_out = false }) end
 end
 nextCommand()
end

-- P is the only caller. Validate the pure plan again, read the PR's actual head repo
-- (including forks), and preserve Git's ordinary non-fast-forward protection.
function M.pushAgentFix(plan: ReviewFix.Plan, canPush: () -> boolean, done: (boolean?, string?) -> ())
 local validated, problem = ReviewFix.plan("push", plan.request)
 if plan.kind ~= "push" or not validated or not validated.command then return done(nil, problem or "No push is planned") end
 local request, fix = validated.request, validated.request.fix
 if not ownsAgentFix(fix) then return done(nil, "The worktree does not belong to this agent fix") end
 local finished = false
 local function finish(ok: boolean?, err: string?)
  if finished then return end
  finished = true
  done(ok, err)
 end
 local function run(argv: { string }, callback: (Github.Out) -> ())
  if not canPush() then return finish(nil, "The selected fix changed") end
  local called = false
  local function reply(out: Github.Out)
   if called or finished then return end
   called = true
   if not ownsAgentFix(fix) then return finish(nil, "The worktree lease changed") end
   if out.status ~= 0 or out.timed_out then return finish(nil, if out.timed_out then "Pushing the fix timed out" else Text.errorLine(if out.stderr ~= "" then out.stderr else "Git could not push the fix")) end
   callback(out)
  end
  local ok, err = pcall(M.runner, argv, { cwd = fix.worktree, timeout_ms = 60_000 }, reply)
  if not ok then reply({ status = -1, stdout = "", stderr = tostring(err), timed_out = false }) end
 end
 run({ "gh", "pr", "view", tostring(request.number), "--repo", request.repo, "--json", "headRefName,headRefOid,headRepository,headRepositoryOwner" }, function(out)
  local ok, meta = pcall(tern.json.decode, out.stdout)
  if not ok or type(meta) ~= "table" or meta.headRefName ~= fix.branch or type(meta.headRepository) ~= "table" then
   return finish(nil, "The pull request branch changed or is missing")
  end
  local remoteRepo = meta.headRepository.nameWithOwner
  if not remoteRepo and type(meta.headRepositoryOwner) == "table" and type(meta.headRepositoryOwner.login) == "string" and type(meta.headRepository.name) == "string" then
   remoteRepo = meta.headRepositoryOwner.login .. "/" .. meta.headRepository.name
  end
  if type(remoteRepo) ~= "string" then return finish(nil, "The pull request head repository is missing") end
  local remotePlan, err = ReviewFix.plan("push", request, nil, remoteRepo)
  if not remotePlan or not remotePlan.command then return finish(nil, err) end
  local command = remotePlan.command
  -- Reconcile an earlier push whose response was lost. Never send it twice on a cleanup retry.
  if meta.headRefOid ~= fix.headOid and meta.headRefOid ~= fix.commit then return finish(nil, "The pull request head changed; refresh the board") end
  run({ "git", "-C", fix.worktree, "ls-remote", "--heads", command.argv[5], "refs/heads/" .. fix.branch }, function(remote)
   local head = string.match(remote.stdout, "^(%x+)%s+refs/heads/")
   if head == fix.commit then return finish(true, nil) end
   if head ~= fix.headOid then return finish(nil, "The remote branch changed; refresh the board") end
   run(command.argv, function() finish(true, nil) end)
  end)
 end)
end

return M
