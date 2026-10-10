--!strict
-- The PR hub's GitHub boundary. Every GitHub call goes through the injected `Runner` (the real one
-- is `Fetch.runner`, tests pass a fake), JSON text is decoded by the injected `decode`
-- (`tern.json.decode`), and nothing here reads `tern`, the clock or a file. The parsers take
-- already decoded tables and never throw on a missing field. Each call returns its own rate-limit
-- envelope; the caller sums them. Failures are `Error` values, never thrown.
--
-- Not built yet (each lands with the issue that first needs it): `details`, `history`, `parseDetails`
-- and the `commands` builders other than the merge, cancel-merge and update-branch ones.
local Model = require("./hub/model")

type HubPR = Model.HubPR
type Checks = Model.Checks
type Error = Model.Error
type RateLimit = Model.RateLimit
type Refresh = Model.Refresh
type PRRef = Model.PRRef
type OpenThread = Model.OpenThread
type MergeMethod = Model.MergeMethod
type MergeFailure = Model.MergeFailure
type PendingMerge = Model.PendingMerge

-- What `tern.process.run` gives and takes, minus the `cx`. src/fetch.luau exports the real runner.
export type Out = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Runner = (argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Out) -> ()) -> ()
export type Decode = (text: string) -> any

export type RefreshRequest = { added: { PRRef }, previous: { HubPR } }
export type Probe = { changed: boolean, lastModified: string?, pollSeconds: number? }
export type ChecksUpdate = { byId: { [string]: { headOid: string, checks: Checks } }, rateLimit: RateLimit }
export type Command = { argv: { string }, stdin: string? }
-- What a repo declares and what its last merges show. `checkedAt` is "" here: the block stamps it, because this module reads no clock.
export type Detected = { declared: MergeMethod?, learned: MergeMethod?, viewerDefault: "squash" | "merge" | "rebase", checkedAt: string }

export type Client = {
	refresh: (req: RefreshRequest, done: (value: Refresh?, err: Error?) -> ()) -> (),
	probe: (since: string?, done: (value: Probe?, err: Error?) -> ()) -> (),
	checks: (ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ()) -> (),
	detect: (repo: string, done: (value: Detected?, err: Error?) -> ()) -> (),
	run: (command: Command, done: (stdout: string?, err: Error?) -> ()) -> (),
}

-- Each of these mirrors docs/hub/queries/<file>.graphql without its `#` comment lines;
-- `tools/luau-fixtures --check` fails when they differ.
local HUB_QUERY = [=[
query Hub($n: Int = 50) {
  viewer { login }
  rateLimit { cost remaining resetAt limit used nodeCount }
  mine: search(type: ISSUE, query: "is:pr is:open author:@me archived:false", first: $n) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ...Hub }
  }
  requested: search(type: ISSUE, query: "is:pr is:open review-requested:@me archived:false", first: $n) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ...Hub }
  }
  reviewed: search(type: ISSUE, query: "is:pr is:open reviewed-by:@me -author:@me archived:false", first: $n) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ...Hub }
  }
}

fragment Hub on PullRequest {
  id
  number
  title
  url
  isDraft
  createdAt
  updatedAt
  headRefOid
  baseRefName
  additions
  deletions
  changedFiles
  author { __typename login }
  repository { nameWithOwner }
  reviewDecision
  mergeable
  mergeStateStatus
  totalCommentsCount
  autoMergeRequest { enabledAt }
  timelineItems(last: 1, itemTypes: [REMOVED_FROM_MERGE_QUEUE_EVENT]) { nodes { ... on RemovedFromMergeQueueEvent { createdAt reason } } }
  commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state contexts(first: 0) { totalCount checkRunCountsByState { state count } statusContextCountsByState { state count } } } } } }
  latestReviews(first: 20) {
    nodes { author { __typename login } state submittedAt commit { oid } }
  }
  reviewRequests(first: 20) {
    nodes { requestedReviewer {
      __typename
      ... on User { login }
      ... on Team { slug }
    } }
  }
  reviewThreads(first: 100) { totalCount nodes { isResolved } }
  comments(last: 1) { totalCount nodes { updatedAt author { login } } }
}]=]

local THREADS_QUERY = [=[
query Threads($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id number reviewThreads(first: 30) { nodes { isResolved comments(first: 1) { nodes { author { __typename login } } } } } } }
}]=]

local CHECKS_QUERY = [=[
query Checks($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id number headRefOid commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 0) { checkRunCountsByState { state count } statusContextCountsByState { state count } } } } } } } }
}]=]

