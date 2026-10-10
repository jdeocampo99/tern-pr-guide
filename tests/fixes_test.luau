--!strict
local Fixes = require("../src/hub/fixes")
local Github = require("../src/github")
local FakeRunner = require("./fake-runner")
local Fixture: any = require("../fixtures/hub/fixes")
local RawDetails: any = require("../fixtures/hub/raw-details")

local function ids(steps: { Fixes.Step }): string
	local out = {}
	for _, step in steps do table.insert(out, step.group .. ":" .. step.who .. "@" .. (step.path or "-") .. ":" .. tostring(step.line)) end
	return table.concat(out, " | ")
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

local function steps(kind: string): { Fixes.Step }
	return Fixes.steps(Fixture.details[kind], Fixture.prs[kind])
end

local function steps_()
	-- A requested change: the review's own words first, then its thread pinned at its line.
	local requested = steps("requested")
	assert(ids(requested) == "requested:@maria-k@-:nil | requested:@maria-k@src/cart/reprice.ts:57", ids(requested))
	assert(requested[1].review and requested[1].text == "Steps should skip removed lines; step 3 now points at a deleted line.")
	assert(requested[2].thread and requested[2].thread.replies == 2 and requested[2].thread.id == "PRRT_requested")

	-- A comment: pinned at its line; the outdated thread keeps its path with no line; resolved threads never arrive.
	assert(ids(steps("comment")) == "comment:@devon@src/cart/reprice.test.ts:12", ids(steps("comment")))
	local outdated = Fixes.steps(Fixture.details.outdated, Fixture.prs.comment)
	assert(ids(outdated) == "comment:@devon@src/cart/old.ts:nil" and outdated[1].thread.outdated)
	for _, thread in Fixture.details.requested.threads do assert(thread.id ~= "PRRT_done") end
	assert(#Fixture.details.requested.threads == 1)

	-- A bot's comment is no step; it is listed apart.
	assert(#steps("bot") == 0)
	local bots = Fixes.bots(Fixture.details.bot)
	assert(#bots == 1 and bots[1].author == "coderabbitai" and bots[1].count == 1)

	-- A failing check pins its first useful annotation; the .github one is dropped. A StatusContext has no annotations.
	local check = steps("check")
	assert(ids(check) == "check:typecheck@src/session/receipts.ts:42 | check:deploy/preview@-:nil", ids(check))
	assert(check[1].text == "Property 'id' does not exist on type 'Receipt'")
	assert(check[1].check and check[1].check.runId == 901 and check[1].check.workflow == "ci")
	assert(check[2].text == "Failed")

	-- Only noise annotations: the step stays, with no pin and the check's summary or "Failed".
	assert(ids(steps("noann")) == "check:build@-:nil", ids(steps("noann")))
	assert(ids(steps("noannReal")) == "check:fail@-:nil", ids(steps("noannReal")))
	assert(#Fixture.details.noannReal.checks[1].annotations == 2)
	assert(#Fixes.usable(Fixture.details.noannReal.checks[1].annotations) == 0)

	-- A conflict with no local copy keeps its step and the note; with git read it is one step per file.
	local noCopy = Fixture.details.conflict
	noCopy.conflictNote = "No local copy of jubbydev/tern-pr-guide-hub-smoke"
	local pending = Fixes.steps(noCopy, Fixture.prs.conflict)
	assert(ids(pending) == "conflict:Conflicts with main@-:nil", ids(pending))
	assert(pending[1].note == "No local copy of jubbydev/tern-pr-guide-hub-smoke")

	-- Merge failure alone: one note with the reason. Any other step replaces it.
	local failure = steps("failure")
	assert(#failure == 1 and failure[1].group == "failure" and failure[1].note == "Removed from the merge queue: a required check failed")
	local both = Fixes.steps(Fixture.details.check, Fixture.prs.failure)
	assert(both[1].group == "check" and #both == 2)

	-- Group order: requested, comments, checks, conflicts.
	local mixed = Fixture.details.requested
	local d = { key = mixed.key, headOid = "x", fetchedAt = "", reviews = {}, threads = Fixture.details.comment.threads, checks = Fixture.details.check.checks,
		changedPaths = {}, conflicts = { { path = "a.txt", cause = nil, hunks = {} } }, conflictNote = nil, files = nil }
	for _, thread in mixed.threads do table.insert(d.threads, thread) end
	local order = {}
	for _, step in Fixes.steps(d, Fixture.prs.conflict) do table.insert(order, step.group) end
	assert(table.concat(order, ",") == "requested,comment,check,check,conflict", table.concat(order, ","))

	local chips = Fixes.chips(Fixes.steps(d, Fixture.prs.conflict))
	assert(table.concat(chips, ",") == "Address changes,Reply,Fix checks,Resolve conflicts")
end

local function people_()
	-- The viewer's own thread on their PR is no step and no "Reply" chip (the recorded smoke #6 thread is by jubbydev).
	local own = Fixes.steps(Fixture.details.conflict, Fixture.prs.conflict)
	assert(#own == 1 and own[1].group == "conflict")
	for _, step in own do assert(step.group ~= "comment") end
	local chips = table.concat(Fixes.chips(own), ",")
	assert(chips == "Resolve conflicts", chips)
	-- A reviewer whose latest review approved leaves no step either; someone who only commented does.
	local pr = table.clone(Fixture.prs.comment)
	pr.reviews = table.clone(pr.reviews)
	pr.reviews.latest = { { author = "devon", bot = false, verdict = "approved", at = "", oid = "" } }
	assert(#Fixes.steps(Fixture.details.comment, pr) == 0)
	pr.reviews.latest = { { author = "devon", bot = false, verdict = "commented", at = "", oid = "" } }
	assert(#Fixes.steps(Fixture.details.comment, pr) == 1)
	-- The one predicate the board uses.
	local Model = require("../src/hub/model")
	assert(Model.threadCounts(Fixture.prs.comment, "devon", false) and not Model.threadCounts(Fixture.prs.comment, "devon", true))
	assert(not Model.threadCounts(Fixture.prs.comment, Fixture.prs.comment.author, false))
end

local function git_()
	-- Clean, one file and several files (a name listed twice counts once).
	local clean = Fixes.parseMergeTree(Fixture.cleanTree)
	assert(clean and #clean.files == 0 and clean.tree == "7784ba3f5f2f1938ff54bf80fa4ea308ee329c6c")
	local one = Fixes.parseMergeTree(Fixture.smokeTree)
	assert(one and #one.files == 1 and one.files[1] == "smoke/conflict.txt")
	local many = Fixes.parseMergeTree(Fixture.manyTree)
	assert(many and #many.files == 2 and many.files[1] == "src/session/receipts.ts" and many.files[2] == "src/session/store.ts")
	assert(Fixes.parseMergeTree("") == nil and Fixes.parseMergeTree("fatal: not a git repository") == nil)

	-- Hunks: the recorded diff3 output (the base section is skipped) and plain two-sided markers.
	local hunks = Fixes.parseHunks(Fixture.smokeShown)
	assert(#hunks == 1 and hunks[1].start == 1)
	assert(#hunks[1].branch == 1 and hunks[1].branch[1] == "branch side 1791575605")
	assert(#hunks[1].main == 1 and hunks[1].main[1] == "main side 1791575605")
	local twice = Fixes.parseHunks(Fixture.receiptsShown)
	assert(#twice == 2 and twice[1].start == 3 and #twice[1].branch == 2 and #twice[1].main == 2)
	assert(twice[2].start == 7 and twice[2].branch[1] == "  return [...store.receipts.values()];")
	assert(#Fixes.parseHunks("no markers\nat all\n") == 0)

	-- The causal main PR: "(#415)" in a squash subject, "Merge pull request #416", and none.
	local squash = Fixes.parseCause(Fixture.receiptsLog)
	assert(squash and squash.number == 415 and squash.author == "devon" and squash.title == "refactor(session): receipts keyed by coordinator")
	assert(squash.sha == "0123456789abcdef0123456789abcdef01234567")
	local merge = Fixes.parseCause(Fixture.mergeCommitLog)
	assert(merge and merge.number == 416)
	local plain = Fixes.parseCause(Fixture.smokeLog)
	assert(plain and plain.number == nil and plain.title == "Change a file the conflicted branch changes")
	assert(Fixes.parseCause("") == nil)

	-- The conflicts of a PR: files, blocks and causes together.
	local read = Fixture.gitRead.conflictMany
	local conflicts = Fixes.conflicts(Fixes.parseMergeTree(read.mergeTree) :: any, read.shown, read.logs)
	assert(#conflicts == 2 and conflicts[1].path == "src/session/receipts.ts" and #conflicts[1].hunks == 2)
	assert(conflicts[1].cause and conflicts[1].cause.number == 415 and conflicts[2].cause and conflicts[2].cause.number == 416)
	local d = Fixture.details.conflictMany
	d.conflicts = conflicts
	local list = Fixes.steps(d, Fixture.prs.conflictMany)
	assert(ids(list) == "conflict:receipts.ts@src/session/receipts.ts:3 | conflict:store.ts@src/session/store.ts:2", ids(list))
	assert(list[1].text == "· 2 conflicts" and list[2].text == "· 1 conflict")
end

local function excerpts_()
	-- A thread's diff hunk: numbered both sides, the commented line last.
	local rows = Fixes.hunkExcerpt(Fixture.details.requested.threads[1].hunk :: string)
	assert(rows and #rows.rows == 8 and rows.before == 50)
	local last = rows.rows[#rows.rows]
	assert(last.kind == "ctx" and last.new == 57 and last.text == "    items,")
	assert(rows.rows[3].kind == "del" and rows.rows[3].old == 53 and rows.rows[3].new == nil)
	assert(rows.rows[4].kind == "add" and rows.rows[4].new == 53 and rows.rows[4].old == nil)
	-- A hunk header with no counts, as GitHub writes a one-line change.
	local one = Fixes.hunkExcerpt(Fixture.details.conflict.threads[1].hunk :: string)
	assert(one and #one.rows == 2 and one.rows[1].kind == "del" and one.rows[1].old == 1 and one.rows[2].kind == "add" and one.rows[2].new == 1)
	assert(Fixes.hunkExcerpt("not a hunk") == nil)
	-- A file around an annotation's line.
	local text = ""
	for n = 1, 30 do text ..= "line " .. n .. "\n" end
	local file = Fixes.fileExcerpt(text, 12)
	assert(file and #file.rows == 11 and file.rows[1].new == 7 and file.rows[11].new == 17 and file.before == 6 and file.after == 13)
	local edge = Fixes.fileExcerpt(text, 2)
	assert(edge and edge.rows[1].new == 1 and edge.before == 0)
	assert(Fixes.fileExcerpt(text, 99) == nil)
end

local function commands_()
	local pr = Fixture.prs.conflict
	-- Details: one query, the PR's node id, one point in the recorded envelope.
	assert(RawDetails.conflict.data.rateLimit.cost == 1 and RawDetails.failing.data.rateLimit.cost == 1)
	local fake = FakeRunner.new({
		{ prefix = { "gh", "api", "graphql", "-f" }, contains = "id=" .. pr.id, reply = { stdout = "details" } },
	})
	local client = Github.client(fake.run, function(text: string): any
		if text == "details" then return RawDetails.conflict end
		error("invalid JSON", 0)
	end)
	local value, err = first(function(done) client.details(pr, done) end)
	assert(err == nil and value and value.key == pr.key and value.headOid == "c32b1c761911413bcbdba8f95f7f943c741a23be")
	assert(#value.threads == 1 and value.threads[1].group == "comment" and value.threads[1].path == "smoke/conflict.txt" and value.threads[1].line == 1)
	assert(value.threads[1].replies == 1 and value.threads[1].bot == false and value.changedPaths[1] == "smoke/conflict.txt")
	fake.expectOnly(1)
	local call = fake.calls[1].argv
	assert(#call == 7 and call[5]:find("query Details", 1, true) == 7 and call[6] == "-f" and call[7] == "id=" .. pr.id, table.concat(call, " "))
	assert(call[5]:find("annotations(first: 20)", 1, true) ~= nil)

	-- A failing check parses with its run id and workflow; a response without the node is an error value.
	local failing = Github.parseDetails(RawDetails.failing, Fixture.prs.noannReal) :: Fixes.FixDetails
	assert(#failing.checks == 1 and failing.checks[1].name == "fail" and failing.checks[1].runId == 37983327811 and failing.checks[1].workflow == "smoke-fail")
	assert(failing.checks[1].annotations[1].level == "failure" and failing.checks[1].annotations[1].line == 5 and failing.checks[1].annotations[1].title == nil)
	assert(failing.checks[1].annotations[2].level == "notice")
	assert(Github.parseDetails({ data = {} }, pr) == nil and Github.parseDetails("nope", pr) == nil)

	-- Reply and resolve: exact argv through the fake runner, the body sent as a field and never through a shell.
	local reply = Github.commands.reply(pr, "PRRT_kwDOVC46H86rCHsY", "Rebased.\nSee `main`.")
	assert(#reply.argv == 9 and reply.stdin == nil)
	assert(table.concat(reply.argv, " ", 1, 4) == "gh api graphql -f" and reply.argv[5]:find("^query=mutation%(%$threadId: ID!, %$body: String!%) { addPullRequestReviewThreadReply") ~= nil)
	assert(reply.argv[6] == "-f" and reply.argv[7] == "threadId=PRRT_kwDOVC46H86rCHsY" and reply.argv[8] == "-f" and reply.argv[9] == "body=Rebased.\nSee `main`.")
	local resolve = Github.commands.resolve("PRRT_kwDOVC46H86rCHsY")
	assert(#resolve.argv == 7 and resolve.argv[5]:find("^query=mutation%(%$threadId: ID!%) { resolveReviewThread") ~= nil)
	assert(resolve.argv[6] == "-f" and resolve.argv[7] == "threadId=PRRT_kwDOVC46H86rCHsY")

	local writes = FakeRunner.new({ { prefix = { "gh", "api", "graphql" }, reply = { stdout = '{"data":{}}' } } })
	local writer = Github.client(writes.run, function(): any return {} end)
	local out, failed = first(function(done) writer.run(reply, done) end)
	assert(failed == nil and out == '{"data":{}}')
	first(function(done) writer.run(resolve, done) end)
	writes.expectOnly(2)
	assert(writes.calls[1].argv[9] == "body=Rebased.\nSee `main`." and writes.calls[2].argv[7] == "threadId=PRRT_kwDOVC46H86rCHsY")

	-- A rejected write is an Error value naming the reason.
	local denied = FakeRunner.new({ { prefix = { "gh", "api", "graphql" }, reply = { status = 1, stderr = "gh: Resource not accessible\n" } } })
	local _, deniedErr = first(function(done) Github.client(denied.run, function(): any return {} end).run(resolve, done) end)
	assert(deniedErr and deniedErr.message == "Couldn't run gh api graphql: Resource not accessible", deniedErr and deniedErr.message)
end

local function logUrl_()
	local check = Fixture.details.check.checks[1]
	assert(Fixes.logUrl(check, "jdeocampo99/tandem") == "https://github.com/jdeocampo99/tandem/actions/runs/901")
	assert(Fixes.logUrl(Fixture.details.check.checks[2], "jdeocampo99/tandem") == "https://example.com/deploy/1")
end

return function()
	steps_()
	people_()
	git_()
	excerpts_()
	commands_()
	logUrl_()
end
