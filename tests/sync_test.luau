--!strict
local Sync = require("../src/hub/sync")
local Cases: any = require("../fixtures/hub/cases")

local NOW: number = Cases.asOf

local function cacheOf(prs: { any }, patch: { [string]: any }?): Sync.Cache
	local cache: any = {
		schema = 1, refreshedAt = Cases.asOfIso, viewer = "jubbydev", prs = prs, rateLimit = nil, lastModified = nil,
		counts = { toReview = 0, needFixes = 0 },
	}
	if patch then
		for k, v in patch do cache[k] = v end
	end
	return cache
end

local function byKey(prs: { any }): { [string]: any }
	local out = {}
	for _, pr in prs do out[pr.key] = pr end
	return out
end

local function clone(pr: any): any
	return table.clone(pr)
end

-- Every case's expected arrivals, green wash and toast, from the fixture.
local function testRefreshes()
	for _, case in Cases.refreshes do
		local old = if case.previous then cacheOf(case.previous) else nil
		local changes = Sync.diff(old, case.prs, NOW, case.suppressed)
		assert(changes.firstLoad == (case.previous == nil), case.name .. ": firstLoad")
		local keys = {}
		for _, arrival in changes.arrivals do table.insert(keys, arrival.key) end
		assert(table.concat(keys, ",") == table.concat(case.rings, ","), case.name .. ": arrivals " .. table.concat(keys, ","))
		assert(table.concat(changes.good, ",") == table.concat(case.good, ","), case.name .. ": good")
		local text = if changes.toast then changes.toast.text else nil
		assert(text == case.toast, case.name .. ": toast " .. tostring(text))
	end
end

