--!strict
-- Where the plugin reaches outside itself: `gh` for the PR list, the PR's metadata and posting the
-- review, `git` in the local checkout for the PR's changes and files, and the checkout's guide
-- files. Each step starts the next from its callback; the first failure ends the chain with a
-- message naming the step.
local GitOutput = require("./git-output")
local Picker = require("./picker")
local Pr = require("./pr")
local Review = require("./review")
local Text = require("./text")

-- A PR as the reader named it (number, URL or branch) and the root of its repository's checkout.
export type Target = { pr: string, repo: string }

-- A checkout: its root, and the directory holding guides for its PRs, shared by its worktrees.
export type Repo = { root: string, guides: string }

-- Where a submitted review goes: in a dry run, the file at `dryRunPath`; otherwise GitHub. Without
-- a `repo` (the bundled sample) there is no PR to check or post to.
export type Destination = { repo: string?, dryRunPath: string? }

type Fail = (message: string) -> ()
type Job = { repo: string, fail: Fail }
type Meta = { number: number, title: string, url: string, author: { login: string }?, baseRefName: string, headRefOid: string }

local GH_MS = 30_000
local GIT_MS = 60_000
local GIT_FETCH_MS = 300_000

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

-- Runs `argv` and hands its stdout to `ok`; a failed run, or an error from `ok` reading unexpected
-- output, goes to `fail`.
local function run(argv: { string }, opts: ProcessOptions, fail: Fail, ok: (stdout: string) -> ())
 local spawned, err = pcall(tern.process.run, argv, opts, function(result: ProcessResult)
  if result.status ~= 0 then
   fail(reason(result))
   return
  end
  local handled, problem = pcall(ok, result.stdout)
  if not handled then fail(Text.errorLine(problem)) end
 end)
 if not spawned then fail(Text.errorLine(err)) end
end

-- `fail` with each message prefixed by the step that failed.
local function named(what: string, fail: Fail): Fail
 return function(message: string) fail(what .. ": " .. message) end
end

local function git(job: Job, what: string, args: { string }, stdin: string?, ok: (stdout: string) -> ())
 local argv = { "git", "--literal-pathspecs", "-C", job.repo }
 table.move(args, 1, #args, #argv + 1, argv)
 run(argv, { stdin = stdin, timeout_ms = if args[1] == "fetch" then GIT_FETCH_MS else GIT_MS }, named(what, job.fail), ok)
end

local function trimmed(text: string): string
 return (string.gsub(text, "%s+$", ""))
end

local function readMeta(job: Job, pr: string, ok: (meta: Meta) -> ())
 local argv = { "gh", "pr", "view", pr, "--json", "number,title,url,author,baseRefName,headRefOid" }
 run(argv, { cwd = job.repo, timeout_ms = GH_MS }, named("gh pr view", job.fail), function(stdout)
  ok(tern.json.decode(stdout))
 end)
end

-- Fetches the PR's head and base into refs/prguide/<n>/*, leaving branches and the working tree
-- alone; hands on the head commit and where it branched from the base.
local function fetchRefs(job: Job, meta: Meta, ok: (head: string, mergeBase: string) -> ())
 local prefix = "refs/prguide/" .. meta.number
 local fetch = {
  "fetch", "--no-tags", "--no-write-fetch-head", "origin",
  "+refs/pull/" .. meta.number .. "/head:" .. prefix .. "/head",
  "+refs/heads/" .. meta.baseRefName .. ":" .. prefix .. "/base",
 }
 git(job, "git fetch", fetch, nil, function()
  git(job, "git rev-parse", { "rev-parse", prefix .. "/head" }, nil, function(head)
   git(job, "git merge-base", { "merge-base", prefix .. "/head", prefix .. "/base" }, nil, function(mergeBase)
    ok(trimmed(head), trimmed(mergeBase))
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

local M = {}

function M.dryRunPath(number: number): string
 return "/tmp/prguide-review-" .. number .. ".json"
end

function M.guidePath(repo: Repo, number: number): string
 return repo.guides .. "/" .. number .. ".json"
end

-- The PRs of `repo` that have a guide file.
function M.guidedPrs(repo: Repo): { [number]: boolean }
 if not tern.fs.exists(repo.guides) then return {} end
 return Picker.guideNumbers(tern.fs.list(repo.guides))
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

-- The open PRs of the checkout at `root` and the number of its current branch's PR, if it has one.
-- Calls `done` once, with the list or with the first line of what `gh` said went wrong.
function M.listPrs(root: string, done: (prs: { Picker.Summary }?, current: number?, err: string?) -> ())
 local prs, current, waiting, failed = nil, nil, 2, false
 local function finish()
  waiting -= 1
  if waiting == 0 and not failed then done(prs, current, nil) end
 end
 local list = { "gh", "pr", "list", "--state", "open", "--limit", "50", "--json", Picker.LIST_FIELDS }
 run(list, { cwd = root, timeout_ms = GH_MS }, function(message)
  failed = true
  done(nil, nil, message)
 end, function(stdout)
  prs = Picker.parse(stdout)
  finish()
 end)
 -- A branch without a PR is no failure: the list just has no "This branch" row.
 run({ "gh", "pr", "view", "--json", "number" }, { cwd = root, timeout_ms = GH_MS }, finish, function(stdout)
  current = tern.json.decode(stdout).number
  finish()
 end)
end

-- Loads `target` from GitHub and its checkout, reporting each stage as it starts. Calls `done`
-- once, with the PR or with what failed.
function M.openPr(target: Target, progress: (stage: string) -> (), done: (pr: Pr.PR?, err: string?) -> ())
 local job: Job = { repo = target.repo, fail = function(message: string) done(nil, message) end }
 progress("Reading the PR from GitHub")
 readMeta(job, target.pr, function(meta)
  progress("Fetching its commits into " .. target.repo)
  fetchRefs(job, meta, function(head, mergeBase)
   progress("Reading the changes")
   listChanges(job, mergeBase, head, function(changes)
    readPatches(job, mergeBase, head, changes, function(patches)
     progress("Reading the changed files")
     readSources(job, head, GitOutput.textPaths(changes, patches), function(blobs)
      done(prOf(meta, head, GitOutput.files(changes, patches, blobs)), nil)
     end)
    end)
   end)
  end)
 end)
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

return M
