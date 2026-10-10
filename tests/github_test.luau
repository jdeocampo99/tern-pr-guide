--!strict
local Github = require("../src/github")
local FakeRunner = require("./fake-runner")
local Cases: any = require("../fixtures/hub/cases")
local RawHub: any = require("../fixtures/hub/raw-hub-f")
local RawThreads: any = require("../fixtures/hub/raw-threads")
local RawChecks: any = require("../fixtures/hub/raw-checks")

local COST_LIMIT = 18
local BASE = { "gh", "api", "graphql", "-f" }

local byKey: { [string]: any } = {}
for _, pr in Cases.prs do byKey[pr.key] = pr end

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

-- Response bodies are tables here (`luau` has no JSON), so stdout is a name and `decode` looks it up.
local function decoder(bodies: { [string]: any }): Github.Decode
	return function(text: string): any
		local body = bodies[text]
		if body == nil then error("invalid JSON", 0) end
		return body
	end
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

local function hubEntry(reply: FakeRunner.Reply): FakeRunner.Entry
	return { prefix = BASE, contains = "query Hub(", reply = reply }
end
local function threadsEntry(reply: FakeRunner.Reply): FakeRunner.Entry
	return { prefix = BASE, contains = "query Threads(", reply = reply }
end
local function checksEntry(reply: FakeRunner.Reply): FakeRunner.Entry
	return { prefix = BASE, contains = "query Checks(", reply = reply }
end

local BODIES = { ["hub-f"] = RawHub, threads = RawThreads, checks = RawChecks }
local function fixtureClient(extra: { FakeRunner.Entry }?): (Github.Client, FakeRunner.Fake)
	local script: { FakeRunner.Entry } = {
		hubEntry({ stdout = "hub-f" }), threadsEntry({ stdout = "threads" }), checksEntry({ stdout = "checks" }),
	}
	for _, entry in extra or {} do table.insert(script, 1, entry) end
	local fake = FakeRunner.new(script)
	return Github.client(fake.run, decoder(BODIES)), fake
end

local function ids(prs: { any }): { string }
	local out = {}
	for _, pr in prs do table.insert(out, pr.id) end
	return out
end

