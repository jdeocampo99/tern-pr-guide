--!strict
-- The hub's rules: which column a PR is in, in what order, and what needs the viewer next.
-- Pure: no clock, no network, no views. Callers pass `now` in seconds since the epoch.

export type Tab = "mine" | "review"
export type Column = "needs_fixes" | "in_review" | "ready" | "inactive" | "to_review" | "waiting_on_author" | "approved"
export type Reason = "merge_failed" | "feedback" | "checks" | "conflict" -- in this order: severity, and the chip order
export type Sort = "repository" | "priority" | "newest" | "oldest" | "smallest"

export type CheckState = "none" | "pending" | "passing" | "failing"
export type Checks = { state: CheckState, passing: number, failing: number, pending: number }

export type Verdict = "approved" | "changes_requested" | "commented" | "dismissed"
-- A reviewer's latest review (hub-f's `latestReviews`).
export type Review = { author: string, bot: boolean, verdict: Verdict, at: string, oid: string }
-- An unresolved thread, by its first comment's author (threads.graphql).
export type OpenThread = { author: string, bot: boolean }
export type ReviewState = {
	decision: "approved" | "changes_requested" | "review_required" | "none",
	latest: { Review }, -- one per reviewer
	mine: Review?, -- the viewer's own latest review
	requestedMe: boolean, -- a review is requested of the viewer
	requested: { string }, -- logins and team slugs
	unresolved: number, -- unresolved threads, counted in hub-f
	threads: { OpenThread }, -- authors of the unresolved ones, once threads.graphql ran
	threadsKnown: boolean, -- false until then: unknown threads never count as feedback
	comments: number,
}

export type MergeFailure = { kind: "queue" | "aviator" | "comment" | "check" | "bot", reason: string }
-- A merge asked for and not finished: the repo's queue, a posted command, or a label.
export type PendingMerge = { method: "queue" | "comment" | "label", at: string }

export type HubPR = {
	key: string, -- "owner/repo#123", the repo as GitHub spells it; unique on the board
	id: string, -- GraphQL node id, for `nodes(ids:)`
	repo: string,
	number: number,
	url: string,
	title: string,
	author: string,
	authorBot: boolean,
	role: Tab, -- "mine": the viewer wrote it. "review": it is waiting on, or was added for, the viewer
	draft: boolean,
	createdAt: string,
	lastActivityAt: string, -- GitHub's createdAt and updatedAt
	headOid: string,
	baseBranch: string,
	additions: number,
	deletions: number,
	files: number,
	checks: Checks,
	conflicts: boolean, -- mergeable == CONFLICTING
	behind: boolean, -- mergeStateStatus == BEHIND
	reviews: ReviewState,
	mergeFailure: MergeFailure?,
	pending: PendingMerge?,
	tandem: boolean, -- Tandem watches the branch; filled by the block, never by GitHub
	addedByMe: boolean, -- on the board through a pasted link; filled from `hub.added`
}

export type Placement = { tab: Tab, column: Column, reasons: { Reason } } -- reasons is empty outside needs_fixes

export type RateLimit = { cost: number, remaining: number, limit: number, resetAt: string }
export type Error = { operation: string, message: string, rateLimit: RateLimit? } -- operation is like "gh api graphql: hub"
export type PRRef = { repo: string, number: number }
-- What one GitHub refresh returns, normalized. Defined here so `sync` and `state` can use it without requiring `github`.
export type Refresh = {
	prs: { HubPR }, -- `tandem` and `addedByMe` false, `pending` nil: the block fills them from local facts
	viewer: string,
	rateLimit: RateLimit, -- the last call's envelope
	calls: { RateLimit }, -- every call's envelope, in order: hub-f, then threads
	truncated: boolean, -- a search returned more than 50
	partial: Error?, -- threads failed: `prs` still stands, with threadsKnown = false
}

export type Filter = { repositories: { [string]: boolean }?, search: string } -- nil repositories = all

-- Next up
export type NextItem = { key: string, tab: Tab, column: Column, reason: Reason? }
export type NextUp = { item: NextItem, index: number, total: number }

-- Flakes. Evidence is fetched by github.luau; the verdict is a rule.
export type FlakeEvidence = {
	history: { failed: number, total: number }?, -- the same check on recent runs of the base branch
	passedBefore: boolean, -- it passed on this commit earlier, or on the previous one without a change to the failing area
	text: string, -- the failure text
	annotationPaths: { string },
	changedPaths: { string },
}
export type FlakeVerdict = { flaky: boolean, basis: ("history" | "rerun" | "text" | "outside_diff")?, reason: string? }

