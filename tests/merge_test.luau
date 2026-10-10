--!strict
local FakeRunner = require("./fake-runner")
local Github = require("../src/github")
local Model = require("../src/hub/model")
local State = require("../src/hub/state")
local Sync = require("../src/hub/sync")
local Cases: any = require("../fixtures/hub/cases")
local Fixture: any = require("../fixtures/hub/merge-methods")
local RawHub: any = require("../fixtures/hub/raw-hub-f")
local RawThreads: any = require("../fixtures/hub/raw-threads")
local RawChecks: any = require("../fixtures/hub/raw-checks")

local NOW: number = Fixture.asOf
local COST_LIMIT = 18
local BASE = { "gh", "api", "graphql", "-f" }

local function same(a: any, b: any, path: string)
	if type(a) ~= type(b) then error(path .. ": " .. tostring(a) .. " ~= " .. tostring(b), 0) end
	if type(a) ~= "table" then
		if a ~= b then error(path .. ": " .. tostring(a) .. " ~= " .. tostring(b), 0) end
		return
	end
	for k, v in a do same(v, b[k], path .. "." .. tostring(k)) end
	for k in b do
		if a[k] == nil then error(path .. "." .. tostring(k) .. ": missing", 0) end
	end
end

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in value do out[k] = clone(v) end
	return out
end

local function first(call: ((any, any) -> ()) -> ()): (any, any)
	local value, err, called = nil, nil, false
	call(function(v, e)
		assert(not called, "callback fired twice")
		called = true
		value, err = v, e
	end)
	assert(called, "callback never fired")
	return value, err
end

local function pr109(): any
	for _, pr in Cases.prs do
		if pr.key == "acme/api#109" then return clone(pr) end
	end
	error("no acme/api#109")
end

local function evidence(patch: { [string]: any }): Model.MergeEvidence
	local out: any = { user = nil, declared = nil, learned = nil, learnedAnswered = false, viewerDefault = "squash" }
	for k, v in patch do out[k] = v end
	return out
end

-- Resolution order: your choice, declared, learned (asked once), viewer default.
local function testResolution()
	local user: Model.MergeMethod = { kind = "label", label = "ready-to-merge" }
	local declared: Model.MergeMethod = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" }
	local learned: Model.MergeMethod = { kind = "comment", command = "/merge", cancel = nil }

	local all = Model.resolveMergeMethod(evidence({ user = user, declared = declared, learned = learned, viewerDefault = "rebase" }))
	assert(all.source == "user" and all.method == user and all.ask == false)
	local noUser = Model.resolveMergeMethod(evidence({ declared = declared, learned = learned, viewerDefault = "rebase" }))
	assert(noUser.source == "declared" and noUser.method == declared and noUser.ask == false)
	local suggested = Model.resolveMergeMethod(evidence({ learned = learned, viewerDefault = "rebase" }))
	assert(suggested.source == "learned" and suggested.method == learned and suggested.ask == true)
	local declined = Model.resolveMergeMethod(evidence({ learned = learned, learnedAnswered = true, viewerDefault = "rebase" }))
	assert(declined.source == "viewer" and declined.method.kind == "rebase" and declined.ask == false)
	local fallback = Model.resolveMergeMethod(evidence({ viewerDefault = "merge" }))
	assert(fallback.source == "viewer" and fallback.method.kind == "merge" and fallback.ask == false)

	-- Saying yes saves the learned method as the viewer's own: it no longer asks.
	local record = Sync.loadMerge({ schema = 1, learned = { kind = "comment", command = "/merge" }, learnedAnswered = false, viewerDefault = "merge" }) :: Sync.MergeRecord
	assert(record.viewerDefault == "merge")
	local asked = Model.resolveMergeMethod(Sync.mergeEvidence(record, "merge"))
	assert(asked.ask == true and asked.source == "learned")
	record.user = record.learned
	local accepted = Model.resolveMergeMethod(Sync.mergeEvidence(record, "merge"))
	assert(accepted.source == "user" and accepted.ask == false)
	-- Saying no is saved and never asked again, even after the habit is seen again.
	local no = Sync.loadMerge({ schema = 1, learned = { kind = "comment", command = "/merge" }, learnedAnswered = true }) :: Sync.MergeRecord
	local noAgain = Model.resolveMergeMethod(Sync.mergeEvidence(no, "squash"))
	assert(noAgain.source == "viewer" and noAgain.ask == false)
	-- A record the plugin did not write is ignored.
	assert(Sync.loadMerge({ schema = 2 }) == nil and Sync.loadMerge("x") == nil)
	local junk = Sync.loadMerge({ schema = 1, user = { kind = "comment" }, declared = { kind = "teleport" }, viewerDefault = "fast" }) :: Sync.MergeRecord
	assert(junk.user == nil and junk.declared == nil and junk.viewerDefault == nil)
