--!strict
-- The PR hub's pure sync decisions: the cache's shape (validate, cap, merge a refresh into it), the
-- per-repo merge-method record, the recent store, what changed between two refreshes, and when each
-- poll is due. It reads no clock and no `tern.*`: callers pass `now`, and sizes are injected.
local Model = require("./model")

type HubPR = Model.HubPR
type Refresh = Model.Refresh
type RateLimit = Model.RateLimit
type PRRef = Model.PRRef
type MergeMethod = Model.MergeMethod
type MergeEvidence = Model.MergeEvidence
type Reason = Model.Reason

-- `schema` is a number because Luau has no literal types; `load` accepts only 1.
export type Counts = { toReview: number, needFixes: number, flashAt: number? } -- what the status segment reads; flashAt is a time
export type Cache = {
	schema: number,
	refreshedAt: string, viewer: string,
	prs: { HubPR },
	rateLimit: RateLimit?,
	lastModified: string?, -- the probe's validator
	counts: Counts,
}
export type Added = { [string]: PRRef } -- hub.added, by key
export type Local = { added: Added, tandem: { [string]: boolean } }
export type MergeRecord = {
	schema: number, user: MergeMethod?, declared: MergeMethod?, learned: MergeMethod?,
	learnedAnswered: boolean, checkedAt: string?,
}
export type Opened = { repo: string, number: number, title: string, author: string, at: string } -- hub.recent, newest first, at most RECENT_CAP

local M = {}

M.RECENT_CAP = 8
M.PROBE_EVERY, M.REFRESH_EVERY, M.DEBOUNCE, M.CHECKS_EVERY = 60, 300, 30, 30 -- seconds

-- Validation ---------------------------------------------------------------------------------------

local function isString(v: any): boolean return type(v) == "string" end
local function isNumber(v: any): boolean return type(v) == "number" end
local function isBool(v: any): boolean return type(v) == "boolean" end
local function isTable(v: any): boolean return type(v) == "table" end

local PR_FIELDS: { [string]: (any) -> boolean } = {
	key = isString, id = isString, repo = isString, number = isNumber, url = isString, title = isString,
	author = isString, authorBot = isBool, draft = isBool, createdAt = isString, lastActivityAt = isString,
	headOid = isString, baseBranch = isString, additions = isNumber, deletions = isNumber, files = isNumber,
	checks = isTable, conflicts = isBool, behind = isBool, reviews = isTable, tandem = isBool, addedByMe = isBool,
}
local REVIEW_FIELDS: { [string]: (any) -> boolean } = {
	decision = isString, latest = isTable, requestedMe = isBool, requested = isTable, unresolved = isNumber,
	threads = isTable, threadsKnown = isBool, comments = isNumber,
}
local CHECK_FIELDS: { [string]: (any) -> boolean } = { state = isString, passing = isNumber, failing = isNumber, pending = isNumber }

local function fieldsOk(value: any, fields: { [string]: (any) -> boolean }): boolean
	if type(value) ~= "table" then return false end
	for name, valid in fields do
		if not valid(value[name]) then return false end
	end
	return true
end

-- A PR the rules can place without raising.
local function validPr(pr: any): boolean
	if not fieldsOk(pr, PR_FIELDS) or not fieldsOk(pr.checks, CHECK_FIELDS) or not fieldsOk(pr.reviews, REVIEW_FIELDS) then return false end
	return pr.role == "mine" or pr.role == "review"
end

local function isArray(value: any): boolean
	if type(value) ~= "table" then return false end
	local n = 0
	for _ in value do n += 1 end
	return n == #value
end

-- The kv value as a Cache, or nil for anything malformed or not schema 1. Never throws.
function M.load(raw: any): Cache?
	if type(raw) ~= "table" or raw.schema ~= 1 then return nil end
	if not isString(raw.refreshedAt) or not isString(raw.viewer) or not isArray(raw.prs) then return nil end
	local counts = raw.counts
	if type(counts) ~= "table" or not isNumber(counts.toReview) or not isNumber(counts.needFixes) then return nil end
	if counts.flashAt ~= nil and not isNumber(counts.flashAt) then return nil end
	if raw.lastModified ~= nil and not isString(raw.lastModified) then return nil end
	if raw.rateLimit ~= nil and not isTable(raw.rateLimit) then return nil end
	for _, pr in raw.prs do
		if not validPr(pr) then return nil end
	end
	return raw :: any
end

-- The value for kv: `cache` with the oldest `lastActivityAt` dropped first until `size(value) <= capBytes`.
function M.save(cache: Cache, capBytes: number, size: (value: any) -> number): any
	local value = table.clone(cache)
	local prs = table.clone(cache.prs)
	value.prs = prs
	while #prs > 0 and size(value) > capBytes do
		local oldest = 1
		for i = 2, #prs do
			if prs[i].lastActivityAt < prs[oldest].lastActivityAt then oldest = i end
		end
		table.remove(prs, oldest)
	end
	return value