-- These two mirror docs/hub/queries/merge-detect.graphql and merge-failure.graphql the same way.
local MERGE_DETECT_QUERY = [=[
query MergeDetect($owner: String!, $name: String!) {
  rateLimit { cost remaining limit resetAt }
  repository(owner: $owner, name: $name) {
    viewerDefaultMergeMethod
    mergeQueue { id }
    aviator: object(expression: "HEAD:.aviator/config.yml") { __typename }
    pullRequests(states: MERGED, first: 8, orderBy: { field: UPDATED_AT, direction: DESC }) {
      nodes { mergedAt mergedBy { __typename login } comments(last: 5) { nodes { createdAt body author { __typename login } } } }
    }
  }
}]=]

local MERGE_FAILURE_QUERY = [=[
query MergeFailure($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id headRefOid
    comments(last: 10) { nodes { createdAt body author { __typename login } } }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 50) { nodes {
      __typename
      ... on CheckRun { name conclusion completedAt }
      ... on StatusContext { context state createdAt }
    } } } } } }
  } }
}]=]

local GRAPHQL_MS = 60_000
local REST_MS = 30_000
local RUN_MS = 120_000
-- `nodes(ids:)` takes at most 250; a refresh reads the threads of this many PRs and leaves the rest unknown.
local THREAD_IDS_MAX = 100
local NO_LIMIT: RateLimit = { cost = 0, remaining = 0, limit = 0, resetAt = "" }

local M = {}

-- Reading decoded JSON without trusting its shape.

local function tbl(value: any): any?
	if type(value) == "table" then return value end
	return nil
end

local function str(value: any): string?
	if type(value) == "string" then return value end
	return nil
end

local function int(value: any): number
	if type(value) == "number" then return value end
	return 0
end

local function list(value: any): { any }
	local t = tbl(value)
	if t == nil then return {} end
	local out = {}
	for _, item in t :: { any } do
		if type(item) == "table" then table.insert(out, item) end
	end
	return out
end

local function rateLimitOf(raw: any): RateLimit?
	local t = tbl(raw)
	if t == nil or type(t.cost) ~= "number" then return nil end
	return { cost = t.cost, remaining = int(t.remaining), limit = int(t.limit), resetAt = str(t.resetAt) or "" }
end

-- Check counts. Skipped and neutral runs pass, as GitHub's own summary counts them.

local FAILING_RUNS = { FAILURE = true, TIMED_OUT = true, STARTUP_FAILURE = true, ACTION_REQUIRED = true, CANCELLED = true }
local PENDING_RUNS = { IN_PROGRESS = true, QUEUED = true, PENDING = true, WAITING = true }
local PASSING_RUNS = { SUCCESS = true, NEUTRAL = true, SKIPPED = true, COMPLETED = true }
local FAILING_STATUSES = { ERROR = true, FAILURE = true }
local PENDING_STATUSES = { PENDING = true, EXPECTED = true }
local ROLLUP_STATES: { [string]: Model.CheckState } = {
	SUCCESS = "passing", FAILURE = "failing", ERROR = "failing", PENDING = "pending", EXPECTED = "pending",
}

local function checksOf(commits: any): Checks
	local none: Checks = { state = "none", passing = 0, failing = 0, pending = 0 }
	local first = list(tbl(commits) and (commits :: any).nodes)[1]
	local commit = first and tbl(first.commit)
	local rollup = commit and tbl(commit.statusCheckRollup)
	if rollup == nil then return none end
	local passing, failing, pending = 0, 0, 0
	local contexts = tbl(rollup.contexts) or {}
	for _, row in list(contexts.checkRunCountsByState) do
		local state, count = str(row.state) or "", int(row.count)
		if FAILING_RUNS[state] then failing += count
		elseif PENDING_RUNS[state] then pending += count
		elseif PASSING_RUNS[state] then passing += count end
	end
	for _, row in list(contexts.statusContextCountsByState) do
		local state, count = str(row.state) or "", int(row.count)
		if FAILING_STATUSES[state] then failing += count
		elseif PENDING_STATUSES[state] then pending += count
		elseif state == "SUCCESS" then passing += count end
	end
	local state = ROLLUP_STATES[str(rollup.state) or ""]
	if state == nil then
		state = if failing > 0 then "failing" elseif pending > 0 then "pending" elseif passing > 0 then "passing" else "none"
	end
	return { state = state, passing = passing, failing = failing, pending = pending }
end

-- hub-f

local VERDICTS: { [string]: Model.Verdict } = {
	APPROVED = "approved", CHANGES_REQUESTED = "changes_requested", COMMENTED = "commented", DISMISSED = "dismissed",
}
local DECISIONS = {
	APPROVED = "approved", CHANGES_REQUESTED = "changes_requested", REVIEW_REQUIRED = "review_required",
}