local function testDiffDetails()
	-- A conflict-only arrival does not toast; one with a failing check does.
	local old = cacheOf({ clone(Cases.prs[5]) })
	local conflicted = clone(Cases.prs[5])
	conflicted.conflicts = true
	local fresh = { conflicted }
	local before = clone(Cases.prs[5])
	before.conflicts = false
	local changes = Sync.diff(cacheOf({ before }), fresh, NOW, {})
	assert(#changes.arrivals == 1 and changes.arrivals[1].toast == false and changes.toast == nil)
	assert(changes.arrivals[1].reasons[1] == "conflict")
	-- The single toast names the reason: a merge failure.
	local web = byKey(Cases.prs)["acme/web#101"]
	local was = clone(web)
	was.mergeFailure = nil
	local one = Sync.diff(cacheOf({ was }), { web }, NOW, {})
	assert(one.toast ~= nil and one.toast.text == "#101 needs fixes: merge failed")
	-- A PR missing from the old cache never arrives.
	local missing = Sync.diff(cacheOf({}), { web }, NOW, {})
	assert(#missing.arrivals == 0 and missing.toast == nil and not missing.firstLoad)
	-- An unchanged board changes nothing.
	local same = Sync.diff(old, old.prs, NOW, {})
	assert(#same.arrivals == 0 and #same.good == 0 and same.toast == nil)
end

local function testLoadSave()
	local prs = Cases.prs
	local cache = Sync.merge({ prs = prs, viewer = "jubbydev", rateLimit = { cost = 1, remaining = 4999, limit = 5000, resetAt = "2026-10-09T13:00:00Z" }, calls = {}, truncated = false, partial = nil } :: any,
		nil, { added = {}, tandem = {} }, NOW)
	assert(cache.refreshedAt == "2026-10-09T12:00:00Z", cache.refreshedAt)
	-- Round trip: the stored value loads back equal and saves again without change under a large cap.
	local stored = Sync.save(cache, math.huge, function() return 1 end)
	local loaded = Sync.load(stored)
	assert(loaded ~= nil and #loaded.prs == #prs and loaded.viewer == "jubbydev" and loaded.refreshedAt == cache.refreshedAt)
	assert(loaded.counts.needFixes == cache.counts.needFixes and loaded.counts.toReview == cache.counts.toReview)
	assert(#Sync.save(loaded, math.huge, function() return 1 end).prs == #prs)
	-- Malformed or not schema 1: nil, no throw.
	assert(Sync.load(nil) == nil and Sync.load("x") == nil and Sync.load(5) == nil and Sync.load({}) == nil)
	local wrong: any = table.clone(stored)
	wrong.schema = 2
	assert(Sync.load(wrong) == nil)
	local noPrs: any = table.clone(stored)
	noPrs.prs = "nope"
	assert(Sync.load(noPrs) == nil)
	local badPr: any = table.clone(stored)
	badPr.prs = { { key = "a/b#1" } }
	assert(Sync.load(badPr) == nil)
	local badCounts: any = table.clone(stored)
	badCounts.counts = { toReview = "x" }
	assert(Sync.load(badCounts) == nil)
	-- Over the cap: the oldest lastActivityAt goes first, down to the cap.
	local function count(value: any): number return #value.prs end
	local capped = Sync.save(cache, 10, count)
	assert(#capped.prs == 10 and #cache.prs == #prs, "save leaves the input alone")
	local oldest = {}
	for _, pr in prs do table.insert(oldest, pr.lastActivityAt) end
	table.sort(oldest)
	local cut = oldest[#oldest - 10]
	for _, pr in capped.prs do assert(pr.lastActivityAt >= cut, "kept PR is newer than every dropped one") end
	assert(Sync.save(cache, 0, count).prs ~= nil and #Sync.save(cache, 0, count).prs == 0)
end

local function testMerge()
	local quiet = clone(byKey(Cases.prs)["acme/web#104"])
	local previous = cacheOf({ quiet }, { counts = { toReview = 0, needFixes = 0, flashAt = 7 } })
	previous.prs[1].pending = { method = "queue", at = "2026-10-09T11:00:00Z" }
	previous.prs[1].tandem = true
	local fresh = clone(quiet)
	fresh.pending = nil
	fresh.tandem = false
	local moved = clone(quiet)
	moved.key = "acme/web#999"
	moved.pending = nil
	local refresh: any = { prs = { fresh, moved }, viewer = "jubbydev", rateLimit = { cost = 1, remaining = 1, limit = 2, resetAt = "" }, calls = {}, truncated = false }
	local localFacts: Sync.Local = { added = { ["acme/web#999"] = { repo = "acme/web", number = 999 } }, tandem = { ["acme/web#104"] = true } }
	local merged = Sync.merge(refresh, previous, localFacts, NOW)
	assert(merged.prs[1].tandem == true and merged.prs[1].addedByMe == false)
	assert(merged.prs[2].tandem == false and merged.prs[2].addedByMe == true)
	local carried = merged.prs[1].pending
	assert(carried ~= nil and carried.method == "queue", "pending kept while the head is the same")
	assert(merged.prs[2].pending == nil)
	-- A moved head drops it.
	fresh.headOid = "other"
	assert(Sync.merge(refresh, previous, localFacts, NOW).prs[1].pending == nil)
	-- Counts rebuilt: #104 (failing, active) and #999 are both in Needs fixes; flash rises with the count.
	assert(merged.counts.needFixes == 2 and merged.counts.toReview == 0 and merged.counts.flashAt == NOW)
	local calm = Sync.merge({ prs = {}, viewer = "jubbydev", rateLimit = refresh.rateLimit, calls = {}, truncated = false } :: any, merged, { added = {}, tandem = {} }, NOW + 60)
	assert(calm.counts.needFixes == 0 and calm.counts.flashAt == NOW and calm.refreshedAt == "2026-10-09T12:01:00Z")
	-- Counts over the whole fixture.
	local all = Sync.merge({ prs = Cases.prs, viewer = "jubbydev", rateLimit = refresh.rateLimit, calls = {}, truncated = false } :: any, nil, { added = {}, tandem = {} }, NOW)
	local fixes, review = 0, 0
	for _, pr in Cases.prs do
		local column = require("../src/hub/model").classify(pr, NOW)
		if column == "needs_fixes" then fixes += 1 elseif column == "to_review" then review += 1 end
	end
	assert(all.counts.needFixes == fixes and all.counts.toReview == review and fixes > 0 and review > 0 and all.counts.flashAt == nil)
end

local function testMergeRecord()
	assert(Sync.loadMerge(nil) == nil and Sync.loadMerge({ schema = 2 }) == nil and Sync.loadMerge("x") == nil)
	local record = Sync.loadMerge({
		schema = 1, user = { kind = "squash" }, declared = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" },
		learned = { kind = "bogus" }, learnedAnswered = true, checkedAt = "2026-10-09T12:00:00Z",
	})
	assert(record ~= nil and record.user ~= nil and record.user.kind == "squash")
	assert(record.declared ~= nil and record.declared.kind == "comment" and record.declared.command == "/aviator merge")
	assert(record.learned == nil and record.learnedAnswered == true and record.checkedAt == "2026-10-09T12:00:00Z")
	local evidence = Sync.mergeEvidence(record, "rebase")
	assert(evidence.user == record.user and evidence.declared == record.declared and evidence.learned == nil)
	assert(evidence.learnedAnswered == true and evidence.viewerDefault == "rebase")
	local none = Sync.mergeEvidence(nil, "merge")
	assert(none.user == nil and none.declared == nil and none.learned == nil and not none.learnedAnswered and none.viewerDefault == "merge")
	local label = Sync.loadMerge({ schema = 1, learned = { kind = "label", label = "automerge" } })
	assert(label ~= nil and label.learned ~= nil and label.learned.kind == "label" and not label.learnedAnswered)
end

local function testRecent()
	assert(Sync.RECENT_CAP == 8)
	assert(#Sync.openedList(nil) == 0 and #Sync.openedList("x") == 0)
	local list = Sync.openedList({ { repo = "a/b", number = 1, title = "T", author = "me", at = "x" }, { repo = "a/b" }, "junk", { repo = "c/d", number = 2 } })
	assert(#list == 2 and list[1].title == "T" and list[2].title == "" and list[2].author == "" and list[2].at == "")
	local out: { Sync.Opened } = {}
	for i = 1, 10 do
		out = Sync.remember(out, { repo = "a/b", number = i, title = "", author = "", at = "" })
	end
	assert(#out == 8 and out[1].number == 10 and out[8].number == 3)
	out = Sync.remember(out, { repo = "A/B", number = 5, title = "again", author = "", at = "" })
	assert(#out == 8 and out[1].title == "again" and out[1].number == 5)
	local seen = 0
	for _, item in out do if item.number == 5 then seen += 1 end end
	assert(seen == 1, "duplicates are suppressed, ignoring repo case")
end

-- Runs the schedule on a fake clock, one tick a second, as the block would. Returns what ran.
local function simulate(from: number, to: number, script: { probeChangesAt: { number }?, focusAt: { number }?, runningUntil: number }): ({ number }, { number }, { number }, number)
	local refreshes, probes, checks = {}, {}, {}
	local cost = 0
	local state: Sync.ScheduleInput = {
		now = from, refreshedAt = nil, refreshing = false, probedAt = from, probeChanged = false, focusedAt = nil,
		checksAt = nil, running = {},
	}
	local changeAt, focusAt = {}, {}
	for _, t in script.probeChangesAt or {} do changeAt[t] = true end
	for _, t in script.focusAt or {} do focusAt[t] = true end
	for now = from, to do
		state.now = now
		state.running = if now < script.runningUntil then { "id" } else {}
		if focusAt[now] then state.focusedAt = now end
		local due = Sync.schedule(state)
		if due.probe == 0 then
			table.insert(probes, now)
			state.probedAt = now
			if changeAt[now] then state.probeChanged = true end
			due = Sync.schedule(state)
		end
		if due.refresh == 0 then
			table.insert(refreshes, now)
			state.refreshedAt = now
			state.probeChanged = false
			cost += 17
		end
		if due.checks == 0 then
			table.insert(checks, now)
			state.checksAt = now
			cost += 1
		end
	end
	return refreshes, probes, checks, cost
end

local function gaps(times: { number }): { number }
	local out = {}
	for i = 2, #times do table.insert(out, times[i] - times[i - 1]) end
	return out
end

local function testSchedule()
	-- A quiet hour with checks running for the first 5 minutes.
	local refreshes, probes, checks, cost = simulate(0, 3599, { runningUntil = 300 })
	assert(probes[1] == 0 + 60 and #probes == 59, "probe at 60 s and every 60 s: " .. #probes)
	for _, gap in gaps(probes) do assert(gap == 60) end
	assert(refreshes[1] == 0 and #refreshes == 12, "twelve refreshes in the hour: " .. #refreshes)
	for _, gap in gaps(refreshes) do assert(gap == 300) end
	assert(#checks == 10 and checks[1] == 0 and checks[2] == 30 and checks[10] == 270, "checks every 30 s while running")
	for _, gap in gaps(checks) do assert(gap == 30) end
	assert(cost == 12 * 17 + 10 and cost <= 220, "modelled cost " .. cost)
	-- No checks poll when nothing runs.
	local _, _, none = simulate(0, 3599, { runningUntil = 0 })
	assert(#none == 0)
	-- A probe change starts a refresh at once once the debounce has passed, and never inside it.
	local changed = simulate(0, 3599, { runningUntil = 0, probeChangesAt = { 120, 130 } })
	assert(table.concat(changed, ",", 1, 3) == "0,120,420", "change at 120 refreshes at 120: " .. table.concat(changed, ","))
	local early = simulate(0, 3599, { runningUntil = 0, probeChangesAt = { 60 } })
	assert(early[2] == 60, "a change at 60 s is past the 30 s debounce")
	-- A change right after a refresh waits out the debounce.
	local direct: Sync.ScheduleInput = { now = 10, refreshedAt = 0, refreshing = false, probedAt = 0, probeChanged = true, focusedAt = nil, checksAt = nil, running = {} }
	assert(Sync.schedule(direct).refresh == 20 and Sync.schedule(direct).probe == 50)
	direct.probeChanged, direct.focusedAt = false, 12
	assert(Sync.schedule(direct).refresh == 20, "focus waits out the debounce")
	direct.now = 45
	assert(Sync.schedule(direct).refresh == 0)
	-- A focus a newer refresh already covered is spent.
	direct.refreshedAt, direct.now = 40, 50
	assert(Sync.schedule(direct).refresh == 290)
	-- No refresh is due while one runs; a first load is due now; running checks have no past poll means now.
	direct.refreshing = true
	assert(Sync.schedule(direct).refresh == nil)
	direct.refreshing, direct.refreshedAt, direct.probedAt = false, nil, nil
	local first = Sync.schedule(direct)
	assert(first.refresh == 0 and first.probe == 0 and first.checks == nil)
	direct.running = { "a", "b" }
	assert(Sync.schedule(direct).checks == 0)
	-- Focus every 10 s for an hour: refreshes keep to the debounce, and never closer than 30 s.
	local focuses = {}
	for t = 5, 3599, 10 do table.insert(focuses, t) end
	local busy = simulate(0, 3599, { runningUntil = 0, focusAt = focuses })
	for _, gap in gaps(busy) do assert(gap >= Sync.DEBOUNCE) end
end

return function()
	testRefreshes()
	testDiffDetails()
	testLoadSave()
	testMerge()
	testMergeRecord()
	testRecent()
	testSchedule()
end