end

-- Merge ---------------------------------------------------------------------------------------------

-- ISO time for seconds since the epoch, computed by hand so no clock or locale is involved.
local function iso(seconds: number): string
	local days = seconds // 86400
	local rest = seconds - days * 86400
	local z = days + 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local day = doy - (153 * mp + 2) // 5 + 1
	local month = if mp < 10 then mp + 3 else mp - 9
	local year = yoe + era * 400 + (if month <= 2 then 1 else 0)
	return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, rest // 3600, (rest % 3600) // 60, rest % 60)
end

local function countsOf(prs: { HubPR }, now: number): (number, number)
	local toReview, needFixes = 0, 0
	for _, pr in prs do
		local column = Model.classify(pr, now)
		if column == "to_review" then toReview += 1 end
		if column == "needs_fixes" then needFixes += 1 end
	end
	return toReview, needFixes
end

-- A fresh refresh as the next Cache: local facts filled in, `pending` kept while the head is unchanged, counts rebuilt.
-- `counts.flashAt` is `now` when the Needs fixes count rose, and otherwise what it was.
function M.merge(fresh: Refresh, previous: Cache?, localFacts: Local, now: number): Cache
	local before: { [string]: HubPR } = {}
	if previous then
		for _, pr in previous.prs do before[pr.key] = pr end
	end
	local prs: { HubPR } = {}
	for _, source in fresh.prs do
		local pr = table.clone(source)
		pr.tandem = localFacts.tandem[pr.key] == true
		pr.addedByMe = localFacts.added[pr.key] ~= nil
		local old = before[pr.key]
		if pr.pending == nil and old and old.pending and old.headOid == pr.headOid then pr.pending = old.pending end
		table.insert(prs, pr)
	end
	local toReview, needFixes = countsOf(prs, now)
	local flashAt = if previous then previous.counts.flashAt else nil
	if previous and needFixes > previous.counts.needFixes then flashAt = now end
	return {
		schema = 1, refreshedAt = iso(now), viewer = fresh.viewer, prs = prs,
		rateLimit = fresh.rateLimit, lastModified = if previous then previous.lastModified else nil,
		counts = { toReview = toReview, needFixes = needFixes, flashAt = flashAt },
	}
end

-- Merge-method record ----------------------------------------------------------------------------------

local function validMethod(raw: any): MergeMethod?
	if type(raw) ~= "table" then return nil end
	local kind = raw.kind
	if kind == "squash" or kind == "merge" or kind == "rebase" or kind == "queue" then
		return { kind = kind } :: any
	elseif kind == "comment" and isString(raw.command) then
		return { kind = "comment", command = raw.command, cancel = if isString(raw.cancel) then raw.cancel else nil }
	elseif kind == "label" and isString(raw.label) then
		return { kind = "label", label = raw.label }
	end
	return nil
end

function M.loadMerge(raw: any): MergeRecord?
	if type(raw) ~= "table" or raw.schema ~= 1 then return nil end
	return {
		schema = 1, user = validMethod(raw.user), declared = validMethod(raw.declared), learned = validMethod(raw.learned),
		learnedAnswered = raw.learnedAnswered == true, checkedAt = if isString(raw.checkedAt) then raw.checkedAt else nil,
	}
end

function M.mergeEvidence(record: MergeRecord?, viewerDefault: "squash" | "merge" | "rebase"): MergeEvidence
	if not record then return { user = nil, declared = nil, learned = nil, learnedAnswered = false, viewerDefault = viewerDefault } end
	return {
		user = record.user, declared = record.declared, learned = record.learned,
		learnedAnswered = record.learnedAnswered, viewerDefault = viewerDefault,
	}
end

-- Recent store ---------------------------------------------------------------------------------------------

-- The opened PRs kept in `saved` (whatever was stored), skipping anything malformed.
function M.openedList(saved: any): { Opened }
	local list: { Opened } = {}
	if type(saved) ~= "table" then return list end
	for _, item in saved do
		if type(item) == "table" and isString(item.repo) and isNumber(item.number) then
			table.insert(list, {
				repo = item.repo, number = item.number,
				title = if isString(item.title) then item.title else "",
				author = if isString(item.author) then item.author else "",
				at = if isString(item.at) then item.at else "",
			})
		end
	end
	return list
end

-- `list` with `opened` moved to the front, each PR once, at most RECENT_CAP long.
function M.remember(list: { Opened }, opened: Opened): { Opened }
	local out = { opened }
	for _, item in list do
		if #out >= M.RECENT_CAP then break end
		if not (string.lower(item.repo) == string.lower(opened.repo) and item.number == opened.number) then table.insert(out, item) end
	end
	return out
end