local function testParsers()
	-- hub-f: 20 PRs from the three searches, the PR in two searches once.
	local hub = Github.parseHub(RawHub) :: any
	assert(hub.viewer == "jubbydev" and hub.viewer == Cases.viewer)
	assert(#hub.prs == 20)
	assert(hub.truncated == false)
	assert(hub.rateLimit.cost == RawHub.data.rateLimit.cost and hub.rateLimit.limit == 5000)
	assert(hub.rateLimit.resetAt == RawHub.data.rateLimit.resetAt)
	local parsed: { [string]: any } = {}
	for _, pr in hub.prs do parsed[pr.key] = pr end

	-- Threads are not in hub-f: a PR with unresolved threads is unknown until threads.graphql runs.
	local withThreads = {}
	for key, pr in parsed do
		if pr.reviews.unresolved == 0 then
			same(pr, byKey[key], key)
		else
			assert(pr.reviews.threadsKnown == false and #pr.reviews.threads == 0, key)
			withThreads[key] = true
		end
	end
	assert(next(withThreads) ~= nil)
	-- Includes the cases the issue names: size, dates, queue removal.
	assert(parsed["acme/web#101"].additions == 40 and parsed["acme/web#101"].deletions == 10)
	assert(parsed["acme/web#101"].createdAt == "2026-09-30T00:00:00Z")
	assert(parsed["acme/web#101"].mergeFailure.kind == "queue")
	assert(parsed["acme/web#101"].mergeFailure.reason == "Removed from the merge queue: a required check failed")
	-- The unread-threads case is exactly the case record.
	same(parsed["acme/api#120"], byKey["acme/api#120"], "120")

	-- threads: keyed by node id; resolved threads and the PRs without any are left out.
	local threads = Github.parseThreads(RawThreads) :: any
	assert(threads.rateLimit.cost == RawThreads.data.rateLimit.cost and threads.rateLimit.limit == 5000)
	same(threads.threads, {
		["PR_acme/api#106"] = { { author = "copilot-bot", bot = true } },
		["PR_acme/api#108"] = { { author = "alice", bot = false } },
		["PR_acme/api#118"] = { { author = "dave", bot = false } },
		["PR_acme/api#119"] = { { author = "erin", bot = false } },
		["PR_acme/api#120"] = { { author = "frank", bot = false }, { author = "frank", bot = false } },
		["PR_acme/api#121"] = { { author = "jubbydev", bot = false } },
	}, "threads")
	-- With their threads, every recorded PR equals its case record.
	for key, pr in parsed do
		local open = threads.threads[pr.id]
		if open then
			pr.reviews.threads = open
			pr.reviews.threadsKnown = true
			if key ~= "acme/api#120" then same(pr, byKey[key], key) end
		end
	end
	assert(#parsed["acme/api#120"].reviews.threads == 2)

	-- checks: keyed by node id, with the head commit the counts belong to.
	local checks = Github.parseChecks(RawChecks) :: any
	assert(checks.rateLimit.cost == RawChecks.data.rateLimit.cost)
	same(checks.byId, {
		["PR_acme/web#104"] = { headOid = "head104", checks = { state = "failing", passing = 3, failing = 1, pending = 0 } },
		["PR_acme/api#114"] = { headOid = "head114", checks = { state = "pending", passing = 2, failing = 0, pending = 1 } },
		["PR_acme/api#108"] = { headOid = "head108", checks = { state = "passing", passing = 4, failing = 0, pending = 0 } },
		["PR_acme/api#109"] = { headOid = "head109", checks = { state = "none", passing = 0, failing = 0, pending = 0 } },
	}, "checks")

	-- probe: `gh api -i`, 200 or 304.
	same(Github.parseProbe("HTTP/2.0 200 OK\r\nLast-Modified: Fri, 09 Oct 2026 19:00:00 GMT\r\nX-Poll-Interval: 60\r\n\r\n[]"),
		{ changed = true, lastModified = "Fri, 09 Oct 2026 19:00:00 GMT", pollSeconds = 60 }, "probe 200")
	same(Github.parseProbe("HTTP/2.0 304 Not Modified\nlast-modified: Fri, 09 Oct 2026 19:00:00 GMT\nx-poll-interval: 120\n\n"),
		{ changed = false, lastModified = "Fri, 09 Oct 2026 19:00:00 GMT", pollSeconds = 120 }, "probe 304")
	same(Github.parseProbe("HTTP/2.0 200 OK\n\n"), { changed = true }, "probe bare")
	assert(Github.parseProbe("HTTP/2.0 404 Not Found\n\n") == nil)
	assert(Github.parseProbe("") == nil)
end

local function testParsersNeverThrow()
	for _, raw in { {}, { data = {} }, { data = { viewer = {} } }, { data = "x" }, "x", 7, false } do
		assert(Github.parseHub(raw) == nil)
		assert(Github.parseThreads(raw) == nil)
		assert(Github.parseChecks(raw) == nil)
	end
	assert(Github.parseHub(nil) == nil and Github.parseThreads(nil) == nil and Github.parseChecks(nil) == nil)
	-- Missing fields: the PR without an id is skipped, the rest default.
	local hub = Github.parseHub({ data = { viewer = { login = "me" }, mine = { nodes = {
		{}, { id = "a" }, "x",
		{ id = "PR_1", number = 1, repository = { nameWithOwner = "o/r" } },
	} } } }) :: any
	assert(#hub.prs == 1 and hub.prs[1].key == "o/r#1" and hub.prs[1].role == "mine")
	assert(hub.prs[1].author == "ghost" and hub.prs[1].checks.state == "none" and hub.prs[1].reviews.decision == "none")
	assert(hub.rateLimit.cost == 0)
end

local function testSearchesAndAliases()
	local function node(id: string, author: string)
		return { id = id, number = 5, repository = { nameWithOwner = "o/r" }, author = { __typename = "User", login = author } }
	end
	local hub = Github.parseHub({ data = {
		viewer = { login = "me" },
		requested = { nodes = { node("A", "x") }, pageInfo = { hasNextPage = true } },
		mine = { nodes = { node("A", "x") } },
		added1 = { pullRequest = node("C", "me") },
		added0 = { pullRequest = node("B", "y") },
		added2 = {},
	} }) :: any
	-- A PR found by "mine" is mine even if another search saw it first; an added PR is the viewer's only if they wrote it.
	local roles = {}
	for _, pr in hub.prs do roles[pr.id] = pr.role end
	assert(#hub.prs == 3 and roles.A == "mine" and roles.B == "review" and roles.C == "mine")
	assert(hub.prs[2].id == "B" and hub.prs[3].id == "C", "added PRs in alias order")
	assert(hub.truncated == true)
	-- Auto-merge asked for again after the queue removal is not a failure; asked for before is.
	local function failing(auto: any): any
		local out = Github.parseHub({ data = { viewer = { login = "me" }, mine = { nodes = { {
			id = "A", number = 1, repository = { nameWithOwner = "o/r" }, autoMergeRequest = auto,
			timelineItems = { nodes = { { createdAt = "2026-10-08T09:00:00Z", reason = "Required status check failed" } } },
		} } } } }) :: any
		return out.prs[1].mergeFailure
	end
	assert(failing(nil).reason == "Removed from the merge queue: required status check failed")
	assert(failing({ enabledAt = "2026-10-08T08:00:00Z" }) ~= nil)
	assert(failing({ enabledAt = "2026-10-08T10:00:00Z" }) == nil)
end

local function testRefresh()
	local client, fake = fixtureClient()
	local value, err = first(function(done) client.refresh({ added = {}, previous = {} }, done) end)
	assert(err == nil, "refresh failed")
	-- The hub-f request: one gh call, the query as its fifth argument, no thread authors in it.
	local hubCall = fake.calls[1]
	assert(#hubCall.argv == 5 and hubCall.stdin == nil and hubCall.cwd == nil)
	for i, word in BASE do assert(hubCall.argv[i] == word) end
	local query = hubCall.argv[5]
	assert(string.sub(query, 1, 17) == "query=query Hub($")
	assert(string.find(query, "reviewThreads(first: 100) { totalCount nodes { isResolved } }", 1, true) ~= nil)
	assert(not string.find(query, "isResolved comments", 1, true), "hub-f must not select thread authors")
	assert(not string.find(query, "comments(first", 1, true), "hub-f must not select thread comments")
	-- Threads only for PRs with an unresolved thread, none of which is cached.
	local expected = { "PR_acme/api#106", "PR_acme/api#108", "PR_acme/api#118", "PR_acme/api#119", "PR_acme/api#120", "PR_acme/api#121" }
	local threadsCall = fake.calls[2]
	assert(#threadsCall.argv == 5 + 2 * #expected and threadsCall.stdin == nil and threadsCall.cwd == nil)
	assert(string.sub(threadsCall.argv[5], 1, 21) == "query=query Threads($")
	for i, id in expected do
		assert(threadsCall.argv[4 + 2 * i] == "-f" and threadsCall.argv[5 + 2 * i] == "ids[]=" .. id)
	end
	fake.expectOnly(2)

	assert(value.viewer == "jubbydev" and #value.prs == 20 and value.partial == nil and value.truncated == false)
	assert(#value.calls == 2 and value.rateLimit == value.calls[2])
	for _, pr in value.prs do
		if pr.key ~= "acme/api#120" then same(pr, byKey[pr.key], pr.key) end
	end
	assert(#value.prs[1].key > 0)

	-- The summed cost of a full refresh, from the fixtures' own envelopes.
	local checksClient, checksFake = fixtureClient()
	local update, checksErr = first(function(done) checksClient.checks({ "PR_acme/web#104", "PR_acme/api#114" }, done) end)
	assert(checksErr == nil)
	local total = update.rateLimit.cost
	for _, call in value.calls do total += call.cost end
	assert(total == RawHub.data.rateLimit.cost + RawThreads.data.rateLimit.cost + RawChecks.data.rateLimit.cost)
	assert(total <= COST_LIMIT, "a refresh costs " .. total .. " points, the limit is " .. COST_LIMIT)
	assert(update.byId["PR_acme/web#104"].checks.state == "failing")
	-- checks: one query, the ids as array fields.
	local call = checksFake.calls[1]
	assert(#call.argv == 9 and call.stdin == nil and call.cwd == nil)
	assert(string.sub(call.argv[5], 1, 21) == "query=query Checks($i")
	assert(call.argv[6] == "-f" and call.argv[7] == "ids[]=PR_acme/web#104" and call.argv[8] == "-f" and call.argv[9] == "ids[]=PR_acme/api#114")
	checksFake.expectOnly(1)

	-- Nothing changed since the last refresh: hub-f alone, no threads call (a threads call would be unmatched).
	local onlyHub = FakeRunner.new({ hubEntry({ stdout = "hub-f" }) })
	local cached = Github.client(onlyHub.run, decoder(BODIES))
	local again, againErr = first(function(done) cached.refresh({ added = {}, previous = value.prs }, done) end)
	assert(againErr == nil and #again.calls == 1)
	onlyHub.expectOnly(1)
	same(again.prs[11].reviews.threads, value.prs[11].reviews.threads, "cached threads")
	for _, pr in again.prs do
		if pr.key ~= "acme/api#120" then same(pr, byKey[pr.key], pr.key) end
	end

	-- One PR got activity: its threads, and only its threads, are read again.
	local previous = clone(value.prs)
	for _, pr in previous do
		if pr.key == "acme/api#119" or pr.key == "acme/web#101" then pr.lastActivityAt = "2026-01-01T00:00:00Z" end
	end
	local oneThread = FakeRunner.new({ hubEntry({ stdout = "hub-f" }), threadsEntry({ stdout = "threads" }) })
	local changed = Github.client(oneThread.run, decoder(BODIES))
	local _, changedErr = first(function(done) changed.refresh({ added = {}, previous = previous }, done) end)
	assert(changedErr == nil)
	oneThread.expectOnly(2)
	assert(#oneThread.calls[2].argv == 7 and oneThread.calls[2].argv[7] == "ids[]=PR_acme/api#119", "only #119 has threads and changed")

	-- Added by link: one alias per valid, distinct PR, ahead of the fragment.
	local added, addedFake = fixtureClient()
	first(function(done)
		added.refresh({ added = {
			{ repo = "acme/web", number = 999 }, { repo = "ACME/web", number = 999 },
			{ repo = "no spaces/x y", number = 1 }, { repo = "acme/api", number = 0 }, { repo = "acme/api", number = 12 },
		}, previous = {} }, done)
	end)
	local aliased = addedFake.calls[1].argv[5]
	assert(string.find(aliased, '  added0: repository(owner: "acme", name: "web") { pullRequest(number: 999) { ...Hub } }\n  added1: repository(owner: "acme", name: "api") { pullRequest(number: 12) { ...Hub } }\n}\n\nfragment Hub on PullRequest {', 1, true) ~= nil)
	assert(not string.find(aliased, "added2", 1, true))
end

local function testPartialThreadsFailure()
	local fake = FakeRunner.new({
		threadsEntry({ status = 1, stderr = "gh: HTTP 502: Bad Gateway\n" }), hubEntry({ stdout = "hub-f" }),
	})
	local client = Github.client(fake.run, decoder(BODIES))
	local value, err = first(function(done) client.refresh({ added = {}, previous = {} }, done) end)
	assert(err == nil and #value.prs == 20 and #value.calls == 1)
	assert(value.partial.message == "Couldn't read review threads: HTTP 502: Bad Gateway")
	assert(value.partial.operation == "gh api graphql: threads")
	for _, pr in value.prs do
		assert(pr.reviews.threadsKnown == (pr.reviews.unresolved == 0), pr.key)
	end
end

local function testErrors()
	local limited = {
		errors = { { type = "RATE_LIMITED", message = "API rate limit already exceeded for user ID 1." } },
	}
	local limitedWithEnvelope = {
		data = { rateLimit = { cost = 0, remaining = 0, limit = 5000, resetAt = "2026-10-09T20:00:00Z" } },
		errors = limited.errors,
	}
	local bodies = { limited = limited, envelope = limitedWithEnvelope, array = { 1, 2 }, empty = {}, noviewer = { data = {} } }
	local function refreshWith(reply: FakeRunner.Reply): (any, any, FakeRunner.Fake)
		local fake = FakeRunner.new({ { prefix = { "gh" }, reply = reply } })
		local client = Github.client(fake.run, decoder(bodies))
		local value, err = first(function(done) client.refresh({ added = {}, previous = {} }, done) end)
		return value, err, fake
	end

	-- A runner that fails.
	local value, err = refreshWith({ status = 1, stderr = "gh: HTTP 502: Bad Gateway\n" })
	assert(value == nil and err.message == "Couldn't refresh pull requests: HTTP 502: Bad Gateway")
	assert(err.operation == "gh api graphql: hub" and err.rateLimit == nil)
	value, err = refreshWith({ status = 4, stderr = "" })
	assert(err.message == "Couldn't refresh pull requests: gh exited with status 4")
	value, err = refreshWith({ status = -1, timed_out = true })
	assert(value == nil and err.message == "Couldn't refresh pull requests: timed out")
	-- A runner that throws is an Error too, not a throw.
	local silent = FakeRunner.new({})
	local silentClient = Github.client(silent.run, decoder(bodies))
	value, err = first(function(done) silentClient.refresh({ added = {}, previous = {} }, done) end)
	assert(value == nil and string.sub(err.message, 1, 35) == "Couldn't refresh pull requests: fak")
	assert(#silent.unmatched == 1)

	-- A malformed body.
	for _, stdout in { "not json", "", "array", "empty", "noviewer" } do
		value, err = refreshWith({ stdout = stdout })
		assert(value == nil, stdout)
		assert(string.sub(err.message, 1, 31) == "Couldn't refresh pull requests:", stdout)
	end
	value, err = refreshWith({ stdout = "not json" })
	assert(err.message == "Couldn't refresh pull requests: GitHub sent a response that isn't JSON data")
	value, err = refreshWith({ stdout = "noviewer" })
	assert(err.message == "Couldn't refresh pull requests: GitHub sent a response without the viewer")

	-- A rate-limited response: in the body, in the body with its envelope, and on stderr alone.
	value, err = refreshWith({ status = 1, stdout = "limited" })
	assert(value == nil and err.message == "Couldn't refresh pull requests: GitHub's rate limit is reached" and err.rateLimit == nil)
	value, err = refreshWith({ status = 1, stdout = "envelope" })
	assert(err.message == "Couldn't refresh pull requests: GitHub's rate limit is reached, resets at 2026-10-09T20:00:00Z")
	assert(err.rateLimit.remaining == 0 and err.rateLimit.limit == 5000 and err.rateLimit.resetAt == "2026-10-09T20:00:00Z")
	value, err = refreshWith({ status = 1, stderr = "gh: API rate limit exceeded for user ID 1. (HTTP 403)" })
	assert(err.message == "Couldn't refresh pull requests: GitHub's rate limit is reached")

	-- The other calls fail the same way, with their own wording.
	local fake = FakeRunner.new({ { prefix = { "gh" }, reply = { status = 1, stderr = "gh: boom" } } })
	local client = Github.client(fake.run, decoder(bodies))
	value, err = first(function(done) client.checks({ "A" }, done) end)
	assert(value == nil and err.message == "Couldn't read checks: boom" and err.operation == "gh api graphql: checks")
	value, err = first(function(done) client.probe(nil, done) end)
	assert(value == nil and err.message == "Couldn't check for changes: boom" and err.operation == "gh api: notifications")
	value, err = first(function(done) client.run({ argv = { "gh", "pr", "merge", "7" } }, done) end)
	assert(value == nil and err.message == "Couldn't run gh pr merge: boom" and err.operation == "gh pr merge")
end

local function testProbeAndRun()
	local reply: { FakeRunner.Entry } = {
		{ prefix = { "gh", "api", "-i", "notifications?per_page=1", "-H" }, reply = { status = 1, stdout = "HTTP/2.0 304 Not Modified\r\nX-Poll-Interval: 60\r\n\r\n" } },
		{ prefix = { "gh", "api", "-i", "notifications?per_page=1" }, reply = { stdout = "HTTP/2.0 200 OK\r\nLast-Modified: Fri, 09 Oct 2026 19:00:00 GMT\r\n\r\n[]" } },
	}
	local fake = FakeRunner.new(reply)
	local client = Github.client(fake.run, decoder({}))
	local value, err = first(function(done) client.probe(nil, done) end)
	assert(err == nil and value.changed == true and value.lastModified == "Fri, 09 Oct 2026 19:00:00 GMT")
	value, err = first(function(done) client.probe("Fri, 09 Oct 2026 19:00:00 GMT", done) end)
	assert(err == nil and value.changed == false and value.pollSeconds == 60)
	fake.expectOnly(2)
	same(fake.calls[1].argv, { "gh", "api", "-i", "notifications?per_page=1" }, "probe argv")
	same(fake.calls[2].argv, { "gh", "api", "-i", "notifications?per_page=1", "-H", "If-Modified-Since: Fri, 09 Oct 2026 19:00:00 GMT" }, "probe since argv")
	assert(fake.calls[1].stdin == nil and fake.calls[1].cwd == nil and fake.calls[2].stdin == nil and fake.calls[2].cwd == nil)

	-- A token without the notifications scope gets a 404.
	local denied = FakeRunner.new({ { prefix = { "gh" }, reply = { status = 1, stdout = "HTTP/2.0 404 Not Found\n\n{}", stderr = "gh: Not Found (HTTP 404)" } } })
	value, err = first(function(done) Github.client(denied.run, decoder({})).probe(nil, done) end)
	assert(value == nil and err.message == "Couldn't check for changes: Not Found (HTTP 404)")

	-- run: the command's argv and stdin, no cwd, its stdout back.
	local runner = FakeRunner.new({
		{ prefix = { "gh", "pr", "merge", "7" }, reply = { stdout = "merged\n" } },
		{ prefix = { "gh", "pr", "comment" }, reply = { status = 1, stderr = "gh: Resource not accessible\n" } },
	})
	local running = Github.client(runner.run, decoder({}))
	local out
	out, err = first(function(done) running.run({ argv = { "gh", "pr", "merge", "7", "--repo", "acme/web", "--squash" } }, done) end)
	assert(err == nil and out == "merged\n")
	value, err = first(function(done) running.run({ argv = { "gh", "pr", "comment", "7", "--body-file", "-" }, stdin = "Looks good" }, done) end)
	assert(value == nil and err.message == "Couldn't run gh pr comment: Resource not accessible" and err.operation == "gh pr comment")
	runner.expectOnly(2)
	same(runner.calls[1].argv, { "gh", "pr", "merge", "7", "--repo", "acme/web", "--squash" }, "merge argv")
	assert(runner.calls[1].stdin == nil and runner.calls[1].cwd == nil)
	same(runner.calls[2].argv, { "gh", "pr", "comment", "7", "--body-file", "-" }, "comment argv")
	assert(runner.calls[2].stdin == "Looks good" and runner.calls[2].cwd == nil)

	-- checks with no ids runs nothing.
	local idle = FakeRunner.new({})
	local update
	update, err = first(function(done) Github.client(idle.run, decoder({})).checks({}, done) end)
	assert(err == nil and next(update.byId) == nil and update.rateLimit.cost == 0)
	idle.expectOnly(0)
end

-- Merge in each of the three methods and update-branch: the exact argv, run through the client, and nothing else.
local function testCommands()
	local pr = byKey["acme/api#110"]
	same(Github.commands.merge(pr, { kind = "squash" }), { argv = { "gh", "pr", "merge", "110", "--repo", "acme/api", "--squash" } }, "squash")
	same(Github.commands.merge(pr, { kind = "merge" }), { argv = { "gh", "pr", "merge", "110", "--repo", "acme/api", "--merge" } }, "merge")
	same(Github.commands.merge(pr, { kind = "rebase" }), { argv = { "gh", "pr", "merge", "110", "--repo", "acme/api", "--rebase" } }, "rebase")
	same(Github.commands.updateBranch(pr), { argv = { "gh", "pr", "update-branch", "110", "--repo", "acme/api" } }, "update-branch")
	assert(not pcall(Github.commands.merge, pr, { kind = "queue" }), "a queue merge is not a GitHub method")

	local fake = FakeRunner.new({
		{ prefix = { "gh", "pr", "merge" }, contains = "--squash", reply = { stdout = "" } },
		{ prefix = { "gh", "pr", "merge" }, contains = "--rebase", reply = { status = 1, stderr = "X Pull request #110 is not mergeable: the base branch policy prohibits the merge.\n" } },
		{ prefix = { "gh", "pr", "update-branch" }, reply = { stdout = "Updated\n" } },
	})
	local client = Github.client(fake.run, decoder({}))
	local out, err = first(function(done) client.run(Github.commands.merge(pr, { kind = "squash" }), done) end)
	assert(err == nil and out == "")
	out, err = first(function(done) client.run(Github.commands.merge(pr, { kind = "rebase" }), done) end)
	assert(out == nil and err.message == "Couldn't run gh pr merge: X Pull request #110 is not mergeable: the base branch policy prohibits the merge.")
	out, err = first(function(done) client.run(Github.commands.updateBranch(pr), done) end)
	assert(err == nil and out == "Updated\n")
	fake.expectOnly(3)
	same(fake.calls[1].argv, { "gh", "pr", "merge", "110", "--repo", "acme/api", "--squash" }, "ran squash")
	same(fake.calls[2].argv, { "gh", "pr", "merge", "110", "--repo", "acme/api", "--rebase" }, "ran rebase")
	same(fake.calls[3].argv, { "gh", "pr", "update-branch", "110", "--repo", "acme/api" }, "ran update-branch")
	for _, call in fake.calls do assert(call.stdin == nil) end

	-- Adding by link needs no command: the refresh asks for the PR by its number.
	local added = FakeRunner.new({ hubEntry({ stdout = "hub-f" }), threadsEntry({ stdout = "threads" }) })
	first(function(done) Github.client(added.run, decoder(BODIES)).refresh({ added = { { repo = "o/r", number = 9 } }, previous = {} }, done) end)
	assert(string.find(added.calls[1].argv[5], 'added0: repository(owner: "o", name: "r") { pullRequest(number: 9) { ...Hub } }', 1, true) ~= nil)
end

return function()
	assert(#ids(Cases.prs) > 0)
	testCommands()
	testParsers()
	testParsersNeverThrow()
	testSearchesAndAliases()
	testRefresh()
	testPartialThreadsFailure()
	testErrors()
	testProbeAndRun()
end
