--!strict
local FakeRunner = require("./fake-runner")
local Github = require("../src/github")
local Model = require("../src/hub/model")
local State = require("../src/hub/state")
local Fixture: any = require("../fixtures/hub/selection")

local NOW: number = Fixture.asOf

local function copy(value: any): any
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in value do out[k] = copy(v) end
	return out
end

local function fresh(): State.State
	return State.new(copy(Fixture.prs), NOW, { tab = "mine", sort = "priority", folded = { inactive = false } })
end

local function join(list: { string }): string
	return table.concat(list, ",")
end

local function markedKeys(s: State.State): string
	local out: { string } = {}
	for _, card in State.markedCards(s) do table.insert(out, card.pr.key) end
	return join(out)
end

local function byKey(key: string): Model.HubPR
	for _, pr in Fixture.prs do
		if pr.key == key then return pr end
	end
	error("no PR " .. key)
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

-- The confirm shows exactly five titles and the rest as a count; the long titles ride along whole for the view to truncate.
local function testConfirmList()
	local ready: { Model.HubPR } = {}
	for _, key in Fixture.selectable do table.insert(ready, byKey(key)) end
	assert(#ready == 6)
	local list = Model.confirmList(ready)
	assert(#list.shown == 5 and list.more == 1)
	assert(list.shown[1].key == "acme/web#401" and list.shown[5].key == "acme/api#405")
	assert(#byKey("acme/web#404").title > 100, "one title would wrap at split width")
	local few = Model.confirmList({ ready[1], ready[2] })
	assert(#few.shown == 2 and few.more == 0)
	local none = Model.confirmList({})
	assert(#none.shown == 0 and none.more == 0)
	local twelve: { Model.HubPR } = {}
	for i = 1, 12 do twelve[i] = ready[1] end
	local many = Model.confirmList(twelve)
	assert(#many.shown == 5 and many.more == 7)
end

-- How they merge: one line for one method, one per method when mixed.
local function testMethodLines()
	local squash: Model.MergeMethod = { kind = "squash" }
	local comment: Model.MergeMethod = { kind = "comment", command = "/merge", cancel = nil }
	assert(join(Model.methodLines({ squash, squash })) == "Squash and merge")
	assert(join(Model.methodLines({ comment })) == "Comments /merge")
	assert(join(Model.methodLines({ squash, comment, squash, { kind = "queue" } })) == "Squash and merge,Comments /merge,Adds to the merge queue")
	assert(Model.methodLine({ kind = "label", label = "ready" }) == "Adds the ready label")
	assert(Model.methodLine({ kind = "rebase" }) == "Rebase and merge" and Model.methodLine({ kind = "merge" }) == "Create a merge commit")
end

local function testRules()
	-- Ready cards select only when they can merge now.
	for _, key in Fixture.selectable do
		assert(Model.selectGroup(byKey(key), NOW) == "ready", key)
	end
	local group, why = Model.selectGroup(byKey("acme/web#407"), NOW)
	assert(group == nil and why == "it is behind main")
	group, why = Model.selectGroup(byKey("acme/api#408"), NOW)
	assert(group == nil and why == "a merge is already waiting")
	-- In review is not a group; every Inactive row is, drafts too.
	assert(Model.selectGroup(byKey("acme/api#415"), NOW) == nil)
	for _, key in { "acme/web#411", "acme/web#412", "acme/api#413", "acme/mono#414", "acme/api#416" } do
		assert(Model.selectGroup(byKey(key), NOW) == "inactive", key)
	end
	-- Stale: past 7 days and not a draft, whatever the draft's age.
	assert(Model.stale(byKey("acme/api#413"), NOW) and Model.stale(byKey("acme/mono#414"), NOW) and Model.stale(byKey("acme/api#416"), NOW))
	assert(not Model.stale(byKey("acme/web#411"), NOW), "a stale draft is not stale for Close stale")
	assert(not Model.stale(byKey("acme/web#412"), NOW))
	assert(not Model.stale(byKey("acme/api#415"), NOW), "exactly 7 days is still active")
	assert(not Model.stale(byKey("acme/web#401"), NOW))
end

local function testMarking()
	local s = fresh()
	-- Space marks and unmarks.
	assert(State.toggleMark(s, "acme/web#401"))
	assert(State.toggleMark(s, "acme/mono#403"))
	assert(markedKeys(s) == "acme/mono#403,acme/web#401" or markedKeys(s) == "acme/web#401,acme/mono#403", markedKeys(s))
	assert(State.card(s, "acme/web#401").marked == true)
	assert(State.toggleMark(s, "acme/web#401"))
	assert(markedKeys(s) == "acme/mono#403" and State.card(s, "acme/web#401").marked == false)

	-- Behind main and queued Ready cards can't be selected.
	local ok, why = State.toggleMark(s, "acme/web#407")
	assert(not ok and why == "it is behind main")
	ok, why = State.toggleMark(s, "acme/api#408")
	assert(not ok and why == "a merge is already waiting")
	assert(markedKeys(s) == "acme/mono#403")
	-- A card in no group can't either.
	assert(not State.toggleMark(s, "acme/api#415"))

	-- Selecting in one group clears the other.
	assert(State.toggleMark(s, "acme/web#411"))
	assert(markedKeys(s) == "acme/web#411")
	assert(State.selection(s).group == "inactive")
	assert(State.toggleMark(s, "acme/web#401"))
	assert(markedKeys(s) == "acme/web#401" and State.selection(s).group == "ready")
	assert(State.card(s, "acme/web#411").marked == false)

	-- Esc clears.
	assert(State.clearMarks(s) and State.selection(s) == nil)
	assert(not State.clearMarks(s))
end

local function testCloseStale()
	local s = fresh()
	assert(State.staleCount(s) == 3)
	-- It replaces a Ready selection, skips both drafts, and opens the fold.
	State.toggleMark(s, "acme/web#401")
	assert(State.markStale(s) == 3)
	assert(markedKeys(s) == join(Fixture.stale), markedKeys(s))
	assert(s.marked["acme/web#411"] == nil and s.marked["acme/web#412"] == nil)
	assert(s.board.open.inactive and State.selection(s).group == "inactive" and State.selection(s).count == 3)
	-- A draft is selected only by Space, and joins the selection.
	assert(State.toggleMark(s, "acme/web#411"))
	assert(State.selection(s).count == 4)
	-- Nothing stale: nothing selected.
	local quiet = State.new({ copy(byKey("acme/web#411")), copy(byKey("acme/web#401")) }, NOW, { tab = "mine", sort = "priority", folded = { inactive = false } })
	assert(State.markStale(quiet) == 0 and State.selection(quiet) == nil)
end

local function testConfirmState()
	local s = fresh()
	for _, key in Fixture.selectable do State.toggleMark(s, key) end
	State.setMerge(s, "acme/web", { method = { kind = "squash" }, source = "viewer", ask = false })
	State.setMerge(s, "acme/api", { method = { kind = "comment", command = "/merge", cancel = nil }, source = "declared", ask = false })
	State.setMerge(s, "acme/mono", { method = { kind = "queue" }, source = "declared", ask = false })
	local bar = State.selection(s)
	assert(bar and bar.count == 6 and bar.verb == "Merge" and bar.key == "M" and bar.confirm == nil)
	assert(State.askBatch(s, "ready") and s.mode == "confirm")
	local confirm = State.selection(s).confirm :: State.BatchConfirm
	assert(confirm.question == "Merge 6 pull requests?")
	assert(#confirm.rows == 5 and confirm.more == 1)
	assert(confirm.rows[1].ref == "web #401" and confirm.rows[1].title == byKey("acme/web#401").title)
	assert(join(confirm.lines) == "Squash and merge,Comments /merge,Adds to the merge queue")
	-- Cancel keeps the selection.
	State.cancelConfirm(s)
	assert(s.mode == "board" and State.selection(s).count == 6 and State.selection(s).confirm == nil)

	-- Closing: the one line about reopening.
	State.markStale(s)
	assert(State.askBatch(s, "inactive"))
	local close = State.selection(s).confirm :: State.BatchConfirm
	assert(close.question == "Close 3 pull requests?" and #close.rows == 3 and close.more == 0)
	assert(join(close.lines) == "Closed pull requests can be reopened.")
	-- X with the other group selected asks nothing.
	State.cancelConfirm(s)
	assert(not State.askBatch(s, "ready"))
end

-- A refresh drops marks that stopped being selectable, and keeps the rest.
local function testPrune()
	local s = fresh()
	State.toggleMark(s, "acme/web#401")
	State.toggleMark(s, "acme/api#402")
	for _, pr in s.prs do
		if pr.key == "acme/web#401" then pr.behind = true end
	end
	State.project(s)
	assert(markedKeys(s) == "acme/api#402")
	State.setTab(s, "review")
	assert(State.selection(s) == nil)
end

-- Three repos on three methods: argv in column order; a failure on the second stops the third.
local function testBatchArgv()
	local s = fresh()
	State.setMerge(s, "acme/web", { method = { kind = "rebase" }, source = "viewer", ask = false })
	State.setMerge(s, "acme/api", { method = { kind = "comment", command = "/merge", cancel = nil }, source = "declared", ask = false })
	State.setMerge(s, "acme/mono", { method = { kind = "queue" }, source = "declared", ask = false })
	for _, key in { "acme/web#401", "acme/api#402", "acme/mono#403" } do State.toggleMark(s, key) end
	local order: { string } = {}
	for _, card in State.markedCards(s) do table.insert(order, card.pr.key) end
	local expected = {
		{ "gh", "pr", "merge", "401", "--repo", "acme/web", "--rebase" },
		{ "gh", "pr", "comment", "402", "--repo", "acme/api", "--body", "/merge" },
		{ "gh", "pr", "merge", "403", "--repo", "acme/mono", "--auto" },
	}
	local function argvFor(card: State.Card): { string }
		local resolved = s.merges[card.pr.repo]
		return Github.commands.merge(card.pr, resolved.method).argv
	end

	-- All three run, each with its repo's method, in the column's order.
	local fake = FakeRunner.new({
		{ prefix = { "gh", "pr" }, reply = { stdout = "ok\n" } },
	})
	local client = Github.client(fake.run, function(): any return {} end)
	for _, card in State.markedCards(s) do
		local _, err = first(function(done) client.run(Github.commands.merge(card.pr, s.merges[card.pr.repo].method), done) end)
		assert(err == nil)
	end
	fake.expectOnly(3)
	for i, argv in expected do
		assert(join(fake.calls[i].argv) == join(argv), join(fake.calls[i].argv))
	end

	-- The second fails: the loop the block runs stops there, so the third never reaches the runner.
	local failing = FakeRunner.new({
		{ prefix = { "gh", "pr", "comment" }, reply = { status = 1, stderr = "GraphQL: Resource not accessible\n" } },
		{ prefix = { "gh", "pr" }, reply = { stdout = "ok\n" } },
	})
	local failClient = Github.client(failing.run, function(): any return {} end)
	local merged: { string } = {}
	local failed: string? = nil
	for _, card in State.markedCards(s) do
		local _, err = first(function(done) failClient.run(Github.commands.merge(card.pr, s.merges[card.pr.repo].method), done) end)
		if err then
			failed = card.pr.key
			break
		end
		table.insert(merged, card.pr.key)
	end
	failing.expectOnly(2)
	assert(failed == "acme/api#402" and join(merged) == "acme/web#401")
	assert(join(failing.calls[1].argv) == join(expected[1]) and join(failing.calls[2].argv) == join(expected[2]))
	assert(join(argvFor(State.card(s, "acme/mono#403") :: State.Card)) == join(expected[3]))
end

local function testClose()
	local command = Github.commands.close(byKey("acme/api#413"))
	assert(join(command.argv) == "gh,pr,close,413,--repo,acme/api" and command.stdin == nil)
	local fake = FakeRunner.new({ { prefix = { "gh", "pr", "close" }, reply = { stdout = "" } } })
	local client = Github.client(fake.run, function(): any return {} end)
	local _, err = first(function(done) client.run(command, done) end)
	assert(err == nil)
	fake.expectOnly(1)
end

return function()
	testConfirmList()
	testMethodLines()
	testRules()
	testMarking()
	testCloseStale()
	testConfirmState()
	testPrune()
	testBatchArgv()
	testClose()
end