local function lowerFirst(text: string): string
	return string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- The latest time the PR left the merge queue, unless auto-merge was asked for again after that.
local function queueFailure(node: any): Model.MergeFailure?
	local event = list(tbl(node.timelineItems) and node.timelineItems.nodes)[1]
	local removedAt = event and str(event.createdAt)
	if removedAt == nil then return nil end
	local auto = tbl(node.autoMergeRequest)
	local again = auto and str(auto.enabledAt)
	if again and again > removedAt then return nil end
	local why = str(event.reason)
	local reason = "Removed from the merge queue"
	if why and why ~= "" then reason ..= ": " .. lowerFirst(why) end
	return { kind = "queue", reason = reason }
end

local function reviewsOf(node: any, viewer: string): Model.ReviewState
	local latest: { Model.Review } = {}
	local mine: Model.Review? = nil
	for _, row in list(tbl(node.latestReviews) and node.latestReviews.nodes) do
		local author = tbl(row.author)
		local login = author and str(author.login)
		local verdict = VERDICTS[str(row.state) or ""]
		if login and verdict then
			local commit = tbl(row.commit)
			local review: Model.Review = {
				author = login, bot = author.__typename == "Bot", verdict = verdict,
				at = str(row.submittedAt) or "", oid = commit and str(commit.oid) or "",
			}
			if login == viewer then mine = review else table.insert(latest, review) end
		end
	end
	local requested: { string } = {}
	local requestedMe = false
	for _, row in list(tbl(node.reviewRequests) and node.reviewRequests.nodes) do
		local who = tbl(row.requestedReviewer)
		local name = who and (str(who.login) or str(who.slug))
		if name then
			table.insert(requested, name)
			if who.login == viewer then requestedMe = true end
		end
	end
	local unresolved = 0
	for _, row in list(tbl(node.reviewThreads) and node.reviewThreads.nodes) do
		if row.isResolved == false then unresolved += 1 end
	end
	local comments = tbl(node.comments)
	return {
		decision = DECISIONS[str(node.reviewDecision) or ""] or "none",
		latest = latest, mine = mine, requestedMe = requestedMe, requested = requested,
		unresolved = unresolved, threads = {}, threadsKnown = unresolved == 0,
		comments = if comments then int(comments.totalCount) else 0,
	}
end

local function prOf(node: any, viewer: string, authored: boolean): HubPR?
	local id, number = str(node.id), node.number
	local repo = tbl(node.repository) and str(node.repository.nameWithOwner)
	if id == nil or type(number) ~= "number" or repo == nil then return nil end
	local author = tbl(node.author)
	local login = author and str(author.login) or "ghost"
	return {
		key = repo .. "#" .. number, id = id, repo = repo, number = number,
		url = str(node.url) or ("https://github.com/" .. repo .. "/pull/" .. number),
		title = str(node.title) or "",
		author = login, authorBot = author ~= nil and author.__typename == "Bot",
		role = if authored or login == viewer then "mine" else "review",
		draft = node.isDraft == true,
		createdAt = str(node.createdAt) or "", lastActivityAt = str(node.updatedAt) or "",
		headOid = str(node.headRefOid) or "", baseBranch = str(node.baseRefName) or "",
		additions = int(node.additions), deletions = int(node.deletions), files = int(node.changedFiles),
		checks = checksOf(node.commits),
		conflicts = node.mergeable == "CONFLICTING", behind = node.mergeStateStatus == "BEHIND",
		reviews = reviewsOf(node, viewer),
		mergeFailure = queueFailure(node), pending = nil,
		tandem = false, addedByMe = false,
	}
end

function M.parseHub(raw: any): { prs: { HubPR }, viewer: string, rateLimit: RateLimit, truncated: boolean }?
	local data = tbl(raw) and tbl(raw.data)
	local viewer = data and tbl(data.viewer) and str(data.viewer.login)
	if data == nil or viewer == nil then return nil end
	local prs: { HubPR } = {}
	local at: { [string]: number } = {}
	local truncated = false
	local function take(node: any, authored: boolean)
		local pr = prOf(node, viewer, authored)
		if pr == nil then return end
		local seen = at[pr.id]
		if seen == nil then
			table.insert(prs, pr)
			at[pr.id] = #prs
		elseif pr.role == "mine" then
			prs[seen].role = "mine"
		end
	end
	for _, name in { "mine", "requested", "reviewed" } do
		local search = tbl(data[name])
		if search then
			if tbl(search.pageInfo) and search.pageInfo.hasNextPage == true then truncated = true end
			for _, node in list(search.nodes) do take(node, name == "mine") end
		end
	end
	-- `added0`, `added1`, …: a PR added by link, as `repository { pullRequest }`.
	local aliases: { string } = {}
	for name in data do
		if string.match(name :: string, "^added%d+$") then table.insert(aliases, name :: string) end
	end
	local function position(name: string): number
		return tonumber(string.sub(name, 6)) or 0
	end
	table.sort(aliases, function(a, b) return position(a) < position(b) end)
	for _, name in aliases do
		local repository = tbl(data[name])
		local node = repository and tbl(repository.pullRequest)
		if node then take(node, false) end
	end
	return { prs = prs, viewer = viewer, rateLimit = rateLimitOf(data.rateLimit) or NO_LIMIT, truncated = truncated }
