--!strict
local Fake = require("./fake-runner")
local Fixture: any = require("../fixtures/hub/flake")
local Github = require("../src/github")
local Cases: any = require("../fixtures/hub/cases")
local Model = require("../src/hub/model")
local State = require("../src/hub/state")

return function()
	-- Named thresholds.
	assert(Model.FLAKE_FAILED_MIN == 3 and Model.FLAKE_FAILED_MAX == 1 and Model.FLAKE_RUNS == 20)

	-- The acceptance matrix: every case, its verdict and its reason.
	for _, case in Fixture.cases do
		local verdict = Model.flake(Fixture.evidence(case))
		assert(verdict.flaky == case.flaky, case.row .. ": flaky")
		assert(verdict.basis == case.basis, case.row .. ": basis " .. tostring(verdict.basis))
		assert(verdict.reason == case.reason, case.row .. ": reason " .. tostring(verdict.reason))
	end

	-- The rule on bare evidence.
	local function evidence(patch: { [string]: any }): Model.FlakeEvidence
		local base: any = { history = nil, passedBefore = false, text = "", annotationPaths = {}, changedPaths = { "a.ts" } }
		for k, v in patch do base[k] = v end
		return base
	end
	assert(not Model.flake(evidence({ history = { failed = 2, total = 20 } })).flaky, "2 of 20 alone")
	assert(Model.flake(evidence({ history = { failed = 2, total = 20 }, passedBefore = true })).flaky, "2 of 20 and a pass before")
	assert(Model.flake(evidence({ history = { failed = 2, total = 20 }, text = "Error: ECONNRESET" })).flaky, "2 of 20 and infrastructure text")
	assert(Model.flake(evidence({ history = { failed = 2, total = 20 }, annotationPaths = { "b.ts" } })).flaky, "2 of 20 and errors outside the diff")
	assert(not Model.flake(evidence({ history = { failed = 1, total = 20 } })).flaky, "1 of 20")
	assert(not Model.flake(evidence({ history = { failed = 0, total = 0 } })).flaky, "no runs")
	local veto = Model.flake(evidence({ history = { failed = 9, total = 20 }, passedBefore = true, text = "timed out", annotationPaths = { "a.ts", "b.ts" } }))
	assert(not veto.flaky and veto.reason == "Error in a.ts, which this PR changed", "an annotation on a changed path is a veto")
	assert(Model.flake(evidence({ history = { failed = 4, total = 12 }, base = "develop" })).reason == "failed 4 of the last 12 runs on develop")
	assert(Model.flake(evidence({ text = "Killed\nProcess completed with exit code 137." })).reason == "the log shows out of memory (exit 137)")
	assert(not Model.flake(evidence({ text = "Type 'Timeout' is not assignable to type 'number'." })).flaky, "a type named Timeout is code")

	-- A card is flaky only when every failing check is.
	local yes: Model.FlakeVerdict = { flaky = true, basis = "text", reason = "x" }
	local no: Model.FlakeVerdict = { flaky = false, basis = nil, reason = nil }
	assert(Model.flakeAll({ yes, yes }).flaky and not Model.flakeAll({ yes, no }).flaky and not Model.flakeAll({}).flaky)

	-- Parsing runs: the recorded history of main has no failures; the busy one counts the newest 20 per workflow.
	local smoke = Fixture.history.smoke.byWorkflow
	assert(smoke.approve.failed == 0 and smoke.approve.total == 2)
	local busy = Fixture.history.busy.byWorkflow
	assert(busy.ci.failed == 3 and busy.ci.total == 20, "ci: 3 of the newest 20")
	assert(busy.e2e.failed == 1 and busy.e2e.total == 20)
	assert(busy.release.failed == 2 and busy.release.total == 4, "cancelled and skipped runs say nothing")
	assert(#Github.parseRuns({}) == 0 and #Github.parseRuns({ workflow_runs = { { id = 1 }, "x" } }) == 0)

	-- The re-run command.
	assert(table.concat(Github.commands.rerun("acme/web", 5107).argv, " ") == "gh run rerun 5107 --failed --repo acme/web")

	-- History and runs: one call each, exact argv; errors are values.
	local fake = Fake.new({
		{ prefix = { "gh", "api" }, contains = "runs?branch=main", reply = { stdout = "busy" } },
		{ prefix = { "gh", "api" }, contains = "runs?head_sha=", reply = { stdout = "rerun" } },
		{ prefix = { "gh", "run", "rerun" }, reply = { stdout = "" } },
	})
	local client = Github.client(fake.run, function(text: string): any
		if text == "busy" then return Fixture.rawBusy end
		return Fixture.rawRerun
	end)
	local got: Github.RepoHistory? = nil
	client.history("acme/web", "main", function(value, err)
		assert(err == nil)
		got = value
	end)
	assert(got and got.byWorkflow.ci.failed == 3 and got.base == "main")
	local rows: { Github.RunRow }? = nil
	client.runs("acme/web", string.rep("1", 40), function(value, err)
		assert(err == nil)
		rows = value
	end)
	assert(rows and #rows == 3)
	assert(table.concat(fake.calls[1].argv, " ") == "gh api repos/acme/web/actions/runs?branch=main&status=completed&per_page=100")
	assert(table.concat(fake.calls[2].argv, " ") == "gh api repos/acme/web/actions/runs?head_sha=" .. string.rep("1", 40) .. "&status=completed&per_page=50")
	local refused: string? = nil
	client.history("not a repo", "main", function(_, err) refused = err and err.message end)
	assert(refused == "Couldn't read recent runs of not a repo: not an owner/repo name")

	-- Cost: history is read once per repo per hour, also by callers that ask at the same time and after a failed read.
	local counted = Fake.new({ { prefix = { "gh", "api" }, reply = { stdout = "busy" } } })
	local cache = Github.historyCache(Github.client(counted.run, function(): any return Fixture.rawBusy end))
	local seen = 0
	for _, at in { 1000, 1000, 1500, 4599, 4600 } do
		cache.read("acme/web", "main", at, function(value) seen += if value and value.byWorkflow.ci.failed == 3 then 1 else 0 end)
	end
	assert(#counted.calls == 2 and seen == 5, "two reads: at 1000 and again an hour later")
	cache.read("acme/api", "main", 4600, function() end)
	assert(#counted.calls == 3, "another repo is its own read")
	local broken = Fake.new({ { prefix = { "gh", "api" }, reply = { status = 1, stderr = "gh: HTTP 502" } } })
	local retry = Github.historyCache(Github.client(broken.run, function(): any return nil end))
	local answered = 0
	for _, at in { 10, 20 } do retry.read("acme/web", "main", at, function(value) answered += if value == nil then 1 else 0 end) end
	assert(#broken.calls == 1 and answered == 2, "a failed read is not retried inside the hour")

	-- Re-run: the argv, once per press.
	local done = 0
	client.run(Github.commands.rerun("acme/web", 5107), function(_, err)
		assert(err == nil)
		done += 1
	end)
	assert(done == 1 and #fake.calls == 3)
	assert(table.concat(fake.calls[3].argv, " ") == "gh run rerun 5107 --failed --repo acme/web")

	-- A rate-limited history is an error value.
	local limited = Fake.new({ { prefix = { "gh", "api" }, reply = { status = 1, stderr = "gh: API rate limit exceeded for user" } } })
	local reason: string? = nil
	Github.client(limited.run, function(): any return nil end).history("acme/web", "main", function(_, err) reason = err and err.message end)
	assert(reason == "Couldn't read recent runs of acme/web: GitHub's rate limit is reached", tostring(reason))

	-- No automatic rerun: refreshing and reading the evidence of every flaky fixture never sends `rerun`.
	local quiet = Fake.new({
		{ prefix = { "gh", "api" }, reply = { stdout = "busy" } },
	})
	local reader = Github.client(quiet.run, function(): any return Fixture.rawBusy end)
	for _, case in Fixture.cases do
		local verdict = Model.flake(Fixture.evidence(case))
		if verdict.flaky then
			reader.history("acme/web", "main", function() end)
			reader.runs("acme/web", string.rep("1", 40), function() end)
		end
	end
	for _, call in quiet.calls do
		assert(table.find(call.argv, "rerun") == nil, "nothing re-runs by itself")
	end

	-- The card: Re-run failed checks is behind Fix checks ▾ on every failing check, first only when the evidence says flaky.
	local s = State.new(Cases.prs, Cases.asOf, nil)
	local card = State.card(s, "acme/web#111") :: State.Card
	assert((card.main :: State.CardAction).label == "Fix with agent" and card.flake == nil)
	assert(#card.more == 1 and card.more[1].act == "card-rerun" and card.more[1].label == "Re-run failed checks" and card.more[1].key == "⇧R")
	local head = (State.prOf(s, "acme/web#111") :: Model.HubPR).headOid
	State.setFlake(s, "acme/web#111", { flaky = true, reason = "failed 3 of the last 20 runs on main", runs = { 5107 }, headOid = head })
	card = State.card(s, "acme/web#111") :: State.Card
	assert((card.main :: State.CardAction).act == "card-rerun" and (card.main :: State.CardAction).key == "⇧R")
	assert(card.more[1].label == "Fix with agent" and card.more[1].key == "A" and #card.more == 1)
	assert(card.flake == "Likely flaky: failed 3 of the last 20 runs on main")
	State.setFlake(s, "acme/web#111", { flaky = false, reason = "Error in a.ts, which this PR changed", runs = { 5107 }, headOid = head })
	card = State.card(s, "acme/web#111") :: State.Card
	assert((card.main :: State.CardAction).label == "Fix with agent" and card.flake == nil, "a real failure is not labelled")
	State.setFlake(s, "acme/web#111", { flaky = true, reason = "x", runs = { 1 }, headOid = "old" })
	card = State.card(s, "acme/web#111") :: State.Card
	assert((card.main :: State.CardAction).label == "Fix with agent" and card.flake == nil and State.flakeOf(s, "acme/web#111") == nil, "evidence for an older commit is ignored")
	-- Flaky checks beside a conflict: the agent stays first, the re-run is in the menu.
	local both = State.prOf(s, "acme/api#112") :: Model.HubPR
	State.setFlake(s, both.key, { flaky = true, reason = "x", runs = { 1 }, headOid = both.headOid })
	local mixed = State.card(s, both.key) :: State.Card
	assert((mixed.main :: State.CardAction).label == "Fix with agent" and mixed.more[#mixed.more].act == "card-rerun")
	-- Feedback alone has no failing check, so no re-run: only Summarize is behind the agent.
	local feedback = State.card(s, "acme/web#103") :: State.Card
	assert(#feedback.more == 1 and feedback.more[1].act == "card-summarize" and feedback.more[1].key == "⇧A")
end
