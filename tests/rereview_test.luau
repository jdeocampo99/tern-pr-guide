--!strict
local FakeRunner = require("./fake-runner")
local Github = require("../src/github")
local Model = require("../src/hub/model")
local State = require("../src/hub/state")
local Fixture: any = require("../fixtures/hub/rereview")

local NOW: number = Fixture.asOf

local function acts(list: { State.CardAction }): string
	local out = {}
	for _, a in list do table.insert(out, a.act) end
	return table.concat(out, ",")
end

local function run(command: Github.Command): FakeRunner.Fake
	local fake = FakeRunner.new({ { prefix = { "gh" }, reply = { stdout = "" } } })
	local client = Github.client(fake.run, function(text: string): any return text end)
	local called = false
	client.run(command, function(_, err)
		called = true
		assert(err == nil, "command failed")
	end)
	assert(called, "callback never fired")
	fake.expectOnly(1)
	return fake
end

local function argv(fake: FakeRunner.Fake): string
	return table.concat(fake.calls[1].argv, " ")
end

return function()
	assert(Fixture.asOf == Model.epoch(Fixture.asOfIso), "asOf matches asOfIso")

	-- The board: each case's column, chip text, note and actions.
	local s = State.new(Fixture.prs, NOW, nil)
	for repo, resolution in Fixture.merges do s.merges[repo] = resolution end
	for repo, allowed in Fixture.autoMerge do s.autoMerge[repo] = allowed end
	State.project(s)
	for key, want in Fixture.expect do
		local card = State.card(s, key)
		assert(card ~= nil, key .. ": no card")
		assert(card.column == want.column, key .. " column " .. card.column)
		if want.chip then
			assert(card.chips[1] ~= nil and card.chips[1].text == want.chip, key .. " chip " .. (if card.chips[1] then card.chips[1].text else "none"))
		end
		assert(card.note == want.note, key .. " note " .. tostring(card.note))
		if want.main then
			assert(card.main ~= nil and card.main.act == want.main, key .. " main " .. (if card.main then card.main.act else "none"))
			assert(acts(card.more) == want.more, key .. " more " .. acts(card.more))
		end
	end

	-- "Waiting on ... to re-review" only where the reviewer's changes were answered by a push.
	for _, pr in Fixture.prs do
		local card = State.card(s, pr.key) :: State.Card
		local waiting = false
		for _, chip in card.chips do
			if string.find(chip.text, "to re-review", 1, true) then waiting = true end
		end
		local want = Fixture.expect[pr.key]
		assert(waiting == (want.chip ~= nil and string.find(want.chip, "re-review", 1, true) ~= nil), pr.key .. " waiting text")
	end

	-- The pure rule.
	local function pr(key: string): Model.HubPR
		for _, p in Fixture.prs do
			if p.key == key then return p end
		end
		error(key)
	end
	local again = Model.awaitingReReview(pr("acme/web#201")) :: Model.ReReview
	assert(table.concat(again.waiting, ",") == "maria-k" and table.concat(again.ask, ",") == "maria-k")
	assert(Model.awaitingReReview(pr("acme/web#202")) == nil, "not pushed")
	assert(Model.awaitingReReview(pr("acme/web#203")) == nil, "approved after the push")
	assert(table.concat((Model.awaitingReReview(pr("acme/web#204")) :: Model.ReReview).waiting, ",") == "maria-k", "only the reviewer who still asks")
	local asked = Model.awaitingReReview(pr("acme/web#208")) :: Model.ReReview
	assert(#asked.waiting == 1 and #asked.ask == 0, "already asked again")
	assert(Model.reviewerList({ "a" }) == "@a" and Model.reviewerList({ "a", "b" }) == "@a and @b")
	assert(Model.placement(pr("acme/web#201"), NOW).column == "in_review")
	assert(Model.placement(pr("acme/web#202"), NOW).column == "needs_fixes")

	-- Merge when ready is offered where the setting allows it, and hidden where it doesn't or isn't known.
	local viewer: Model.MergeResolution = { method = { kind = "squash" }, source = "viewer", ask = false }
	assert(Model.canMergeWhenReady(viewer, true))
	assert(not Model.canMergeWhenReady(viewer, false), "auto-merge off")
	assert(not Model.canMergeWhenReady(viewer, nil), "not read yet")
	assert(not Model.canMergeWhenReady(nil, nil))
	assert(Model.canMergeWhenReady({ method = { kind = "queue" }, source = "declared", ask = false }, true))
	local comment: Model.MergeResolution = { method = { kind = "comment", command = "/merge", cancel = nil }, source = "declared", ask = false }
	assert(Model.canMergeWhenReady(comment, false), "a comment method needs no setting")
	assert(not Model.canMergeWhenReady({ method = comment.method, source = "learned", ask = true }, true), "a suggestion is asked on Ready first")

	-- Commands: exact argv, run through the fake runner, nothing else.
	local squash = { kind = "squash" } :: Model.MergeMethod
	assert(argv(run(Github.commands.autoMerge(pr("acme/web#201"), squash))) == "gh pr merge 201 --repo acme/web --auto --squash")
	assert(argv(run(Github.commands.autoMerge(pr("acme/web#201"), { kind = "rebase" }))) == "gh pr merge 201 --repo acme/web --auto --rebase")
	assert(argv(run(Github.commands.autoMerge(pr("acme/web#201"), { kind = "merge" }))) == "gh pr merge 201 --repo acme/web --auto --merge")
	assert(argv(run(Github.commands.autoMerge(pr("acme/web#201"), { kind = "queue" }))) == "gh pr merge 201 --repo acme/web --auto")
	assert(argv(run(Github.commands.autoMerge(pr("acme/aviator#207"), comment.method))) == "gh pr comment 207 --repo acme/aviator --body /merge")
	assert(argv(run(Github.commands.autoMerge(pr("acme/web#201"), { kind = "label", label = "ready" }))) == "gh pr edit 201 --repo acme/web --add-label ready")
	assert(argv(run(Github.commands.cancelMerge(pr("acme/web#205"), { kind = "queue" }))) == "gh pr merge 205 --repo acme/web --disable-auto")
	local aviator = Fixture.merges["acme/aviator"].method
	assert(argv(run(Github.commands.cancelMerge(pr("acme/aviator#207"), aviator))) == "gh pr comment 207 --repo acme/aviator --body /aviator cancel")
	assert(argv(run(Github.commands.requestReview(pr("acme/web#201"), "maria-k"))) == "gh pr edit 201 --repo acme/web --add-reviewer maria-k")
	assert(argv(run(Github.commands.requestReview(pr("acme/web#209"), "maria-k,devon,lee"))) == "gh pr edit 209 --repo acme/web --add-reviewer maria-k,devon,lee")

	-- Asking again shows at once: no second Re-request review on the card.
	State.reRequested(s, "acme/web#201", { "maria-k" })
	local after = State.card(s, "acme/web#201") :: State.Card
	assert(after.main ~= nil and after.main.act == "card-copy", "main goes back to Copy link")
	assert(after.chips[1].text == "Waiting on @maria-k to re-review")

	-- Detection: the repo's setting comes from merge-detect's autoMergeAllowed.
	local on = Github.parseDetect({ data = { repository = { autoMergeAllowed = true } } }) :: Github.Detected
	local off = Github.parseDetect({ data = { repository = { autoMergeAllowed = false } } }) :: Github.Detected
	assert(on.autoMergeAllowed and not off.autoMergeAllowed)
end