-- Merging
export type MergeMethod =
	{ kind: "squash" } | { kind: "merge" } | { kind: "rebase" }
	| { kind: "queue" } -- gh pr merge --auto
	| { kind: "comment", command: string, cancel: string? } -- gh pr comment
	| { kind: "label", label: string } -- gh pr edit --add-label
export type MergeSource = "user" | "declared" | "learned" | "viewer"
export type MergeEvidence = {
	user: MergeMethod?,
	declared: MergeMethod?, -- .aviator/config.yml, or repository.mergeQueue
	learned: MergeMethod?, -- from the last 8 merged PRs
	learnedAnswered: boolean, -- the viewer was asked about `learned` and said no (a yes becomes `user`)
	viewerDefault: "squash" | "merge" | "rebase",
}
export type MergeResolution = { method: MergeMethod, source: MergeSource, ask: boolean } -- ask: a learned method nobody confirmed yet

local M = {}

-- A PR with no activity for longer than this is Inactive, whatever else is wrong with it.
M.ACTIVE_DAYS = 7
local ACTIVE_SECONDS = M.ACTIVE_DAYS * 86400

-- Seconds since the epoch of an ISO time like "2026-10-08T09:12:33Z".
function M.epoch(iso: string): number?
	local y, mo, d, h, mi, s = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return nil end
	local month, day = tonumber(mo) :: number, tonumber(d) :: number
	-- Days from 1970-01-01 to the date, counting years from March so leap days fall last.
	local year = (tonumber(y) :: number) - (if month <= 2 then 1 else 0)
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * ((month + 9) % 12) + 2) // 5 + day - 1
	local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
	return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)
end

local AGO_UNITS = {
	{ seconds = 86400 * 365, suffix = "y" }, { seconds = 86400 * 30, suffix = "mo" }, { seconds = 86400 * 7, suffix = "w" },
	{ seconds = 86400, suffix = "d" }, { seconds = 3600, suffix = "h" }, { seconds = 60, suffix = "m" },
}

-- How long before `now` (seconds since the epoch) the ISO time `iso` was, as "2h ago".
function M.ago(iso: string, now: number): string
	local at = M.epoch(iso)
	if not at then return "" end
	local elapsed = now - at
	for _, unit in AGO_UNITS do
		if elapsed >= unit.seconds then return (elapsed // unit.seconds) .. unit.suffix .. " ago" end
	end
	return "just now"
end

local function seconds(iso: string): number
	return M.epoch(iso) or 0
end

local function active(pr: HubPR, now: number): boolean
	local at = M.epoch(pr.lastActivityAt)
	return at ~= nil and now - at <= ACTIVE_SECONDS
end

-- Whether a thread by `author` is feedback from a person to act on: not a bot, not the PR's author (the viewer
-- wrote their PRs, so their own comments never count), and not someone whose latest review approved.
function M.threadCounts(pr: HubPR, author: string, bot: boolean): boolean
	if bot or author == pr.author then return false end
	for _, review in pr.reviews.latest do
		if review.author == author and review.verdict == "approved" then return false end
	end
	return true
end

local function personFeedback(pr: HubPR): boolean
	local reviews = pr.reviews
	for _, review in reviews.latest do
		if not review.bot and review.author ~= pr.author and review.verdict == "changes_requested" then return true end
	end
	if not reviews.threadsKnown then return false end
	for _, thread in reviews.threads do
		if M.threadCounts(pr, thread.author, thread.bot) then return true end
	end
	return false
end

