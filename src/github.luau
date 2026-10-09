--!strict
-- The PR hub's GitHub boundary. Every GitHub call goes through the injected `Runner` (the real one
-- is `Fetch.runner`, tests pass a fake), JSON text is decoded by the injected `decode`
-- (`tern.json.decode`), and nothing here reads `tern`, the clock or a file. The parsers take
-- already decoded tables and never throw on a missing field. Each call returns its own rate-limit
-- envelope; the caller sums them. Failures are `Error` values, never thrown.
--
-- Not built yet (each lands with the issue that first needs it): `details`, `history`, `detect`,
-- `parseDetails` and the `commands` builders.
local Model = require("./hub/model")

type HubPR = Model.HubPR
type Checks = Model.Checks
type Error = Model.Error
type RateLimit = Model.RateLimit
type Refresh = Model.Refresh
type PRRef = Model.PRRef
type OpenThread = Model.OpenThread

-- What `tern.process.run` gives and takes, minus the `cx`. src/fetch.luau exports the real runner.
export type Out = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Runner = (argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Out) -> ()) -> ()
export type Decode = (text: string) -> any

export type RefreshRequest = { added: { PRRef }, previous: { HubPR } }
export type Probe = { changed: boolean, lastModified: string?, pollSeconds: number? }
export type ChecksUpdate = { byId: { [string]: { headOid: string, checks: Checks } }, rateLimit: RateLimit }
export type Command = { argv: { string }, stdin: string? }

export type Client = {
	refresh: (req: RefreshRequest, done: (value: Refresh?, err: Error?) -> ()) -> (),
	probe: (since: string?, done: (value: Probe?, err: Error?) -> ()) -> (),
	checks: (ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ()) -> (),
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
			local ids = threadsFor(hub.prs, req.previous)
			if #ids == 0 then return done(result, nil) end
			local args: { string } = {}
			for _, id in ids do
				table.insert(args, "-f")
				table.insert(args, "ids[]=" .. id)
			end
			graphql(THREADS_QUERY, args, "gh api graphql: threads", "read review threads", function(threadsDoc, threadsErr)
				if threadsErr then
					result.partial = threadsErr
					if threadsErr.rateLimit then
						table.insert(result.calls, threadsErr.rateLimit)
						result.rateLimit = threadsErr.rateLimit
					end
					return done(result, nil)
				end
				local threads = M.parseThreads(threadsDoc)
				if threads == nil then
					result.partial = failure("gh api graphql: threads", "read review threads", "GitHub sent a response without nodes", nil)
					return done(result, nil)
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
				done(result, nil)
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

	return { refresh = refresh, probe = probe, checks = checks, run = runCommand }
end

return M