end

-- threads

function M.parseThreads(raw: any): { threads: { [string]: { OpenThread } }, rateLimit: RateLimit }?
	local data = tbl(raw) and tbl(raw.data)
	if data == nil or tbl(data.nodes) == nil then return nil end
	local threads: { [string]: { OpenThread } } = {}
	for _, node in list(data.nodes) do
		local id = str(node.id)
		if id and tbl(node.reviewThreads) then
			local open: { OpenThread } = {}
			for _, thread in list(node.reviewThreads.nodes) do
				if thread.isResolved == false then
					local first = list(tbl(thread.comments) and thread.comments.nodes)[1]
					local author = first and tbl(first.author)
					table.insert(open, { author = author and str(author.login) or "ghost", bot = author ~= nil and author.__typename == "Bot" })
				end
			end
			threads[id] = open
		end
	end
	return { threads = threads, rateLimit = rateLimitOf(data.rateLimit) or NO_LIMIT }
end

-- checks

function M.parseChecks(raw: any): ChecksUpdate?
	local data = tbl(raw) and tbl(raw.data)
	if data == nil or tbl(data.nodes) == nil then return nil end
	local byId: { [string]: { headOid: string, checks: Checks } } = {}
	for _, node in list(data.nodes) do
		local id = str(node.id)
		if id and tbl(node.commits) then
			byId[id] = { headOid = str(node.headRefOid) or "", checks = checksOf(node.commits) }
		end
	end
	return { byId = byId, rateLimit = rateLimitOf(data.rateLimit) or NO_LIMIT }
end

-- probe

-- `gh api -i notifications` output: the status line, then headers, then the body. 304 means nothing changed.
function M.parseProbe(stdout: string): Probe?
	local status = string.match(stdout, "^HTTP/%S+%s+(%d+)")
	if status ~= "200" and status ~= "304" then return nil end
	local probe: Probe = { changed = status == "200", lastModified = nil, pollSeconds = nil }
	local headers = string.match(stdout, "^(.-)\r?\n\r?\n") or stdout
	for line in string.gmatch(headers, "[^\r\n]+") do
		local name, value = string.match(line, "^([%w%-]+):%s*(.-)%s*$")
		if name then
			name = string.lower(name)
			if name == "last-modified" then probe.lastModified = value
			elseif name == "x-poll-interval" then probe.pollSeconds = tonumber(value) end
		end
	end
	return probe
end

-- The client

local function firstLine(text: string): string?
	for line in string.gmatch(text, "[^\r\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") :: string
		if trimmed ~= "" then return (string.gsub(trimmed, "^gh: ", "")) end
	end
	return nil
end

local function limited(text: string): boolean
	return string.find(string.lower(text), "rate limit", 1, true) ~= nil
end

local function failure(operation: string, what: string, reason: string, rateLimit: RateLimit?): Error
	return { operation = operation, message = "Couldn't " .. what .. ": " .. reason, rateLimit = rateLimit }
end

local function rateLimitedMessage(rateLimit: RateLimit?): string
	local resets = if rateLimit and rateLimit.resetAt ~= "" then ", resets at " .. rateLimit.resetAt else ""
	return "GitHub's rate limit is reached" .. resets
end

-- A finished command as decoded JSON, or the `Error` that explains why not. A body with `data`
-- stands even when `gh` exited 1 because of a partial GraphQL error (an added PR that is gone).
local function decoded(out: Out, decode: Decode, operation: string, what: string): (any?, Error?)
	if out.timed_out then return nil, failure(operation, what, "timed out", nil) end
	local doc: any = nil
	if out.stdout ~= "" then
		local ok, value = pcall(decode, out.stdout)
		if ok and type(value) == "table" then doc = value end
	end
	local data = doc and tbl(doc.data)
	local rateLimit = data and rateLimitOf(data.rateLimit)
	local limitedByGithub = limited(out.stderr)
	local errors = doc and list(doc.errors) or {}
	for _, problem in errors do
		if problem.type == "RATE_LIMITED" or limited(str(problem.message) or "") then limitedByGithub = true end
	end
	if limitedByGithub then return nil, failure(operation, what, rateLimitedMessage(rateLimit), rateLimit) end
	if data then return doc, nil end
	local message = errors[1] and str(errors[1].message)
	if message then return nil, failure(operation, what, message, nil) end
	if out.status ~= 0 then
		return nil, failure(operation, what, firstLine(out.stderr) or ("gh exited with status " .. out.status), nil)
	end
	return nil, failure(operation, what, "GitHub sent a response that isn't JSON data", nil)