function M.reasons(pr: HubPR, now: number): { Reason }
	local out: { Reason } = {}
	if pr.role ~= "mine" or pr.draft or not active(pr, now) then return out end
	if pr.mergeFailure then out[#out + 1] = "merge_failed" end
	if personFeedback(pr) then out[#out + 1] = "feedback" end
	if pr.checks.state == "failing" then out[#out + 1] = "checks" end
	if pr.conflicts then out[#out + 1] = "conflict" end
	return out
end

-- True when the viewer approved an older commit than the head.
local function reReview(pr: HubPR): boolean
	local mine = pr.reviews.mine
	return mine ~= nil and mine.verdict == "approved" and mine.oid ~= pr.headOid
end

function M.placement(pr: HubPR, now: number): Placement
	if pr.role == "review" then
		local reviews = pr.reviews
		local mine = reviews.mine
		local column: Column = "to_review"
		if reviews.requestedMe or reReview(pr) then
			column = "to_review"
		elseif mine and mine.verdict == "approved" then
			column = "approved"
		elseif mine and (mine.verdict == "changes_requested" or mine.verdict == "commented") then
			column = "waiting_on_author"
		end
		return { tab = "review", column = column, reasons = {} }
	end
	if pr.draft or not active(pr, now) then return { tab = "mine", column = "inactive", reasons = {} } end
	local reasons = M.reasons(pr, now)
	if #reasons > 0 then return { tab = "mine", column = "needs_fixes", reasons = reasons } end
	local passing = pr.checks.state == "passing" or pr.checks.state == "none"
	if pr.reviews.decision == "approved" and passing and not pr.conflicts then
		return { tab = "mine", column = "ready", reasons = reasons }
	end
	return { tab = "mine", column = "in_review", reasons = reasons }
end

function M.classify(pr: HubPR, now: number): Column
	return M.placement(pr, now).column
end

-- A bot's latest review or unresolved thread, for Fix bot comments.
function M.botFeedback(pr: HubPR): boolean
	for _, review in pr.reviews.latest do
		if review.bot and review.verdict ~= "approved" and review.verdict ~= "dismissed" then return true end
	end
	if pr.reviews.threadsKnown then
		for _, thread in pr.reviews.threads do
			if thread.bot then return true end
		end
	end
	return false
end

-- Ready, not behind, nothing pending: the cards Space may select.
function M.mergeable(pr: HubPR): boolean
	return pr.role == "mine" and not pr.draft and pr.reviews.decision == "approved"
		and (pr.checks.state == "passing" or pr.checks.state == "none")
		and not pr.conflicts and not pr.behind and pr.pending == nil and pr.mergeFailure == nil
end

function M.size(pr: HubPR): number
	return pr.additions + pr.deletions
end

-- Search matches "#n", title, author, repo and base branch, ignoring case.
function M.visible(pr: HubPR, filter: Filter): boolean
	if filter.repositories and not filter.repositories[pr.repo] then return false end
	local query = string.lower((string.gsub(filter.search, "^%s+", "")))
	query = (string.gsub(query, "%s+$", ""))
	if query == "" then return true end
	for _, field in { "#" .. pr.number, pr.title, pr.author, pr.repo, pr.baseBranch } do
		if string.find(string.lower(field), query, 1, true) then return true end
	end
	return false
end

local function has(reasons: { Reason }, reason: Reason): boolean
	for _, r in reasons do
		if r == reason then return true end
	end
	return false
end

-- How urgent a your-turn card is, 0 first: a merge failure, then a person waiting on the viewer, then a machine.
local function urgency(pr: HubPR, placement: Placement): number
	if placement.column == "needs_fixes" then
		if has(placement.reasons, "merge_failed") then return 0 end
		if has(placement.reasons, "feedback") then return 1 end
		return 2
	end
	if pr.reviews.requestedMe or reReview(pr) then return 1 end
	return 2
end

local function yourTurn(column: Column): boolean
	return column == "needs_fixes" or column == "to_review"
end

type Entry = { pr: HubPR, placement: Placement, urgency: number, active: number, created: number }

local function entry(pr: HubPR, now: number): Entry
	local placement = M.placement(pr, now)
	return {
		pr = pr, placement = placement, urgency = urgency(pr, placement),
		active = seconds(pr.lastActivityAt), created = seconds(pr.createdAt),
	}
end

-- Less-than for the column's own order: your-turn by urgency then longest waiting, ready oldest first, the rest newest first.
local function priority(column: Column): (Entry, Entry) -> boolean
	if yourTurn(column) then
		return function(a: Entry, b: Entry): boolean
			if a.urgency ~= b.urgency then return a.urgency < b.urgency end
			if a.active ~= b.active then return a.active < b.active end
			return a.pr.key < b.pr.key
		end
	end
	local oldestFirst = column == "ready"
	return function(a: Entry, b: Entry): boolean
		if a.created ~= b.created then
			if oldestFirst then return a.created < b.created end
			return a.created > b.created
		end
		return a.pr.key < b.pr.key
	end
end

-- The PRs in `column`, in `sort` order. Ties fall back to the key, so the result is deterministic.
function M.order(prs: { HubPR }, column: Column, sort: Sort, now: number): { HubPR }
	local entries: { Entry } = {}
	for _, pr in prs do
		local e = entry(pr, now)
		if e.placement.column == column then table.insert(entries, e) end
	end
	local byPriority = priority(column)
	local less: (Entry, Entry) -> boolean = byPriority
	if sort == "repository" then
		less = function(a: Entry, b: Entry): boolean
			local ra, rb = string.lower(a.pr.repo), string.lower(b.pr.repo)
			if ra ~= rb then return ra < rb end
			return byPriority(a, b)
		end
	elseif sort == "newest" or sort == "oldest" then
		local newest = sort == "newest"
		less = function(a: Entry, b: Entry): boolean
			if a.created ~= b.created then
				if newest then return a.created > b.created end
				return a.created < b.created
			end
			return a.pr.key < b.pr.key
		end
	elseif sort == "smallest" then
		less = function(a: Entry, b: Entry): boolean
			local sa, sb = M.size(a.pr), M.size(b.pr)
			if sa ~= sb then return sa < sb end
			return a.pr.key < b.pr.key
		end
	end
	table.sort(entries, less)
	local out: { HubPR } = {}
	for _, e in entries do table.insert(out, e.pr) end
	return out
end

-- Everything that needs the viewer, across both tabs, most urgent first.
function M.queue(prs: { HubPR }, now: number): { NextItem }
	local entries: { Entry } = {}
	for _, pr in prs do
		local e = entry(pr, now)
		if yourTurn(e.placement.column) then table.insert(entries, e) end
	end
	table.sort(entries, function(a: Entry, b: Entry): boolean
		if a.urgency ~= b.urgency then return a.urgency < b.urgency end
		if a.active ~= b.active then return a.active < b.active end
		return a.pr.key < b.pr.key
	end)
	local out: { NextItem } = {}
	for _, e in entries do
		table.insert(out, {
			key = e.pr.key, tab = e.placement.tab, column = e.placement.column, reason = e.placement.reasons[1],
		})
	end
	return out
end

-- The item after `after` in the queue; the first when `after` is nil or no longer queued; wraps; nil when
-- nothing needs the viewer. `index` is its place in the queue and `total` the queue's length.
function M.nextUp(prs: { HubPR }, now: number, after: string?): NextUp?
	local list = M.queue(prs, now)
	if #list == 0 then return nil end
	local index = 1
	if after then
		for i, item in list do
			if item.key == after then index = i % #list + 1 end
		end
	end
	return { item = list[index], index = index, total = #list }
end

-- How a repo merges: the viewer's choice, then what the repo declares, then a habit learned from its last
-- merges (asked about once), then the viewer's GitHub default.
function M.resolveMergeMethod(evidence: MergeEvidence): MergeResolution
	if evidence.user then return { method = evidence.user, source = "user", ask = false } end
	if evidence.declared then return { method = evidence.declared, source = "declared", ask = false } end
	if evidence.learned and not evidence.learnedAnswered then
		return { method = evidence.learned, source = "learned", ask = true }
	end
	return { method = { kind = evidence.viewerDefault } :: MergeMethod, source = "viewer", ask = false }
end

-- Selecting several -------------------------------------------------------------------------------------

export type Group = "ready" | "inactive"
export type ConfirmList = { shown: { HubPR }, more: number }

-- A confirm lists at most this many titles.
M.CONFIRM_TITLES = 5

-- Which group a card may be selected in, or why it may not. Ready cards qualify only when they can merge
-- now: not behind main, nothing queued or in flight. Inactive rows (drafts too) always qualify.
function M.selectGroup(pr: HubPR, now: number): (Group?, string?)
	local column = M.classify(pr, now)
	if column == "inactive" then return "inactive", nil end
	if column ~= "ready" then return nil, "only Ready and Inactive pull requests can be selected" end
	if pr.behind then return nil, "it is behind " .. pr.baseBranch end
	if pr.pending then return nil, "a merge is already waiting" end
	if not M.mergeable(pr) then return nil, "it can't merge yet" end
	return "ready", nil
end

-- Stale: Inactive for lack of activity and not a draft. Close stale selects exactly these.
function M.stale(pr: HubPR, now: number): boolean
	return pr.role == "mine" and not pr.draft and not active(pr, now)
end

-- The titles a confirm shows (the first CONFIRM_TITLES) and how many more there are.
function M.confirmList(prs: { HubPR }): ConfirmList
	local shown: { HubPR } = {}
	for i = 1, math.min(#prs, M.CONFIRM_TITLES) do shown[i] = prs[i] end
	return { shown = shown, more = #prs - #shown }
end

local GITHUB_LINES: { [string]: string } = {
	squash = "Squash and merge", merge = "Create a merge commit", rebase = "Rebase and merge",
}

-- How one method merges, as a confirm says it.
function M.methodLine(method: MergeMethod): string
	if method.kind == "comment" then return "Comments " .. method.command end
	if method.kind == "label" then return "Adds the " .. method.label .. " label" end
	if method.kind == "queue" then return "Adds to the merge queue" end
	return GITHUB_LINES[method.kind]
end

-- One line per distinct method, in order of first use ("Squash and merge", or several lines when they differ).
function M.methodLines(methods: { MergeMethod }): { string }
	local out: { string } = {}
	for _, method in methods do
		local line = M.methodLine(method)
		if not table.find(out, line) then table.insert(out, line) end
	end
	return out
end

-- flake (#13) arrives with its issue; its types are declared above.

return M