-- What changed -----------------------------------------------------------------------------------------------

export type Arrival = { key: string, reasons: { Reason }, toast: boolean } -- toast: any reason but a conflict
export type Changes = {
	firstLoad: boolean, -- no previous cache: no ring, no toast
	arrivals: { Arrival }, -- entered needs_fixes from outside it, and not suppressed
	good: { string }, -- entered ready or approved: the green wash
	toast: { text: string, sub: string? }?, -- one per refresh
}

local REASON_TEXT: { [Reason]: string } = {
	merge_failed = "merge failed", feedback = "new feedback", checks = "failing check", conflict = "conflict",
}

-- What `fresh` changed against `old`. A PR missing from `old` (new, or evicted by the cap) never arrives, since
-- nothing says where it came from. `suppressed` holds the keys the viewer just acted on.
function M.diff(old: Cache?, fresh: { HubPR }, now: number, suppressed: { [string]: boolean }): Changes
	local changes: Changes = { firstLoad = old == nil, arrivals = {}, good = {}, toast = nil }
	if not old then return changes end
	local before: { [string]: HubPR } = {}
	for _, pr in old.prs do before[pr.key] = pr end
	local loud: { HubPR } = {}
	for _, pr in fresh do
		local was = before[pr.key]
		if was then
			local placement = Model.placement(pr, now)
			local from = Model.classify(was, now)
			if placement.column == "needs_fixes" and from ~= "needs_fixes" and not suppressed[pr.key] then
				local toast = false
				for _, reason in placement.reasons do
					if reason ~= "conflict" then toast = true end
				end
				table.insert(changes.arrivals, { key = pr.key, reasons = placement.reasons, toast = toast })
				if toast then table.insert(loud, pr) end
			elseif (placement.column == "ready" or placement.column == "approved") and from ~= "ready" and from ~= "approved" then
				table.insert(changes.good, pr.key)
			end
		end
	end
	if #loud == 1 then
		local pr = loud[1]
		local reason = "needs fixes"
		for _, arrival in changes.arrivals do
			if arrival.key == pr.key then
				for _, r in arrival.reasons do
					if r ~= "conflict" then reason = REASON_TEXT[r]; break end
				end
			end
		end
		changes.toast = { text = "#" .. pr.number .. " needs fixes: " .. reason }
	elseif #loud > 1 then
		changes.toast = { text = #loud .. " pull requests need fixes" }
	end
	return changes
end

export type Alerts = {
	toast: { text: string, sub: string? }?, -- the one toast for the refresh
	rings: { string }, -- keys that arrive in Needs fixes: the red ring
	good: { string }, -- keys that became ready or approved: the green wash
}

-- What the block shows for `changes`: the toast text and the keys to ring red and to wash green.
function M.alerts(changes: Changes): Alerts
	local rings: { string } = {}
	for _, arrival in changes.arrivals do table.insert(rings, arrival.key) end
	return { toast = changes.toast, rings = rings, good = changes.good }
end

-- Schedule ----------------------------------------------------------------------------------------------------

export type ScheduleInput = {
	now: number,
	refreshedAt: number?, -- the last full refresh, re-read from `hub.cache` every tick so windows share work
	refreshing: boolean,
	probedAt: number?,
	probeChanged: boolean, -- the last probe saw a change that no refresh has covered
	focusedAt: number?, -- a focus the block has not refreshed for yet
	checksAt: number?,
	running: { string }, -- node ids of PRs with running checks
}
export type Schedule = { probe: number, refresh: number?, checks: number? } -- seconds from now until due; 0 is now; nil is off

local function untilDue(at: number, now: number): number
	return math.max(0, at - now)
end

-- probe: PROBE_EVERY after the last one. refresh: REFRESH_EVERY after the last, or sooner when a probe saw a change
-- or the hub regained focus, but never within DEBOUNCE of the last; off while one runs. checks: CHECKS_EVERY, only while
-- `running` is not empty.
function M.schedule(input: ScheduleInput): Schedule
	local now, last = input.now, input.refreshedAt
	local probe = if input.probedAt then untilDue(input.probedAt + M.PROBE_EVERY, now) else 0
	local refresh: number? = nil
	if not input.refreshing then
		if last == nil then
			refresh = 0
		else
			local due = last + M.REFRESH_EVERY
			-- A focus a later refresh already covered (another window's) is spent.
			local focused = input.focusedAt ~= nil and input.focusedAt > last
			if input.probeChanged or focused then due = math.min(due, last + M.DEBOUNCE) end
			refresh = untilDue(math.max(due, last + M.DEBOUNCE), now)
		end
	end
	local checks: number? = nil
	if #input.running > 0 then
		checks = if input.checksAt then untilDue(input.checksAt + M.CHECKS_EVERY, now) else 0
	end
	return { probe = probe, refresh = refresh, checks = checks }
end

return M