end

-- What a repo declares and what its last merges show.
local function testDetect()
	local aviator = Github.parseDetect(Fixture.detect["acme/aviator"]) :: Github.Detected
	same(aviator.declared, { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" }, "aviator declared")
	assert(aviator.learned == nil and aviator.viewerDefault == "squash" and aviator.checkedAt == "")

	local queued = Github.parseDetect(Fixture.detect["acme/queued"]) :: Github.Detected
	same(queued.declared, { kind = "queue" }, "queue declared")
	assert(queued.viewerDefault == "merge")

	local learned = Github.parseDetect(Fixture.detect["acme/botmerge"]) :: Github.Detected
	assert(learned.declared == nil and learned.viewerDefault == "rebase")
	same(learned.learned, { kind = "comment", command = "/merge" }, "learned from 8 of 8")

	-- Two of six is not a habit, and a command from a bot or a merge by a person does not count.
	local mixed = Github.parseDetect(Fixture.detect["acme/mixed"]) :: Github.Detected
	assert(mixed.learned == nil and mixed.declared == nil)
	local plain = Github.parseDetect(Fixture.detect["acme/plain"]) :: Github.Detected
	assert(plain.learned == nil and plain.declared == nil and plain.viewerDefault == "squash")
	for _, raw in { {}, { data = {} }, { data = { repository = "x" } }, "x", 7 } do assert(Github.parseDetect(raw) == nil) end
	assert(Github.parseDetect(nil) == nil)

	-- The client asks once, with the owner and name as variables.
	local fake = FakeRunner.new({ { prefix = BASE, contains = "query MergeDetect(", reply = { stdout = "aviator" } } })
	local client = Github.client(fake.run, function(text: string): any return Fixture.detect["acme/" .. text] end)
	local value, err = first(function(done) client.detect("acme/aviator", done) end)
	assert(err == nil and value.declared.command == "/aviator merge")
	fake.expectOnly(1)
	local argv = fake.calls[1].argv
	assert(#argv == 9 and string.sub(argv[5], 1, 24) == "query=query MergeDetect(")
	assert(argv[6] == "-f" and argv[7] == "owner=acme" and argv[8] == "-f" and argv[9] == "name=aviator")
	local _, bad = first(function(done) client.detect("not a repo", done) end)
	assert(bad.message == "Couldn't detect how not a repo merges: not an owner/repo name")
	fake.expectOnly(1)
end

-- The five Merge failed sources, each with its reason.
local function failureOf(name: string, method: "comment" | "label"): Model.MergeFailure?
	return Github.parseMergeFailure(Fixture.failures[name], { method = method, at = Fixture.pendingAt })
end

local function testMergeFailureSources()
	same(failureOf("aviator", "comment"), { kind = "aviator", reason = "This pull request failed to merge: e2e failed on the merge group." }, "aviator reply")
	same(failureOf("aviatorCheck", "comment"), { kind = "aviator", reason = "Aviator MergeQueue failed" }, "aviator check")
	same(failureOf("comment", "comment"), { kind = "comment", reason = "ci" }, "comment then a failing check")
	same(failureOf("check", "label"), { kind = "check", reason = "buildkite/api" }, "label then a failing check")
	same(failureOf("bot", "comment"), { kind = "bot", reason = "Couldn't merge: 2 approvals are required." }, "bot reply, newest first line")
	local queue = (Github.parseHub(Fixture.queueRemoval) :: any).prs[1].mergeFailure
	same(queue, { kind = "queue", reason = "Removed from the merge queue: merge conflict with the base branch" }, "queue removal")

	-- A newer event supersedes: the failure is older than the merge asked for, or nothing failed.
	assert(Github.parseMergeFailure(Fixture.failures.superseded, { method = "comment", at = Fixture.pendingAt }) == nil)
	assert(Github.parseMergeFailure(Fixture.failures.comment, { method = "comment", at = "2026-10-09T11:00:00Z" }) == nil)
	assert(Github.parseMergeFailure(Fixture.failures.fine, { method = "comment", at = Fixture.pendingAt }) == nil)
	-- A queue merge never needs the lookup, and garbage is nothing.
	assert(Github.parseMergeFailure(Fixture.failures.comment, { method = "queue", at = Fixture.pendingAt }) == nil)
	assert(Github.parseMergeFailure(nil, { method = "comment", at = Fixture.pendingAt }) == nil)
	assert(Github.parseMergeFailure("x", { method = "comment", at = Fixture.pendingAt }) == nil)
end

-- Each source puts the PR first in Needs fixes with its reason; a new head clears it.
local function testNeedsFixes()
	local failures: { [string]: Model.MergeFailure } = {
		queue = { kind = "queue", reason = "Removed from the merge queue: merge conflict with the base branch" },
		aviator = failureOf("aviator", "comment") :: Model.MergeFailure,
		comment = failureOf("comment", "comment") :: Model.MergeFailure,
		check = failureOf("check", "label") :: Model.MergeFailure,
		bot = failureOf("bot", "comment") :: Model.MergeFailure,
	}
	for _, kind in { "queue", "aviator", "comment", "check", "bot" } do
		local prs: { any } = {}
		for _, pr in Cases.prs do table.insert(prs, clone(pr)) end
		local target: any
		for _, pr in prs do
			-- Old cases failed in the queue; start from none.
			pr.mergeFailure = nil
			if pr.key == "acme/api#109" then target = pr end
		end
		-- Another PR that needs fixes sits in front of it by age, as does a feedback case.
		target.mergeFailure = failures[kind]
		assert(failures[kind].kind == kind)
		local placement = Model.placement(target, NOW)
		assert(placement.column == "needs_fixes" and placement.reasons[1] == "merge_failed", kind .. ": placement")
		local ordered = Model.order(prs, "needs_fixes", "priority", NOW)
		assert(ordered[1].key == "acme/api#109", kind .. ": first in Needs fixes, got " .. ordered[1].key)
		assert(Model.queue(prs, NOW)[1].key == "acme/api#109" and Model.queue(prs, NOW)[1].reason == "merge_failed")
		-- The card shows the reason.
		local s = State.new(prs, NOW, nil)
		local card = State.card(s, "acme/api#109") :: State.Card
		assert(card.chips[1].text == "Merge failed" and card.detail == failures[kind].reason, kind .. ": reason on the card")
	end
end

-- Refresh: the lookup runs only for a merge in flight on the same head, its cost counts, and a new head clears the failure.
local function refreshClient(): (Github.Client, FakeRunner.Fake)
	local node = clone(Fixture.failures.comment)
	node.id, node.headRefOid = "PR_acme/api#109", "head109"
	local bodies: { [string]: any } = {
		["hub-f"] = RawHub, threads = RawThreads, checks = RawChecks,
		failure = { data = {
			rateLimit = { cost = 1, remaining = 4900, limit = 5000, resetAt = "2026-10-09T13:00:00Z" },
			nodes = { node },
		} },
	}
	local fake = FakeRunner.new({
		{ prefix = BASE, contains = "query MergeFailure(", reply = { stdout = "failure" } },
		{ prefix = BASE, contains = "query Hub(", reply = { stdout = "hub-f" } },
		{ prefix = BASE, contains = "query Threads(", reply = { stdout = "threads" } },
		{ prefix = BASE, contains = "query Checks(", reply = { stdout = "checks" } },
	})
	return Github.client(fake.run, function(text: string): any return bodies[text] end), fake
end

local function testRefresh()
	local client, fake = refreshClient()
	-- No merge in flight: the same two calls as before.
	local plain = first(function(done) client.refresh({ added = {}, previous = {} }, done) end)
	assert(#plain.calls == 2 and #fake.calls == 2)
	local base = clone(plain.prs)
	local target: any
	for _, pr in base do
		if pr.id == "PR_acme/api#109" then target = pr end
	end
	assert(target.headOid == "head109" and target.mergeFailure == nil)

	-- A comment merge in flight on the same head: one more call, asking for that PR only.
	local pending = clone(target)
	pending.pending = { method = "comment", at = Fixture.pendingAt }
	local value = first(function(done) client.refresh({ added = {}, previous = { pending } }, done) end)
	assert(#fake.calls == 5 and #value.calls == 3)
	local lookup = fake.calls[5]
	assert(string.find(lookup.argv[5], "query MergeFailure(", 1, true) ~= nil)
	same({ table.unpack(lookup.argv, 6) }, { "-f", "ids[]=PR_acme/api#109" }, "lookup ids")
	local failing: any
	for _, pr in value.prs do
		if pr.id == "PR_acme/api#109" then failing = pr end
		if pr.id ~= "PR_acme/api#109" then assert(pr.mergeFailure == nil or pr.mergeFailure.kind == "queue") end
	end
	same(failing.mergeFailure, { kind = "comment", reason = "ci" }, "failure from the lookup")
	assert(value.rateLimit == value.calls[3])
	-- The whole refresh, with the lookup, stays under the budget the tests hold.
	local total = 0
	for _, call in value.calls do total += call.cost end
	local checks = RawChecks.data.rateLimit.cost
	assert(total + checks <= COST_LIMIT, "a refresh costs " .. (total + checks) .. " points, the limit is " .. COST_LIMIT)

	-- A new head: the merge is over, so no lookup and no failure.
	local moved = clone(pending)
	moved.headOid = "older-head"
	local calls = #fake.calls
	local after = first(function(done) client.refresh({ added = {}, previous = { moved } }, done) end)
	assert(#fake.calls == calls + 2 and #after.calls == 2)
	for _, pr in after.prs do
		if pr.id == "PR_acme/api#109" then assert(pr.mergeFailure == nil) end
	end
	-- And Sync drops the carried pending with the head, so the next refresh looks nothing up either.
	local previous: any = { schema = 1, refreshedAt = Cases.asOfIso, viewer = "me", prs = { moved }, counts = { toReview = 0, needFixes = 0 } }
	local merged = Sync.merge(after, previous, { added = {}, tandem = {} }, NOW)
	for _, pr in merged.prs do
		if pr.id == "PR_acme/api#109" then assert(pr.pending == nil and pr.mergeFailure == nil) end
	end

	-- A queue merge in flight needs no lookup: hub-f carries its removal.
	local queued = clone(target)
	queued.pending = { method = "queue", at = Fixture.pendingAt }
	calls = #fake.calls
	first(function(done) client.refresh({ added = {}, previous = { queued } }, done) end)
	assert(#fake.calls == calls + 2)

	-- A lookup that fails leaves the refresh standing.
	local broken = FakeRunner.new({
		{ prefix = BASE, contains = "query MergeFailure(", reply = { status = 1, stderr = "gh: HTTP 502" } },
		{ prefix = BASE, contains = "query Hub(", reply = { stdout = "hub-f" } },
		{ prefix = BASE, contains = "query Threads(", reply = { stdout = "threads" } },
	})
	local survivor = Github.client(broken.run, function(text: string): any
		return if text == "hub-f" then RawHub else RawThreads
	end)
	local ok = first(function(done) survivor.refresh({ added = {}, previous = { pending } }, done) end)
	assert(#ok.prs == #base and ok.partial ~= nil and ok.partial.message == "Couldn't check merges in flight: HTTP 502")
end

-- Sync carries a merge in flight while the head is the same, and drops it when the queue says it's over.
local function testCarry()
	local before = pr109()
	before.pending = { method = "label", at = Fixture.pendingAt }
	local previous: any = { schema = 1, refreshedAt = Cases.asOfIso, viewer = "me", prs = { before }, counts = { toReview = 0, needFixes = 0 } }
	local function refreshWith(patch: { [string]: any }): any
		local fresh = clone(before)
		fresh.pending = nil
		for k, v in patch do fresh[k] = v end
		local refresh: any = { prs = { fresh }, viewer = "me", rateLimit = { cost = 0, remaining = 0, limit = 0, resetAt = "" }, calls = {}, truncated = false }
		return Sync.merge(refresh, previous, { added = {}, tandem = {} }, NOW).prs[1]
	end
	assert(refreshWith({}).pending ~= nil)
	assert(refreshWith({ headOid = "new" }).pending == nil)
	assert(refreshWith({ mergeFailure = { kind = "queue", reason = "x" } }).pending == nil)
	assert(refreshWith({ mergeFailure = { kind = "check", reason = "ci" } }).pending ~= nil)
end

-- The commands, run against the fake runner: nothing else runs.
local function testCommands()
	local pr = pr109()
	local method: { [string]: Model.MergeMethod } = {
		squash = { kind = "squash" }, merge = { kind = "merge" }, rebase = { kind = "rebase" }, queue = { kind = "queue" },
		aviator = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" },
		bot = { kind = "comment", command = "/merge", cancel = nil },
		label = { kind = "label", label = "ready-to-merge" },
	}
	local merges: { [string]: { string } } = {
		squash = { "gh", "pr", "merge", "109", "--repo", "acme/api", "--squash" },
		merge = { "gh", "pr", "merge", "109", "--repo", "acme/api", "--merge" },
		rebase = { "gh", "pr", "merge", "109", "--repo", "acme/api", "--rebase" },
		queue = { "gh", "pr", "merge", "109", "--repo", "acme/api", "--auto" },
		aviator = { "gh", "pr", "comment", "109", "--repo", "acme/api", "--body", "/aviator merge" },
		bot = { "gh", "pr", "comment", "109", "--repo", "acme/api", "--body", "/merge" },
		label = { "gh", "pr", "edit", "109", "--repo", "acme/api", "--add-label", "ready-to-merge" },
	}
	for name, argv in merges do
		local command = Github.commands.merge(pr, method[name])
		same(command.argv, argv, "merge " .. name)
		assert(command.stdin == nil)
	end
	local cancels: { [string]: { string } } = {
		queue = { "gh", "pr", "merge", "109", "--repo", "acme/api", "--disable-auto" },
		aviator = { "gh", "pr", "comment", "109", "--repo", "acme/api", "--body", "/aviator cancel" },
		label = { "gh", "pr", "edit", "109", "--repo", "acme/api", "--remove-label", "ready-to-merge" },
	}
	for name, argv in cancels do
		local command = Github.commands.cancelMerge(pr, method[name])
		same(command.argv, argv, "cancel " .. name)
		assert(command.stdin == nil)
	end
	-- A GitHub merge happens at once, and a comment with no cancel can't be taken back.
	for _, name in { "squash", "merge", "rebase", "bot" } do
		assert(not pcall(Github.commands.cancelMerge, pr, method[name]), name .. " has nothing to cancel")
	end

	-- Run for real against the fake: an Aviator repo merges with a comment and cancels with a comment; GitHub's merge never runs.
	local fake = FakeRunner.new({
		{ prefix = { "gh", "pr", "comment" }, reply = { stdout = "https://github.com/acme/api/pull/109#issuecomment-1\n" } },
	})
	local client = Github.client(fake.run, function(): any return {} end)
	local out, err = first(function(done) client.run(Github.commands.merge(pr, method.aviator), done) end)
	assert(err == nil and out ~= nil)
	out, err = first(function(done) client.run(Github.commands.cancelMerge(pr, method.aviator), done) end)
	assert(err == nil and out ~= nil)
	fake.expectOnly(2)
	same(fake.calls[1].argv, merges.aviator, "ran /aviator merge")
	same(fake.calls[2].argv, cancels.aviator, "ran /aviator cancel")
end

-- The board: the chooser, the card's note and Cancel merge.
local function testCards()
	local prs: { any } = {}
	for _, pr in Cases.prs do table.insert(prs, clone(pr)) end
	local s = State.new(prs, NOW, nil)
	local function resolve(patch: { [string]: any })
		State.setMerge(s, "acme/api", Model.resolveMergeMethod(evidence(patch)))
	end

	-- A GitHub method asks first, a comment runs at once, a learned one asks once.
	local ready = State.card(s, "acme/api#109") :: State.Card
	assert(ready.main ~= nil and ready.main.act == "card-merge" and State.mergeStep(s, ready.pr) == "confirm")
	resolve({ declared = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" } })
	assert(State.mergeStep(s, ready.pr) == "run")
	resolve({ learned = { kind = "comment", command = "/merge" } })
	assert(State.mergeStep(s, ready.pr) == "ask")
	State.askMerge(s, "acme/api#109")
	assert(s.confirm ~= nil and s.confirm.kind == "learned")
	assert((State.card(s, "acme/api#109") :: State.Card).asking == "Comment /merge, as this repository usually does?")
	State.cancelConfirm(s)

	-- The chooser lists the six kinds, ticks the current one and names where it came from.
	resolve({ declared = { kind = "queue" } })
	State.select(s, "acme/api#109")
	State.openMenu(s, "merge")
	local rows = State.menuRows(s)
	assert(#rows == 6 and rows[1].label == "Squash and merge" and rows[4].label == "Merge when ready" and rows[4].on and not rows[1].on)
	assert(rows[5].label == "Comment a command" and rows[6].label == "Add a label")
	assert(s.menuCursor == 4 and State.mergeSource(s) == "Declared by the repository")
	State.closeMenu(s)

	-- Commenting asks for text: "/merge" or "/merge | /cancel".
	State.openMenu(s, "merge")
	State.beginMethodEdit(s, "comment")
	assert((s.methodEdit :: State.MethodEdit).repo == "acme/api" and State.methodOfEdit(s) == nil)
	local edit = s.methodEdit :: State.MethodEdit
	edit.field.text = " /merge | /cancel "
	same(State.methodOfEdit(s), { kind = "comment", command = "/merge", cancel = "/cancel" }, "command with cancel")
	edit.field.text = "/merge"
	same(State.methodOfEdit(s), { kind = "comment", command = "/merge" }, "command alone")
	State.beginMethodEdit(s, "label")
	edit = s.methodEdit :: State.MethodEdit
	edit.field.text = "ready-to-merge"
	same(State.methodOfEdit(s), { kind = "label", label = "ready-to-merge" }, "label")
	State.closeMenu(s)
	assert(s.methodEdit == nil)

	-- A merge in flight reads on the card, and the main action is Cancel merge when it can be cancelled.
	resolve({ user = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" } })
	State.setPending(s, "acme/api#109", { method = "comment", at = Fixture.pendingAt })
	local waiting = State.card(s, "acme/api#109") :: State.Card
	assert(waiting.note == "Queued in Aviator" and waiting.main.act == "card-cancel" and waiting.main.label == "Cancel merge" and waiting.main.key == "M")
	assert(#waiting.more == 0)
	resolve({ user = { kind = "comment", command = "/merge", cancel = nil } })
	waiting = State.card(s, "acme/api#109") :: State.Card
	assert(waiting.note == "Commented /merge · waiting for the merge" and waiting.main == nil)
	resolve({ user = { kind = "label", label = "ready-to-merge" } })
	State.setPending(s, "acme/api#109", { method = "label", at = Fixture.pendingAt })
	waiting = State.card(s, "acme/api#109") :: State.Card
	assert(waiting.note == "Labeled ready-to-merge · waiting for the merge" and waiting.main.act == "card-cancel")
	State.setPending(s, "acme/api#109", { method = "queue", at = Fixture.pendingAt })
	assert((State.card(s, "acme/api#109") :: State.Card).note == "In the merge queue")
	State.setPending(s, "acme/api#109", nil)
	assert((State.card(s, "acme/api#109") :: State.Card).note == nil)
end

return function()
	testResolution()
	testDetect()
	testMergeFailureSources()
	testNeedsFixes()
	testRefresh()
	testCarry()
	testCommands()
	testCards()
end