end

local function validRef(ref: PRRef): boolean
	return string.match(ref.repo, "^[%w_.%-]+/[%w_.%-]+$") ~= nil and ref.number > 0 and ref.number % 1 == 0
end

-- hub-f, with one `pullRequest(number:)` alias per PR added by link, before the fragment.
local function hubQuery(added: { PRRef }): string
	local lines: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, ref in added do
		local key = string.lower(ref.repo) .. "#" .. ref.number
		if validRef(ref) and not seen[key] then
			seen[key] = true
			local owner, name = string.match(ref.repo, "^([^/]+)/(.+)$")
			table.insert(lines, string.format('  added%d: repository(owner: "%s", name: "%s") { pullRequest(number: %d) { ...Hub } }', #lines, owner :: string, name :: string, ref.number))
		end
	end
	if #lines == 0 then return HUB_QUERY end
	local close = string.find(HUB_QUERY, "\n}\n\nfragment", 1, true) :: number
	return string.sub(HUB_QUERY, 1, close) .. table.concat(lines, "\n") .. "\n" .. string.sub(HUB_QUERY, close + 1)
end

-- Command builders: exact argv, no network. `Client.run` executes them.
local MERGE_FLAGS: { [string]: string } = { squash = "--squash", merge = "--merge", rebase = "--rebase" }

local function prArgv(verb: string, pr: HubPR, ...: string): { string }
	local argv = { "gh", "pr", verb, tostring(pr.number), "--repo", pr.repo }
	for _, word in { ... } do table.insert(argv, word) end
	return argv
end

M.commands = {
	-- Merging asks the repo's own tool: GitHub for squash, merge and rebase, `--auto` for the queue, a comment, or a label.
	merge = function(pr: HubPR, method: MergeMethod): Command
		if method.kind == "queue" then return { argv = prArgv("merge", pr, "--auto"), stdin = nil } end
		if method.kind == "comment" then return { argv = prArgv("comment", pr, "--body", method.command), stdin = nil } end
		if method.kind == "label" then return { argv = prArgv("edit", pr, "--add-label", method.label), stdin = nil } end
		return { argv = prArgv("merge", pr, MERGE_FLAGS[method.kind]), stdin = nil }
	end,
	-- Takes back a merge asked for through a queue, a comment (when the method has a cancel) or a label. A GitHub
	-- merge happens at once and has nothing to cancel, so those raise, as does a comment method without a cancel.
	cancelMerge = function(pr: HubPR, method: MergeMethod): Command
		if method.kind == "queue" then return { argv = prArgv("merge", pr, "--disable-auto"), stdin = nil } end
		if method.kind == "comment" and method.cancel then
			return { argv = prArgv("comment", pr, "--body", method.cancel), stdin = nil }
		end
		if method.kind == "label" then return { argv = prArgv("edit", pr, "--remove-label", method.label), stdin = nil } end
		error("commands.cancelMerge: " .. method.kind .. " has nothing to cancel", 0)
	end,
	updateBranch = function(pr: HubPR): Command
		return { argv = { "gh", "pr", "update-branch", tostring(pr.number), "--repo", pr.repo }, stdin = nil }
	end,
}

-- Merge failures and merge habits

local FAILURE_WORDS = {
	"fail", "blocked", "couldn't", "could not", "can't", "cannot", "unable", "conflict", "reject", "dequeue",
	"removed from", "not mergeable", "error",
}
local LEARN_MIN = 3 -- a habit needs this many of the last 8 merges, and more than half of those read

-- The first line that says something: not blank, not an HTML comment or a heading, with leading marks
-- (">", "*", ":x:", emoji) dropped.
local function replyLine(body: string): string?
	for line in string.gmatch(body, "[^\r\n]+") do
		local text = string.match(line, "^%s*(.-)%s*$") :: string
		local skip = text == "" or string.sub(text, 1, 4) == "<!--" or string.sub(text, 1, 1) == "#"
		if not skip then
			text = string.gsub(text, "^:[%w_+%-]+:%s*", "")
			text = string.match(text, "^[^%w]*(.-)$") :: string
			if text ~= "" then
				if #text > 140 then text = string.sub(text, 1, 139) .. "…" end
				return text
			end
		end
	end
	return nil
end

local function mentionsFailure(line: string): boolean
	local lower = string.lower(line)
	for _, word in FAILURE_WORDS do
		if string.find(lower, word, 1, true) then return true end
	end
	return false
end

local function isBot(author: any): boolean
	local who = tbl(author)
	if who == nil then return false end
	local login = string.lower(str(who.login) or "")
	return who.__typename == "Bot" or string.find(login, "bot", 1, true) ~= nil or string.find(login, "aviator", 1, true) ~= nil
end

-- A check that failed after the merge was asked for: its name, the first by name.
local function failedCheck(node: any, since: string): string?
	local commit = list(tbl(node.commits) and node.commits.nodes)[1]
	local rollup = commit and tbl(tbl(commit.commit) and commit.commit.statusCheckRollup)
	local contexts = rollup and tbl(rollup.contexts)
	local found: { string } = {}
	for _, row in list(contexts and contexts.nodes) do
		local name, at, failed
		if row.__typename == "StatusContext" then
			name, at, failed = str(row.context), str(row.createdAt), FAILING_STATUSES[str(row.state) or ""]
		else
			name, at, failed = str(row.name), str(row.completedAt), FAILING_RUNS[str(row.conclusion) or ""]
		end
		if name and failed and at and at > since then table.insert(found, name) end
	end
	table.sort(found)
	return found[1]
end

-- Why a merge asked for at `pending.at` did not happen, from `merge-failure.graphql`'s node for the PR, or nil.
-- Only what came after `pending.at` counts, so asking again clears an old failure. The newest bot reply wins:
-- a reply from Aviator is `aviator`, from any other bot `bot`. Without a reply, a check that failed afterwards is
-- `comment` for a comment merge and `check` for a label merge. A queue's own failures arrive with hub-f.
function M.parseMergeFailure(raw: any, pending: PendingMerge): MergeFailure?
	local node = tbl(raw)
	if node == nil or pending.method == "queue" then return nil end
	local newest: { createdAt: string, line: string, aviator: boolean }? = nil
	for _, row in list(tbl(node.comments) and node.comments.nodes) do
		local at, body = str(row.createdAt), str(row.body)
		local line = if body then replyLine(body) else nil
		if at and at > pending.at and line and isBot(row.author) and (newest == nil or at > newest.createdAt) then
			local who = tbl(row.author)
			local login = string.lower(str(who and who.login) or "")
			newest = { createdAt = at, line = line, aviator = string.find(login, "aviator", 1, true) ~= nil or string.find(string.lower(line), "aviator", 1, true) ~= nil }
		end
	end
	if newest and mentionsFailure(newest.line) then
		return { kind = if newest.aviator then "aviator" else "bot", reason = newest.line }
	end
	local check = failedCheck(node, pending.at)
	if check == nil then return nil end
	if string.find(string.lower(check), "aviator", 1, true) then return { kind = "aviator", reason = check .. " failed" } end
	return { kind = if pending.method == "comment" then "comment" else "check", reason = check }
end

local ENUM_METHODS: { [string]: "squash" | "merge" | "rebase" } = { SQUASH = "squash", MERGE = "merge", REBASE = "rebase" }

-- "/merge" from a comment's first line, when it is a short slash command.
local function slashCommand(body: string): string?
	local line = string.match(body, "^%s*([^\r\n]*)")
	local command = line and string.match(line, "^(/[%w_%-]+[%w_%- ]*)%s*$")
	if command and #command <= 40 then return command end
	return nil
end

-- A repo's declared merge tool and the habit of its last merges. Declared: `.aviator/config.yml` (comment
-- `/aviator merge`, cancelled by `/aviator cancel`), else a merge queue. Learned: a bot merged after a person
-- commented the same slash command, in more than half of the merged PRs and at least LEARN_MIN of them.
function M.parseDetect(raw: any): Detected?
	local data = tbl(raw) and tbl(raw.data)
	local repo = data and tbl(data.repository)
	if data == nil or repo == nil then return nil end
	local declared: MergeMethod? = nil
	if tbl(repo.aviator) then
		declared = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" }
	elseif tbl(repo.mergeQueue) then
		declared = { kind = "queue" }
	end
	local merged = list(tbl(repo.pullRequests) and repo.pullRequests.nodes)
	local counts: { [string]: number } = {}
	for _, pr in merged do
		local mergedAt = str(pr.mergedAt)
		if mergedAt and isBot(pr.mergedBy) then
			local latest: string? = nil
			local command: string? = nil
			for _, row in list(tbl(pr.comments) and pr.comments.nodes) do
				local at, body = str(row.createdAt), str(row.body)
				local who = tbl(row.author)
				local slash = if body and not isBot(who) then slashCommand(body) else nil
				if at and slash and at <= mergedAt and (latest == nil or at > latest) then latest, command = at, slash end
			end
			if command then counts[command] = (counts[command] or 0) + 1 end
		end
	end
	local learned: MergeMethod? = nil
	local best, bestCount = nil, 0
	for command, count in counts do
		if count > bestCount or (count == bestCount and best ~= nil and command < best) then best, bestCount = command, count end
	end
	if best and bestCount >= LEARN_MIN and bestCount * 2 > #merged then
		learned = { kind = "comment", command = best, cancel = nil }
	end
	return {
		declared = declared, learned = learned,
		viewerDefault = ENUM_METHODS[str(repo.viewerDefaultMergeMethod) or ""] or "squash", checkedAt = "",
	}
end

function M.client(run: Runner, decode: Decode): Client
	-- Runs `argv` once and hands `done` its result, also when the runner throws.
	local function exec(argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Out) -> ())
		local settled = false
		local ok, err = pcall(run, argv, opts, function(out: Out)
			if settled then return end
			settled = true
			done(out)
		end)
		if not ok then
			if settled then error(err, 0) end
			settled = true
			done({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
		end
	end

	local function graphql(query: string, extra: { string }, operation: string, what: string, done: (doc: any?, err: Error?) -> ())
		local argv = { "gh", "api", "graphql", "-f", "query=" .. query }
		table.move(extra, 1, #extra, #argv + 1, argv)
		exec(argv, { timeout_ms = GRAPHQL_MS }, function(out)
			done(decoded(out, decode, operation, what))
		end)
	end

	local function threadsFor(prs: { HubPR }, previous: { HubPR }): { string }
		local known: { [string]: HubPR } = {}
		for _, pr in previous do known[pr.id] = pr end
		local ids: { string } = {}
		for _, pr in prs do
			local before = known[pr.id]
			if pr.reviews.unresolved > 0 then
				if before and before.lastActivityAt == pr.lastActivityAt and before.reviews.threadsKnown then
					pr.reviews.threads = before.reviews.threads
					pr.reviews.threadsKnown = true
				elseif #ids < THREAD_IDS_MAX then
					table.insert(ids, pr.id)
				end
			end
		end
		return ids
	end

	local function idArgs(ids: { string }): { string }
		local args: { string } = {}
		for _, id in ids do
			table.insert(args, "-f")
			table.insert(args, "ids[]=" .. id)
		end
		return args
	end

	local function previousOf(previous: { HubPR }, pr: HubPR): HubPR
		for _, before in previous do
			if before.id == pr.id then return before end
		end
		return pr
	end

	-- PRs with a comment or label merge in flight on the same head commit: the only ones worth a failure lookup.
	-- A queue merge reports its own removal in hub-f, and a new head drops the merge.
	local function inFlightMerges(prs: { HubPR }, previous: { HubPR }): { HubPR }
		local out: { HubPR } = {}
		for _, pr in prs do
			local before = previousOf(previous, pr)
			local pending = before.pending
			if pending and pending.method ~= "queue" and before.headOid == pr.headOid then table.insert(out, pr) end
		end
		return out
	end

	local function refresh(req: RefreshRequest, done: (value: Refresh?, err: Error?) -> ())
		graphql(hubQuery(req.added), {}, "gh api graphql: hub", "refresh pull requests", function(doc, err)
			if err then return done(nil, err) end
			local hub = M.parseHub(doc)
			if hub == nil then
				return done(nil, failure("gh api graphql: hub", "refresh pull requests", "GitHub sent a response without the viewer", nil))
			end
			local result: Refresh = {
				prs = hub.prs, viewer = hub.viewer, rateLimit = hub.rateLimit, calls = { hub.rateLimit },
				truncated = hub.truncated, partial = nil,
			}
			local function finish()
				local inFlight = inFlightMerges(hub.prs, req.previous)
				if #inFlight == 0 then return done(result, nil) end
				local ids: { string } = {}
				for _, pr in inFlight do table.insert(ids, pr.id) end
				graphql(MERGE_FAILURE_QUERY, idArgs(ids), "gh api graphql: merge failures", "check merges in flight", function(failDoc, failErr)
					if failErr then
						result.partial = result.partial or failErr
						if failErr.rateLimit then
							table.insert(result.calls, failErr.rateLimit)
							result.rateLimit = failErr.rateLimit
						end
						return done(result, nil)
					end
					local data = tbl(failDoc) and tbl(failDoc.data)
					local byId: { [string]: any } = {}
					for _, node in list(data and data.nodes) do
						local id = str(node.id)
						if id then byId[id] = node end
					end
					for _, pr in inFlight do
						local node, pending = byId[pr.id], previousOf(req.previous, pr).pending
						if node and pending and str(node.headRefOid) == pr.headOid then
							pr.mergeFailure = pr.mergeFailure or M.parseMergeFailure(node, pending)
						end
					end
					local used = rateLimitOf(data and data.rateLimit) or NO_LIMIT
					table.insert(result.calls, used)
					result.rateLimit = used
					done(result, nil)
				end)
			end
			local ids = threadsFor(hub.prs, req.previous)
			if #ids == 0 then return finish() end
			local args = idArgs(ids)
			graphql(THREADS_QUERY, args, "gh api graphql: threads", "read review threads", function(threadsDoc, threadsErr)
				if threadsErr then
					result.partial = threadsErr
					if threadsErr.rateLimit then
						table.insert(result.calls, threadsErr.rateLimit)
						result.rateLimit = threadsErr.rateLimit
					end
					return finish()
				end
				local threads = M.parseThreads(threadsDoc)
				if threads == nil then
					result.partial = failure("gh api graphql: threads", "read review threads", "GitHub sent a response without nodes", nil)
					return finish()
				end
				for _, pr in result.prs do
					local open = threads.threads[pr.id]
					if open then
						pr.reviews.threads = open
						pr.reviews.threadsKnown = true
					end
				end
				table.insert(result.calls, threads.rateLimit)
				result.rateLimit = threads.rateLimit
				finish()
			end)
		end)
	end

	local function probe(since: string?, done: (value: Probe?, err: Error?) -> ())
		local argv = { "gh", "api", "-i", "notifications?per_page=1" }
		if since and since ~= "" then
			table.insert(argv, "-H")
			table.insert(argv, "If-Modified-Since: " .. since)
		end
		exec(argv, { timeout_ms = REST_MS }, function(out)
			local operation, what = "gh api: notifications", "check for changes"
			-- `gh` can exit non-zero on a 304; the status line decides.
			local result = if out.timed_out then nil else M.parseProbe(out.stdout)
			if result then return done(result, nil) end
			if out.timed_out then return done(nil, failure(operation, what, "timed out", nil)) end
			local reason = firstLine(out.stderr) or firstLine(out.stdout) or "no response"
			if limited(out.stderr) or limited(out.stdout) then reason = rateLimitedMessage(nil) end
			done(nil, failure(operation, what, reason, nil))
		end)
	end

	local function checks(ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ())
		if #ids == 0 then return done({ byId = {}, rateLimit = NO_LIMIT }, nil) end
		local args: { string } = {}
		for _, id in ids do
			table.insert(args, "-f")
			table.insert(args, "ids[]=" .. id)
		end
		graphql(CHECKS_QUERY, args, "gh api graphql: checks", "read checks", function(doc, err)
			if err then return done(nil, err) end
			local update = M.parseChecks(doc)
			if update == nil then
				return done(nil, failure("gh api graphql: checks", "read checks", "GitHub sent a response without nodes", nil))
			end
			done(update, nil)
		end)
	end

	local function detect(repo: string, done: (value: Detected?, err: Error?) -> ())
		local owner, name = string.match(repo, "^([%w_.%-]+)/([%w_.%-]+)$")
		if owner == nil or name == nil then
			return done(nil, failure("gh api graphql: merge-detect", "detect how " .. repo .. " merges", "not an owner/repo name", nil))
		end
		graphql(MERGE_DETECT_QUERY, { "-f", "owner=" .. owner, "-f", "name=" .. name }, "gh api graphql: merge-detect", "detect how " .. repo .. " merges", function(doc, err)
			if err then return done(nil, err) end
			local detected = M.parseDetect(doc)
			if detected == nil then
				return done(nil, failure("gh api graphql: merge-detect", "detect how " .. repo .. " merges", "GitHub has no repository " .. repo, nil))
			end
			done(detected, nil)
		end)
	end

	local function runCommand(command: Command, done: (stdout: string?, err: Error?) -> ())
		local argv = command.argv
		local operation = table.concat(argv, " ", 1, math.min(#argv, 3))
		exec(argv, { stdin = command.stdin, timeout_ms = RUN_MS }, function(out)
			if out.status == 0 and not out.timed_out then return done(out.stdout, nil) end
			local what = "run " .. operation
			if out.timed_out then return done(nil, failure(operation, what, "timed out", nil)) end
			local text = out.stderr .. "\n" .. out.stdout
			local reason = if limited(text) then rateLimitedMessage(nil) else (firstLine(out.stderr) or firstLine(out.stdout) or ("exit status " .. out.status))
			done(nil, failure(operation, what, reason, nil))
		end)
	end

	return { refresh = refresh, probe = probe, checks = checks, detect = detect, run = runCommand }
end

return M
