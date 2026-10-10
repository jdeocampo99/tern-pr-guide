--!strict
-- The Tandem hand-off: the watch parser, where a watched PR sits and what its card offers, the exact argv and
-- stdin of both Tandem calls, and the real hub block driven through them. `tern` is stubbed in the module
-- environments of block and fetch, and every process effect is a recorded call that a scenario settles by hand.
local Cases: any = require("../fixtures/hub/cases")
local AgentFix = require("../src/hub/agent-fix")
local Model = require("../src/hub/model")
local State = require("../src/hub/state")
local Sync = require("../src/hub/sync")
local ReviewFix = require("../src/hub/review-fix")
local ReviewFixture: any = require("../fixtures/hub/review-fix")
local RawWatch: any = require("../fixtures/hub/raw-tandem-watch")
local RawFix: any = require("../fixtures/hub/raw-tandem-pr-fix")

local function copy(value: any): any
	if type(value) ~= "table" then return value end
	local out = {}
	for key, item in value do out[key] = copy(item) end
	return out
end

local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for key, value in a do
		if not same(value, b[key]) then return false end
	end
	for key in b do
		if a[key] == nil then return false end
	end
	return true
end

local function equal(actual: { string }, expected: { string })
	assert(#actual == #expected, "argv length: " .. table.concat(actual, " "))
	for i, value in expected do assert(actual[i] == value, "argv at " .. i) end
end

local function pr(key: string, patch: any?): any
	for _, source in Cases.prs do
		if source.key == key then
			local out = copy(source)
			for name, value in (patch or {}) do out[name] = value end
			return out
		end
	end
	error("no case " .. key)
end

local function board(prs: { any }): State.State
	return State.new(prs, Cases.asOf, nil)
end

local function card(s: State.State, key: string): State.Card
	local found = State.card(s, key)
	assert(found, "missing card " .. key)
	return found
end

-- Every action a card offers, main first.
local function acts(c: State.Card): { string }
	local out: { string } = {}
	if c.main then table.insert(out, c.main.act) end
	for _, more in c.more do table.insert(out, more.act) end
	return out
end

local function offers(c: State.Card, act: string): boolean
	return table.find(acts(c), act) ~= nil
end

local function parser()
	local watched = Model.parseTandemWatch(RawWatch) :: { [string]: boolean }
	-- The unwatched row is not owned, and the repo's case is not part of the match.
	assert(watched["acme/web#104"] == true and watched["acme/api#114"] == true and watched["acme/api#112"] == nil)
	local count = 0
	for _ in watched do count += 1 end
	assert(count == 2)

	local web, api = pr("acme/web#104"), pr("acme/api#114")
	local flags = Model.tandemFlags(watched, { web, api, pr("acme/api#112"), pr("acme/web#101") })
	assert(flags["acme/web#104"] == true and flags["acme/api#114"] == true and flags["acme/api#112"] == nil and flags["acme/web#101"] == nil)
	local spelled = copy(web)
	spelled.repo, spelled.key = "Acme/Web", "Acme/Web#104"
	assert(Model.tandemFlags(watched, { spelled })["Acme/Web#104"] == true, "flags use the board's own key")

	-- A malformed row is ignored and the rest still count; a document that is not the output is rejected.
	local doc = copy(RawWatch)
	local good = doc.rows[1]
	local bad: { any } = {
		"row", {}, { repo = "acme", number = 1 },
		{ repo = "acme/web", number = 0, branch = "b", url = "u", color = "red", checks = "", status = "", note = "" },
		{ repo = "acme/web", number = 1.5, branch = "b", url = "u", color = "red", checks = "", status = "", note = "" },
		{ repo = "acme/web", number = 2, branch = "b", url = "u", color = "purple", checks = "", status = "", note = "" },
		{ repo = "acme/web", number = 3, branch = 7, url = "u", color = "red", checks = "", status = "", note = "" },
		{ repo = "acme/web", number = 4, branch = "b", url = "u", color = "red", checks = "", status = "", note = "", checkCounts = { passed = 1 } },
		{ repo = "acme/web", number = 5, branch = "b", url = "u", color = "red", checks = "", status = "", note = "", taskId = 9 },
	}
	doc.rows = { bad[1], bad[2], bad[3], bad[4], bad[5], bad[6], bad[7], bad[8], bad[9], good }
	local filtered = Model.parseTandemWatch(doc) :: { [string]: boolean }
	local kept = 0
	for key in filtered do
		kept += 1
		assert(key == "acme/web#104", key)
	end
	assert(kept == 1)
	assert(next(Model.parseTandemWatch({ now = "x", rows = {} }) :: any) == nil)
	for _, document in { "text", 4, {}, { rows = {} }, { now = "x" }, { now = "x", rows = "no" }, { now = "x", rows = {}, readAt = 1 } } do
		assert(Model.parseTandemWatch(document) == nil)
	end
	local frozen = table.freeze(copy(RawWatch))
	assert(Model.parseTandemWatch(frozen) ~= nil, "parsing reads and never writes")
end

local function placement()
	-- A watched PR with something to fix stays In review, and its card hands off to Tandem.
	for _, key in { "acme/web#104", "acme/api#105", "acme/web#101", "acme/api#116" } do
		local mine = pr(key)
		assert(Model.classify(mine, Cases.asOf) == "needs_fixes", key)
		mine.tandem = true
		local placed = Model.placement(mine, Cases.asOf)
		assert(placed.column == "in_review" and #placed.reasons == 0, key)
		local s = board({ mine })
		local c = card(s, key)
		assert(c.column == "in_review" and c.chips[1].text == "Waiting on Tandem" and c.chips[1].kind == "agent")
		assert(c.main and c.main.act == "card-handoff" and c.main.label == "Hand off to Tandem" and c.main.key == "A")
		assert(#c.more == 1 and c.more[1].act == "card-copy" and c.more[1].label == "Copy link")
		for _, forbidden in { "card-agent", "card-summarize", "card-rerun" } do assert(not offers(c, forbidden), forbidden) end
		assert(not c.agentSlot, "no agent slot on a card Tandem owns")
	end

	-- The same PR with no Tandem keeps its own card.
	local plain = card(board({ pr("acme/web#104") }), "acme/web#104")
	assert(plain.column == "needs_fixes" and plain.main and plain.main.label == "Fix with agent")

	-- A watched bot-feedback PR is handed off, not fixed with an agent.
	local bot = card(board({ pr("acme/api#106") }), "acme/api#106")
	assert(bot.main and bot.main.label == "Fix bot comments" and offers(bot, "card-summarize"))
	local watchedBot = card(board({ pr("acme/api#106", { tandem = true }) }), "acme/api#106")
	assert(watchedBot.column == "in_review" and watchedBot.main and watchedBot.main.act == "card-handoff")
	for _, forbidden in { "card-agent", "card-summarize" } do assert(not offers(watchedBot, forbidden), forbidden) end
	assert(bot.agentSlot and not watchedBot.agentSlot)

	-- Draft, inactive and review-role PRs keep their own places; every other watched PR of the viewer is In review.
	local draft = Model.placement(pr("acme/web#113", { tandem = true }), Cases.asOf)
	assert(draft.column == "inactive")
	assert(Model.placement(pr("acme/web#102", { tandem = true }), Cases.asOf).column == "inactive")
	assert(Model.placement(pr("acme/web#301", { tandem = true }), Cases.asOf).column == "to_review")
	assert(Model.classify(pr("acme/api#109"), Cases.asOf) == "ready")
	local readyPlaced = Model.placement(pr("acme/api#109", { tandem = true }), Cases.asOf)
	assert(readyPlaced.column == "in_review" and #readyPlaced.reasons == 0, "a watched PR that could merge waits in In review")
	local owned = card(board({ pr("acme/api#109", { tandem = true }) }), "acme/api#109")
	assert(owned.column == "in_review" and owned.chips[1].text == "Waiting on Tandem")
	assert(owned.main and owned.main.act == "card-handoff" and owned.main.act ~= "card-merge")
	for _, forbidden in { "card-merge", "card-update", "card-agent", "card-summarize" } do assert(not offers(owned, forbidden), forbidden) end
	assert(Model.selectGroup(owned.pr, Cases.asOf) == nil, "a watched PR is not selected for a merge")
	local waiting = card(board({ pr("acme/api#114", { tandem = true }) }), "acme/api#114")
	assert(waiting.column == "in_review" and waiting.chips[1].text == "Waiting on Tandem")

	-- The reason a hand-off gives is stable and never empty.
	local failing = pr("acme/web#104", { tandem = true })
	assert(Model.handoffReason(failing, Cases.asOf) == "PR hub: failing checks")
	assert(Model.handoffReason(failing, Cases.asOf) == Model.handoffReason(failing, Cases.asOf))
	assert(Model.handoffReason(pr("acme/api#116", { tandem = true }), Cases.asOf) == "PR hub: the merge failed, review feedback to address, failing checks, merge conflicts")
	assert(Model.handoffReason(pr("acme/api#114", { tandem = true }), Cases.asOf) == "Hand off from the PR hub")
end

-- The stub `tern` shared by the block's and fetch's module environments. Decoded text is looked up, and an
-- encoded value is recorded so the test can compare the exact request table that would be written.
local REPO_ROOT = "/Users/reader/project"
local SUBFOLDER = REPO_ROOT .. "/src/deep"

local function stubTern(w: any): any
	return {
		json = {
			decode = function(text: string): any
				local value = w.decoded[text]
				if value == nil then error("invalid json", 0) end
				return value
			end,
			encode = function(value: any): string
				table.insert(w.encoded, value)
				return "ENVELOPE_" .. #w.encoded
			end,
		},
		timer = function(_: number, fn: () -> ()): any
			table.insert(w.timers, fn)
			return { cancel = function() end }
		end,
		getenv = function(): string? return nil end,
		-- `w.kvIn` is what the plugin finds stored and `w.kv` what it wrote. With `w.shared`, one store serves both: a read sees
		-- every earlier write, and values are copied in and out, as a store shared by two windows would.
		kv = {
			-- `w.failGets` fails that many reads and then recovers; `w.onGet` runs before a read and may store another window's write.
			get = function(key: string): any
				if w.onGet then w.onGet() end
				if w.failGet then error("disk unreadable", 0) end
				if (w.failGets or 0) > 0 then
					w.failGets -= 1
					error("disk unreadable", 0)
				end
				if w.shared then return copy(w.kv[key]) end
				return if w.kvIn then w.kvIn[key] else nil
			end,
			-- `w.cacheSets` counts every attempt to store the cache, failed or not; `w.failWhen` fails the stores it names.
			set = function(key: string, value: any)
				if key == "hub.cache" then w.cacheSets = (w.cacheSets or 0) + 1 end
				if w.failKv or (w.failWhen and w.failWhen(key, value)) then
					if w.whileFailing then w.whileFailing() end
					error("disk full", 0)
				end
				w.kv[key] = if w.shared then copy(value) else value
			end,
		},
	}
end

-- Block's clock is frozen at `w.now` for the whole scenario (an hour after the recorded boards' `asOf`, so the stamps
-- the scenarios store, up to `asOf + 120`, are all older than a refresh and no result depends on the machine's date). A
-- scenario moves it by setting `w.now`. The real `os` comes back even when the scenario errors.
local function withWorld(run: (w: any, Fetch: any, Block: any) -> ())
	local Block: any = require("../src/hub/block")
	local Fetch: any = require("../src/fetch")
	local blockEnv: any, fetchEnv: any = getfenv(Block.init), getfenv(Fetch.tandemWatch)
	local hostBlock, hostFetch, hostRunner, hostFind = blockEnv.tern, fetchEnv.tern, Fetch.runner, Fetch.findRepo
	local hostOs = rawget(blockEnv, "os")
	local realOs = os
	local hostClone, hostStart = Fetch.findAgentClone, Fetch.startAgentFix
	local w: any = {
		decoded = {}, encoded = {}, timers = {}, calls = {}, toasts = {}, renders = 0, throws = false, Block = Block,
		finds = {}, holdRoot = false, rootFails = false, findThrows = false, kv = {}, now = Cases.asOf + 3600,
	}
	local stub = stubTern(w)
	blockEnv.tern, fetchEnv.tern = stub, stub
	blockEnv.os = setmetatable({
		time = function(t: any?): number
			if t then return realOs.time(t) end
			return w.now
		end,
	}, { __index = realOs })
	-- Finding the repository root is a recorded call too: answered at once with REPO_ROOT unless a scenario holds
	-- it (settled by hand through `finds[n].done`) or makes it fail or throw.
	Fetch.findRepo = function(dir: string, done: (any, string?) -> ())
		table.insert(w.finds, { dir = dir, done = done })
		if w.findThrows then error("git failed", 0) end
		if w.holdRoot then return end
		if w.rootFails then return done(nil, "No checkout at " .. dir) end
		done({ root = REPO_ROOT, guides = REPO_ROOT .. "/.git/prguide" }, nil)
	end
	Fetch.runner = function(argv: { string }, opts: any, done: (any) -> ())
		table.insert(w.calls, { argv = table.clone(argv), opts = opts, done = done })
		if w.throws then error("spawn failed", 0) end
	end
	local ok, err = pcall(run, w, Fetch, Block)
	blockEnv.tern, fetchEnv.tern, Fetch.runner, Fetch.findRepo = hostBlock, hostFetch, hostRunner, hostFind
	blockEnv.os = hostOs
	Fetch.findAgentClone, Fetch.startAgentFix = hostClone, hostStart
	if not ok then error(err, 0) end
end

local function out(stdout: string?, status: number?, stderr: string?, timedOut: boolean?): any
	return { status = status or 0, stdout = stdout or "", stderr = stderr or "", timed_out = timedOut or false }
end

local function fetching()
	withWorld(function(w, Fetch)
		w.decoded["WATCH"] = RawWatch
		w.decoded["DONE"], w.decoded["KEPT"], w.decoded["REFUSED"] = RawFix.done, RawFix.kept, RawFix.refusal

		-- Watch: exactly `tandem watch --json` in the project root, answered once.
		local seen: { { watched: any, err: string? } } = {}
		local function watch(settle: (any) -> ())
			w.calls = {}
			seen = {}
			Fetch.tandemWatch(REPO_ROOT, function(watched: any, err: string?) table.insert(seen, { watched = watched, err = err }) end)
			assert(#w.calls == 1)
			local call = w.calls[1]
			equal(call.argv, { "tandem", "watch", "--json" })
			assert(call.opts.cwd == REPO_ROOT and call.opts.stdin == nil)
			settle(call)
		end
		watch(function(call)
			call.done(out("WATCH"))
			call.done(out("WATCH"))
			assert(#seen == 1 and seen[1].err == nil and seen[1].watched["acme/web#104"] == true and seen[1].watched["acme/api#112"] == nil, "once")
		end)
		for name, reply in {
			nonzero = out("WATCH", 1, "tandem: not found"), timeout = out("", 0, "", true),
			garbage = out("not json"), shape = out("SHAPELESS"),
		} do
			w.decoded["SHAPELESS"] = { rows = {} }
			watch(function(call)
				call.done(reply)
				assert(#seen == 1 and seen[1].watched == nil and seen[1].err ~= nil, name)
			end)
		end
		w.throws = true
		seen = {}
		w.calls = {}
		Fetch.tandemWatch(REPO_ROOT, function(watched: any, err: string?) table.insert(seen, { watched = watched, err = err }) end)
		assert(#seen == 1 and seen[1].watched == nil and string.find(seen[1].err :: string, "spawn failed", 1, true))
		w.throws = false
		w.calls = {}
		Fetch.tandemWatch("relative/project", function(watched: any, err: string?) table.insert(seen, { watched = watched, err = err }) end)
		assert(#w.calls == 0 and #seen == 2 and seen[2].watched == nil, "a relative root runs nothing")

		-- Hand-off: exactly `tandem native act`, with the plugin origin and the four action fields.
		local replies: { { outcome: any, err: string? } } = {}
		local function handoff(settle: (any) -> ())
			w.calls, w.encoded, replies = {}, {}, {}
			Fetch.tandemHandoff(REPO_ROOT, "acme/web", 104, "  PR hub: failing checks \n", function(outcome: any, err: string?)
				table.insert(replies, { outcome = outcome, err = err })
			end)
			assert(#w.calls == 1 and #w.encoded == 1)
			local call = w.calls[1]
			equal(call.argv, { "tandem", "native", "act" })
			assert(call.opts.cwd == REPO_ROOT and call.opts.stdin == "ENVELOPE_1")
			assert(same(w.encoded[1], {
				v = 1, origin = { plugin = "prguide", repoPath = REPO_ROOT },
				action = { verb = "pr-fix", repo = "acme/web", number = 104, reason = "PR hub: failing checks" },
			}), "the envelope is exact")
			settle(call)
		end
		handoff(function(call)
			call.done(out("DONE"))
			call.done(out("REFUSED"))
			assert(#replies == 1 and replies[1].err == nil and replies[1].outcome.status == "done" and replies[1].outcome.notice == nil, "once")
		end)
		handoff(function(call)
			call.done(out("KEPT"))
			local outcome = replies[1].outcome
			assert(outcome.status == "kept" and outcome.notice.code == "failed" and string.find(outcome.notice.text, "No worktree is free", 1, true))
		end)
		handoff(function(call)
			call.done(out("REFUSED", 0))
			local outcome = replies[1].outcome
			assert(replies[1].err == nil and outcome.status == "refused" and outcome.notice.text == "Tandem does not know this project")
		end)
		w.decoded["ODD"] = { status = "maybe" }
		w.decoded["BADNOTICE"] = { status = "refused", notice = "text" }
		w.decoded["NOCODE"] = { status = "refused", notice = { text = "x" } }
		for name, reply in {
			nonzero = out("DONE", 2, "tandem: boom"), timeout = out("", 0, "", true), garbage = out("nope"),
			status = out("ODD"), notice = out("BADNOTICE"), code = out("NOCODE"),
		} do
			handoff(function(call)
				call.done(reply)
				assert(#replies == 1 and replies[1].outcome == nil and replies[1].err ~= nil, name)
			end)
		end
		w.throws = true
		w.calls, w.encoded, replies = {}, {}, {}
		Fetch.tandemHandoff(REPO_ROOT, "acme/web", 104, "why", function(outcome: any, err: string?) table.insert(replies, { outcome = outcome, err = err }) end)
		assert(#replies == 1 and replies[1].outcome == nil and string.find(replies[1].err :: string, "spawn failed", 1, true))
		w.throws = false
		-- A request that is not whole runs nothing.
		w.calls, w.encoded, replies = {}, {}, {}
		local incomplete: { { any } } = {
			{ "acme/web", 104, "   " }, { "acme/web", 0, "why" }, { "acme/web", 1.5, "why" }, { "acme", 104, "why" }, { "acme/web", -1, "why" },
		}
		for _, args in incomplete do
			Fetch.tandemHandoff(REPO_ROOT, args[1], args[2], args[3], function(outcome: any, err: string?) table.insert(replies, { outcome = outcome, err = err }) end)
		end
		Fetch.tandemHandoff("relative", "acme/web", 104, "why", function(outcome: any, err: string?) table.insert(replies, { outcome = outcome, err = err }) end)
		assert(#w.calls == 0 and #w.encoded == 0 and #replies == 6)
		for _, reply in replies do assert(reply.outcome == nil and reply.err ~= nil) end
	end)
end

local function runTimers(w: any)
	local pending = w.timers
	w.timers = {}
	for _, fn in pending do fn() end
end

-- A live board (opened in a subfolder of the repository, so the block finds the root and reads Tandem) over the
-- cases, with every effect recorded. With `cached`, the board opens from the cache in `w.kvIn` and keeps what it holds.
local function live(w: any, Block: any, cached: boolean?): any
	local cx: any = { cwd = SUBFOLDER }
	function cx:render() w.renders += 1 end
	function cx:toast(kind: string, title: string, detail: string?) table.insert(w.toasts, { kind = kind, title = title, detail = detail }) end
	function cx:frame() end
	function cx:open() end
	w.decoded["WATCH"], w.decoded["DONE"], w.decoded["KEPT"], w.decoded["REFUSED"] = RawWatch, RawFix.done, RawFix.kept, RawFix.refusal
	local b: any = Block.init(cx, {}, nil)
	w.b, w.cx = b, cx
	State.replace(b.s, if cached then b.s.prs else copy(Cases.prs), Cases.asOf, Cases.asOfIso)
	return b
end

local function press(w: any, name: string)
	w.b.s.keyed = true
	w.Block.key(w.b, { name = name } :: any, w.cx)
end

local function handoffs(w: any): { any }
	local found = {}
	for _, call in w.calls do
		if call.argv[2] == "native" then table.insert(found, call) end
	end
	return found
end

local function blockPaths()
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		-- Opening the block reads Tandem once, in the project root, and nothing else runs.
		assert(#w.calls == 1)
		equal(w.calls[1].argv, { "tandem", "watch", "--json" })
		assert(w.calls[1].opts.cwd == REPO_ROOT and #handoffs(w) == 0, "Tandem runs in the repository root, not the subfolder")
		assert(#w.finds == 1 and w.finds[1].dir == SUBFOLDER and b.root == REPO_ROOT)
		assert(card(b.s, "acme/web#104").column == "needs_fixes", "before the read, nothing is flagged")
		w.calls[1].done(out("WATCH"))
		local web, api, other = card(b.s, "acme/web#104"), card(b.s, "acme/api#114"), card(b.s, "acme/api#105")
		assert(web.column == "in_review" and web.chips[1].text == "Waiting on Tandem" and web.pr.tandem)
		assert(api.chips[1].text == "Waiting on Tandem" and api.pr.tandem, "the repo's case does not matter")
		assert(other.column == "needs_fixes" and not other.pr.tandem and other.main and other.main.label == "Fix with agent")
		assert(card(b.s, "acme/api#112").column == "needs_fixes" and not card(b.s, "acme/api#112").pr.tandem, "unwatched is not owned")
		assert(#handoffs(w) == 0, "nothing is handed off before a press")

		-- A refresh reads Tandem again, once, in the same root, and still hands nothing off.
		b.github = { refresh = function() end }
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local reads = 0
		for _, call in w.calls do
			if call.argv[1] == "tandem" then
				reads += 1
				equal(call.argv, { "tandem", "watch", "--json" })
				assert(call.opts.cwd == REPO_ROOT)
			end
		end
		assert(reads == 2 and #handoffs(w) == 0 and #w.finds == 1, "the root is found once")
		w.calls[2].done(out("WATCH"))
		assert(b.flights.tandem == false and card(b.s, "acme/web#104").pr.tandem)
		w.calls = {}

		-- Fix with agent is not offered on a watched card, and the handlers refuse it all the same.
		for _, column in b.s.board.columns do
			for _, c in column.cards do
				if c.pr.tandem then
					assert(c.main and c.main.act == "card-handoff" and c.main.label == "Hand off to Tandem")
					for _, forbidden in { "card-agent", "card-summarize" } do assert(not offers(c, forbidden), forbidden) end
				end
			end
		end
		Block.event(b, { ev = "action", act = "card-agent", value = "acme/web#104" } :: any, w.cx)
		assert(b.agentFlight == nil and b.s.agents["acme/web#104"] == nil and #w.toasts == 0 and #w.calls == 0)

		-- A on the watched card hands it off: one call, the exact request, the card busy until Tandem answers.
		State.select(b.s, "acme/web#104")
		local renders = w.renders
		press(w, "a")
		assert(#w.calls == 1 and #handoffs(w) == 1 and w.renders > renders)
		local call = handoffs(w)[1]
		equal(call.argv, { "tandem", "native", "act" })
		assert(call.opts.cwd == REPO_ROOT and call.opts.stdin == "ENVELOPE_1")
		assert(same(w.encoded[1], {
			v = 1, origin = { plugin = "prguide", repoPath = REPO_ROOT },
			action = { verb = "pr-fix", repo = "acme/web", number = 104, reason = "PR hub: failing checks" },
		}))
		assert(b.s.busy["acme/web#104"] ~= nil)
		press(w, "a")
		assert(#w.calls == 1, "a press while the request is out sends nothing")
		call.done(out("DONE"))
		call.done(out("REFUSED"))
		assert(b.s.busy["acme/web#104"] == nil and #w.toasts == 0 and card(b.s, "acme/web#104").column == "in_review", "answered once")
		assert(card(b.s, "acme/web#104").chips[1].text == "Waiting on Tandem")

		-- Done on a card Tandem was not on yet: it moves to In review as Waiting on Tandem.
		w.calls = {}
		w.encoded = {}
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#105" } :: any, w.cx)
		assert(#w.finds == 1, "the hand-off reuses the root")
		assert(#w.calls == 1 and w.calls[1].opts.cwd == REPO_ROOT and same(w.encoded[1].origin, { plugin = "prguide", repoPath = REPO_ROOT }))
		assert(#w.calls == 1 and same(w.encoded[1].action, { verb = "pr-fix", repo = "acme/api", number = 105, reason = "PR hub: merge conflicts" }))
		w.calls[1].done(out("DONE"))
		local moved = card(b.s, "acme/api#105")
		assert(moved.pr.tandem and moved.column == "in_review" and moved.chips[1].text == "Waiting on Tandem" and #w.toasts == 0)
		assert(not card(b.s, "acme/api#116").pr.tandem and card(b.s, "acme/api#116").column == "needs_fixes", "only the intended PR changes")
		assert(b.watched["acme/api#105"] == true)

		-- Kept is Waiting on Tandem too, with Tandem's own notice as an info toast.
		w.calls, w.encoded, w.toasts = {}, {}, {}
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/web#101" } :: any, w.cx)
		w.calls[1].done(out("KEPT"))
		assert(card(b.s, "acme/web#101").pr.tandem and card(b.s, "acme/web#101").chips[1].text == "Waiting on Tandem")
		assert(#w.toasts == 1 and w.toasts[1].kind == "info" and string.find(w.toasts[1].title, "No worktree is free", 1, true))

		-- Refused: the notice is the toast, and nothing about the card changes.
		w.calls, w.encoded, w.toasts = {}, {}, {}
		local before = card(b.s, "acme/api#116")
		local was = { column = before.column, tandem = before.pr.tandem, main = before.main and before.main.act }
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		w.calls[1].done(out("REFUSED"))
		local after = card(b.s, "acme/api#116")
		assert(#w.toasts == 1 and w.toasts[1].kind == "error" and w.toasts[1].title == "Tandem does not know this project")
		assert(after.column == was.column and after.pr.tandem == was.tandem and after.main and after.main.act == was.main and b.s.busy["acme/api#116"] == nil)
		assert(b.watched["acme/api#116"] == nil)

		-- A failed call is a toast and no change: non-zero, timeout, bad output, a throw.
		for name, reply in { nonzero = out("", 1, "tandem: boom"), timeout = out("", 0, "", true), garbage = out("nope") } do
			w.calls, w.toasts = {}, {}
			Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
			w.calls[1].done(reply)
			assert(#w.toasts == 1 and w.toasts[1].kind == "error" and string.find(w.toasts[1].title, "Couldn't hand off to Tandem", 1, true), name)
			assert(not card(b.s, "acme/api#116").pr.tandem and b.s.busy["acme/api#116"] == nil, name)
		end
		w.throws, w.calls, w.toasts = true, {}, {}
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		assert(#w.toasts == 1 and string.find(w.toasts[1].title, "spawn failed", 1, true) and not card(b.s, "acme/api#116").pr.tandem and b.s.busy["acme/api#116"] == nil)
		w.throws = false

		-- An answer for a PR that left the board, or whose head moved, changes nothing.
		w.calls, w.toasts = {}, {}
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		State.dropPr(b.s, "acme/api#116")
		w.calls[1].done(out("DONE"))
		assert(State.prOf(b.s, "acme/api#116") == nil and #w.toasts == 0 and b.watched["acme/api#116"] == nil)
		w.calls = {}
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#119" } :: any, w.cx)
		local moved119: any = State.prOf(b.s, "acme/api#119")
		moved119.headOid = "moved"
		w.calls[1].done(out("DONE"))
		assert(not moved119.tandem and #w.toasts == 0 and b.s.busy["acme/api#119"] == nil)
		w.calls = {}
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#118" } :: any, w.cx)
		b.closed = true
		local renderedBefore = w.renders
		w.calls[1].done(out("DONE"))
		assert(w.renders == renderedBefore and #w.toasts == 0, "a closed block does nothing")
	end)

	-- A failed or unreadable watch leaves every flag false and the board usable.
	for name, reply in { nonzero = out("", 127, "tandem: not found"), garbage = out("nope"), timeout = out("", 0, "", true) } do
		withWorld(function(w, Fetch, Block)
			local b = live(w, Block)
			w.calls[1].done(reply)
			local c = card(b.s, "acme/web#104")
			assert(not c.pr.tandem and c.column == "needs_fixes" and c.main and c.main.label == "Fix with agent", name)
			assert(b.flights.tandem == false and #w.toasts == 0 and b.s.error == nil, name)
		end)
	end
	withWorld(function(w, Fetch, Block)
		w.throws = true
		local b = live(w, Block)
		assert(b.flights.tandem == false and not card(b.s, "acme/web#104").pr.tandem)
	end)
	withWorld(function(w, Fetch, Block)
		local cx: any = { cwd = nil }
		function cx:render() end
		function cx:toast() end
		function cx:frame() end
		local b: any = Block.init(cx, {}, nil)
		assert(#w.calls == 0 and #w.finds == 0 and b.flights.tandem == false, "no project folder, no read")
	end)
end

local function rootPaths()
	-- The root is found while a watch and two hand-offs wait: one lookup, nothing sent until it answers, and then
	-- every call runs in the repository root with that root as the origin.
	withWorld(function(w, Fetch, Block)
		w.holdRoot = true
		local b = live(w, Block)
		assert(#w.finds == 1 and #w.calls == 0 and b.flights.tandem == true and b.root == nil)
		b.github = { refresh = function() end }
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#105" } :: any, w.cx)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		assert(#w.finds == 1 and #w.calls == 0 and #w.encoded == 0, "one lookup, no process before the root")
		assert(b.s.busy["acme/api#105"] ~= nil and b.s.busy["acme/api#116"] ~= nil)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#105" } :: any, w.cx)
		assert(#w.finds == 1 and #w.calls == 0, "a press on a card that is already out sends nothing")
		w.finds[1].done({ root = REPO_ROOT }, nil)
		w.finds[1].done({ root = "/elsewhere" }, nil)
		assert(b.root == REPO_ROOT and #w.finds == 1)
		assert(#w.calls == 3 and #handoffs(w) == 2, "one watch and two hand-offs")
		equal(w.calls[1].argv, { "tandem", "watch", "--json" })
		for _, call in w.calls do assert(call.opts.cwd == REPO_ROOT) end
		for _, envelope in w.encoded do assert(envelope.origin.repoPath == REPO_ROOT and envelope.origin.plugin == "prguide") end
		assert(#w.encoded == 2 and w.encoded[1].action.number == 105 and w.encoded[2].action.number == 116)
		w.finds[1].done({ root = REPO_ROOT }, nil)
		assert(#w.calls == 3, "a second answer from the lookup sends nothing")
	end)

	-- No root: the watch is quiet and the board usable; a press says so, sends nothing and frees the card; the
	-- next try looks again.
	for name, how in { fails = "rootFails", throws = "findThrows" } do
		withWorld(function(w, Fetch, Block)
			w[how] = true
			local b = live(w, Block)
			assert(#w.calls == 0 and b.flights.tandem == false and b.root == nil and #w.toasts == 0 and b.s.error == nil, name)
			local plain = card(b.s, "acme/web#104")
			assert(plain.column == "needs_fixes" and plain.main and plain.main.label == "Fix with agent", name)
			Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
			assert(#w.calls == 0 and #w.encoded == 0 and b.s.busy["acme/api#116"] == nil, name)
			assert(#w.toasts == 1 and w.toasts[1].kind == "error" and string.find(w.toasts[1].title, "Couldn't hand off to Tandem", 1, true), name)
			assert(not card(b.s, "acme/api#116").pr.tandem and card(b.s, "acme/api#116").column == "needs_fixes", name)
			w[how] = false
			Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
			assert(#w.finds == 3 and b.root == REPO_ROOT and #handoffs(w) == 1 and handoffs(w)[1].opts.cwd == REPO_ROOT, name)
		end)
	end

	-- A card that went away or moved while the root was found gets nothing sent; another card's busy state stays its own.
	withWorld(function(w, Fetch, Block)
		w.holdRoot = true
		local b = live(w, Block)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#105" } :: any, w.cx)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#119" } :: any, w.cx)
		State.dropPr(b.s, "acme/api#105")
		local moved: any = State.prOf(b.s, "acme/api#116")
		moved.headOid = "moved"
		b.s.busy["acme/api#119"] = "Merging…"
		w.finds[1].done({ root = REPO_ROOT }, nil)
		assert(#handoffs(w) == 1 and #w.encoded == 1 and w.encoded[1].action.number == 119, "only the card that is still there is sent")
		assert(b.s.busy["acme/api#116"] == nil and b.s.busy["acme/api#105"] == nil and #w.toasts == 0)
		handoffs(w)[1].done(out("DONE"))
		assert(b.s.busy["acme/api#119"] == "Merging…", "another action's busy state is not cleared by the answer")
	end)
	withWorld(function(w, Fetch, Block)
		w.holdRoot = true
		local b = live(w, Block)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#119" } :: any, w.cx)
		State.dropPr(b.s, "acme/api#116")
		b.s.busy["acme/api#119"] = "Merging…"
		w.finds[1].done(nil, "No checkout")
		assert(#w.calls == 0 and #w.encoded == 0, "nothing is sent")
		assert(#w.toasts == 1 and w.toasts[1].detail == "acme/api#119" and string.find(w.toasts[1].title, "Couldn't hand off to Tandem", 1, true), "only the card still there is told")
		assert(b.s.busy["acme/api#119"] == "Merging…", "another action's busy state is not cleared")
	end)

	-- A closed block does nothing with the answer.
	withWorld(function(w, Fetch, Block)
		w.holdRoot = true
		local b = live(w, Block)
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		b.closed = true
		local rendered = w.renders
		w.finds[1].done({ root = REPO_ROOT }, nil)
		assert(#w.calls == 0 and w.renders == rendered and #w.toasts == 0 and b.flights.tandem == false)
	end)
end

-- The `tandem watch --json` reads a board has asked for, oldest first.
local function reads(w: any): { any }
	local found = {}
	for _, call in w.calls do
		if call.argv[2] == "watch" then table.insert(found, call) end
	end
	return found
end

-- The recorded watch with a row added for each key ("owner/repo#123"), as Tandem answers once it watches them.
local function watchWith(keys: { string }): any
	local doc = copy(RawWatch)
	for _, key in keys do
		local repo: any, number: any = string.match(key, "^(.+)#(%d+)$")
		local row = copy(doc.rows[1])
		row.repo, row.number, row.taskId = repo, tonumber(number), nil
		row.branch, row.url = "branch-" .. number, "https://github.com/" .. repo .. "/pull/" .. number
		table.insert(doc.rows, row)
	end
	return doc
end

-- A read of Tandem that started before a hand-off returns after it, and the other way round. Every callback is
-- settled by hand, so the order is the test's own.
local function staleRead()
	local KEY = "acme/api#105"
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		w.decoded["LATER"] = watchWith({ KEY })
		local first = reads(w)[1]
		assert(#reads(w) == 1 and b.flights.tandem, "open's read is still out")
		Block.event(b, { ev = "action", act = "card-handoff", value = KEY } :: any, w.cx)
		handoffs(w)[1].done(out("DONE"))
		assert(card(b.s, KEY).pr.tandem and b.watched[KEY] == true)

		-- The older read comes back last, and its snapshot (the recorded watch) does not name the PR. It is dropped.
		first.done(out("WATCH"))
		local mine = card(b.s, KEY)
		assert(mine.pr.tandem and mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem", "a hand-off is not undone by an older read")
		assert(mine.main and mine.main.act == "card-handoff" and not offers(mine, "card-agent"), "no Fix with agent comes back")
		assert(b.watched[KEY] == true and #reads(w) == 2 and b.flights.tandem, "a newer read is out")
		first.done(out("WATCH"))
		assert(#reads(w) == 2 and card(b.s, KEY).pr.tandem, "the stale answer counts once")

		-- The newer read settles it, in whichever order Tandem reports.
		reads(w)[2].done(out("LATER"))
		assert(card(b.s, KEY).pr.tandem and #reads(w) == 2 and not b.flights.tandem)
		assert(card(b.s, "acme/web#104").pr.tandem and not card(b.s, "acme/api#116").pr.tandem)

		-- A read that began after the hand-off is authoritative: one that no longer names the PR clears the flag.
		b.github = { refresh = function() end }
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(#reads(w) == 3)
		reads(w)[3].done(out("WATCH"))
		assert(not card(b.s, KEY).pr.tandem and card(b.s, KEY).column == "needs_fixes" and #reads(w) == 3)
	end)

	-- A stale read that failed is dropped too, and asks again.
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		local first = reads(w)[1]
		Block.event(b, { ev = "action", act = "card-handoff", value = KEY } :: any, w.cx)
		handoffs(w)[1].done(out("KEPT"))
		first.done(out("nope"))
		assert(card(b.s, KEY).pr.tandem and #reads(w) == 2 and b.s.error == nil and #w.toasts == 1)
	end)

	-- A closed block reads nothing more and renders nothing.
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		local first = reads(w)[1]
		Block.event(b, { ev = "action", act = "card-handoff", value = KEY } :: any, w.cx)
		handoffs(w)[1].done(out("DONE"))
		b.closed = true
		local rendered = w.renders
		first.done(out("WATCH"))
		assert(#reads(w) == 1 and w.renders == rendered and b.flights.tandem == false)
	end)
end

-- GitHub's refresh answered first and Tandem's read second: the cache and the window's status segment follow the
-- placement the flags give, counted over every PR, and the flash time stays.
local function counts()
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		local FLASH = 1234
		local fresh: any = { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
		local cache = Sync.merge(fresh, nil, { added = {}, tandem = {} }, Cases.asOf)
		cache.counts.flashAt = FLASH
		b.cache = cache
		State.replace(b.s, cache.prs, Cases.asOf, Cases.asOfIso)
		local before = cache.counts.needFixes
		assert(card(b.s, "acme/web#104").column == "needs_fixes" and before >= 2)

		reads(w)[1].done(out("WATCH"))
		assert(card(b.s, "acme/web#104").column == "in_review")
		local toReview, needFixes = 0, 0
		for _, pr in b.s.prs do
			local column = Model.classify(pr, Cases.asOf)
			if column == "to_review" then toReview += 1 end
			if column == "needs_fixes" then needFixes += 1 end
		end
		assert(needFixes < before, "the watched PR left Needs fixes")
		assert(b.cache.counts.needFixes == needFixes and b.cache.counts.toReview == toReview and b.cache.counts.flashAt == FLASH)
		local status, saved = w.kv["hub.status"], w.kv["hub.cache"]
		assert(status.counts.needFixes == needFixes and status.counts.toReview == toReview and status.counts.flashAt == FLASH, "the status segment")
		assert(saved.counts.needFixes == needFixes and saved.counts.flashAt == FLASH, "the saved cache")

		-- A hand-off moves a PR out of Needs fixes the same way.
		w.calls = {}
		Block.event(b, { ev = "action", act = "card-handoff", value = "acme/api#116" } :: any, w.cx)
		handoffs(w)[1].done(out("DONE"))
		assert(b.cache.counts.needFixes == needFixes - 1 and b.cache.counts.flashAt == FLASH)
		assert(w.kv["hub.status"].counts.needFixes == needFixes - 1 and w.kv["hub.status"].counts.flashAt == FLASH)
	end)
end

local TARGET = "acme/api#105"

-- A live board whose agent and clone lookup are recorded calls, with Tandem read once (it names web#104 and api#114,
-- not TARGET). `claim` then lets a later read of Tandem name TARGET.
local function agentBoard(w: any, Fetch: any, Block: any): any
	local b = live(w, Block)
	reads(w)[1].done(out("WATCH"))
	w.clones, w.started, w.details, w.stops = {}, {}, {}, 0
	Fetch.findAgentClone = function(_near: any, _dir: string, slug: string, ask: any, done: (string?, string?) -> ())
		table.insert(w.clones, { slug = slug, ask = ask, done = done })
	end
	Fetch.startAgentFix = function(request: any, _agent: any, _now: number, changed: any, done: any): any
		table.insert(w.started, { request = request, changed = changed, done = done })
		return {
			stop = function() w.stops += 1 end, release = function(finished: (boolean?, string?) -> ()) finished(true, nil) end,
			begin = function() end, held = function(): any return nil end, busy = function(): boolean return true end,
		}
	end
	b.agent = { command = "/omp", path = "/omp", model = "provider/model", effort = "high", models = {}, lenses = {}, lens = "" }
	b.github = { refresh = function() end, details = function(pr: any, done: any) table.insert(w.details, { pr = pr, done = done }) end }
	local target: any = State.prOf(b.s, TARGET)
	w.decoded["REFS"] = { headRefName = "topic", baseRefName = target.baseBranch, headRefOid = target.headOid }
	w.decoded["CLAIM"] = watchWith({ TARGET })
	assert(not target.tandem and card(b.s, TARGET).main.label == "Fix with agent")
	return b
end

local function claim(w: any, Block: any, b: any)
	Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
	local list = reads(w)
	list[#list].done(out("CLAIM"))
	assert(State.prOf(b.s, TARGET).tandem == true)
end

local function gh(w: any): any
	for _, call in w.calls do
		if call.argv[1] == "gh" then return call end
	end
	return nil
end

-- Nothing started, nothing left running, and no worktree or engine taken.
local function noFixer(w: any, b: any, why: string)
	assert(#w.started == 0 and b.agentFlight == nil and w.stops == 0, why)
	assert(b.s.agents[TARGET] == nil, why .. ": a fix that never started leaves no state")
end

-- Tandem takes a PR while its agent is only being set up, or already has a failed or missing-clone state.
local function agentOverlap()
	-- Retry, Clone and Choose folder on a card Tandem owns go through the same entry, which starts nothing. The
	-- same press on a card nobody watches does start looking, so the refusal is the guard's.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		State.agentFailed(b.s, TARGET, "No clone was found", nil)
		claim(w, Block, b)
		local finds = #w.finds
		for _, act in { "card-agent-retry", "card-agent-clone", "card-agent-folder" } do
			Block.event(b, { ev = "action", act = act, value = TARGET } :: any, w.cx)
		end
		assert(#w.finds == finds and #w.clones == 0 and #w.started == 0 and b.agentFlight == nil and gh(w) == nil)
		assert(b.s.agents[TARGET] == nil and #w.toasts == 0, "the failed state is dropped once Tandem owns the card")
		local owned = card(b.s, TARGET)
		assert(owned.chips[1].text == "Waiting on Tandem" and owned.main and owned.main.act == "card-handoff" and owned.main.key == "A")
		State.noAgentClone(b.s, TARGET, "acme/api")
		assert(b.s.agents[TARGET] == nil, "a missing clone is dropped too")
		for _, act in { "card-agent-clone", "card-agent-folder" } do
			Block.event(b, { ev = "action", act = act, value = TARGET } :: any, w.cx)
		end
		assert(#w.finds == finds and #w.clones == 0 and #w.started == 0 and b.agentFlight == nil and b.s.agents[TARGET] == nil)
		State.agentFailed(b.s, "acme/api#116", "No clone was found", nil)
		Block.event(b, { ev = "action", act = "card-agent-retry", value = "acme/api#116" } :: any, w.cx)
		assert(#w.finds == finds + 1 and #w.clones == 1 and b.agentFlight ~= nil, "a PR nobody watches still starts")
	end)

	-- Each delayed step re-checks. A board that arrives with the flag set (a refresh, or another window's cache)
	-- does not pass through the watch read, so the flag is set by hand and the step's answer is settled after.
	local function flagged(b: any)
		local pr: any = State.prOf(b.s, TARGET)
		pr.tandem = true
	end
	local function drive(act: string, holdRoot: boolean?, settle: (w: any, b: any) -> ())
		withWorld(function(w, Fetch, Block)
			local b = agentBoard(w, Fetch, Block)
			w.holdRoot = holdRoot == true
			Block.event(b, { ev = "action", act = act, value = TARGET } :: any, w.cx)
			assert(b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running")
			settle(w, b)
			noFixer(w, b, act)
			assert(#w.toasts == 0 and #w.encoded == 0)
		end)
	end
	-- The repository lookup is out.
	drive("card-agent", true, function(w, b)
		assert(#w.finds == 2 and #w.clones == 0)
		flagged(b)
		w.finds[2].done({ root = REPO_ROOT }, nil)
		assert(#w.clones == 0 and gh(w) == nil)
	end)
	-- The clone lookup is out.
	drive("card-agent", false, function(w, b)
		assert(#w.clones == 1)
		flagged(b)
		w.clones[1].done("/clone", nil)
		assert(gh(w) == nil, "no PR refs are read for a PR Tandem owns")
	end)
	-- The folder question is out.
	drive("card-agent-folder", false, function(w, b)
		local finds = #w.finds
		local ask = w.calls[#w.calls]
		assert(ask.argv[1] == "osascript")
		flagged(b)
		ask.done(out("/Users/reader/clone\n"))
		assert(#w.finds == finds and #w.clones == 0, "the chosen folder is not looked at")
	end)
	-- The bot feedback read is out.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		b.botKeys[TARGET] = true
		Block.event(b, { ev = "action", act = "card-agent-clone", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		assert(#w.details == 1 and b.agentFlight ~= nil)
		flagged(b)
		w.details[1].done(nil, { operation = "details", message = "late" })
		noFixer(w, b, "bot feedback")
		assert(gh(w) == nil and #w.toasts == 0, "it ends as stopped, not as a failure")
	end)
	-- The PR refs are out: the last step before the engine starts. The same sequence on an unwatched PR starts one.
	for _, owned in { true, false } do
		withWorld(function(w, Fetch, Block)
			local b = agentBoard(w, Fetch, Block)
			Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
			w.clones[1].done("/clone", nil)
			local refs = gh(w)
			assert(refs ~= nil)
			equal(refs.argv, { "gh", "pr", "view", "105", "--repo", "acme/api", "--json", "headRefName,baseRefName,headRefOid" })
			if owned then flagged(b) end
			refs.done(out("REFS"))
			if owned then
				noFixer(w, b, "refs")
			else
				assert(#w.started == 1 and w.started[1].request.key == TARGET and b.agentFlight ~= nil and b.agentFlight.engine ~= nil)
			end
		end)
	end

	-- A watch read that names the PR while its fix is being set up settles that fix at once: stopped, with no worktree
	-- held, and the late folder answer starts nothing.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		Block.event(b, { ev = "action", act = "card-agent-folder", value = TARGET } :: any, w.cx)
		local ask = w.calls[#w.calls]
		assert(ask.argv[1] == "osascript" and b.s.agents[TARGET].kind == "running")
		claim(w, Block, b)
		noFixer(w, b, "claimed")
		local finds = #w.finds
		ask.done(out("/Users/reader/clone\n"))
		assert(#w.finds == finds and #w.clones == 0 and #w.started == 0 and b.agentFlight == nil and #w.toasts == 0)
		Block.event(b, { ev = "action", act = "card-agent-stop", value = TARGET } :: any, w.cx)
		assert(b.s.agents[TARGET] == nil and w.stops == 0)
	end)

	-- An engine that already holds a worktree is not cut off: Stop still reaches it.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		gh(w).done(out("REFS"))
		assert(#w.started == 1 and b.agentFlight.engine ~= nil and b.s.agents[TARGET].kind == "running")
		claim(w, Block, b)
		assert(#w.started == 1 and b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running" and w.stops == 0, "the running engine is left alone")
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		Block.event(b, { ev = "action", act = "card-agent-retry", value = TARGET } :: any, w.cx)
		assert(#w.started == 1 and #w.toasts == 0)
		Block.event(b, { ev = "action", act = "card-agent-stop", value = TARGET } :: any, w.cx)
		assert(w.stops == 1, "Stop still stops it")
	end)
end

-- A cache another run or window stored at `at`, with `owned` (keys) flagged as Tandem's.
local function storedCache(owned: { string }, at: number): any
	local tandem: { [string]: boolean } = {}
	for _, key in owned do tandem[key] = true end
	local fresh: any = { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
	return Sync.save(Sync.merge(fresh, nil, { added = {}, tandem = tandem }, at), math.huge, function() return 1 end)
end

-- A GitHub client that answers `refresh` as the test settles it and nothing else.
local function quietGithub(refresh: (opts: any, done: (any, any) -> ()) -> ()): any
	return setmetatable({ refresh = refresh }, { __index = function(): any return function() end end })
end

local function needFixesOf(b: any): number
	local count = 0
	for _, pr in b.s.prs do
		if Model.classify(pr, b.s.now) == "needs_fixes" then count += 1 end
	end
	return count
end

local WEB, API114 = "acme/web#104", "acme/api#114"

-- A refresh or an adopted cache stamps the board with the real clock; the recorded PRs are dated to `Cases.asOf`.
local function frozen(b: any)
	State.replace(b.s, b.s.prs, Cases.asOf, Cases.asOfIso)
end

-- A board that opens from a cache holding Tandem's flags keeps them until a read of Tandem succeeds.
local function cachedStartup()
	local function owned(b: any)
		for _, key in { WEB, API114 } do
			local mine = card(b.s, key)
			assert(mine.pr.tandem and mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem", key)
			assert(mine.main and mine.main.act == "card-handoff" and not offers(mine, "card-agent"), key)
		end
	end

	-- The first read fails: nothing moves, and no fixer starts on a PR it names.
	withWorld(function(w, Fetch, Block)
		w.kvIn = { ["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf) }
		local b = live(w, Block, true)
		owned(b)
		assert(b.watched[WEB] == true and b.watched[API114] == true and #reads(w) == 1)
		local needFixes = b.cache.counts.needFixes
		reads(w)[1].done(out("nope"))
		owned(b)
		assert(b.watched[WEB] == true and b.s.error == nil and not b.flights.tandem and b.cache.counts.needFixes == needFixes)
		Block.event(b, { ev = "action", act = "card-agent", value = WEB } :: any, w.cx)
		assert(b.agentFlight == nil and b.s.agents[WEB] == nil and gh(w) == nil and #w.toasts == 0)
	end)

	-- A failed read that exits nonzero or times out changes nothing either.
	for _, failure in { out("", 1, "no daemon"), out("", 0, "", true) } do
		withWorld(function(w, Fetch, Block)
			w.kvIn = { ["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf) }
			local b = live(w, Block, true)
			reads(w)[1].done(failure)
			owned(b)
		end)
	end

	-- GitHub's refresh answers before the first read of Tandem: the cache's ownership stands, and the read that
	-- follows is authoritative, so one that no longer names a PR clears it.
	withWorld(function(w, Fetch, Block)
		w.kvIn = { ["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf) }
		local b = live(w, Block, true)
		local answer: any = nil
		b.github = quietGithub(function(_, done) answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(answer ~= nil and #reads(w) == 1 and b.flights.tandem, "the first read is still out")
		answer({ viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }, nil)
		frozen(b)
		owned(b)
		for _, saved in { b.cache, w.kv["hub.cache"] } do
			for _, key in { WEB, API114 } do
				for _, cached in saved.prs do
					if cached.key == key then assert(cached.tandem == true, key) end
				end
			end
		end

		local later = copy(RawWatch)
		local rows = {}
		for _, row in later.rows do
			if row.number ~= 104 then table.insert(rows, row) end
		end
		later.rows = rows
		w.decoded["LATER"] = later
		reads(w)[1].done(out("LATER"))
		assert(not card(b.s, WEB).pr.tandem and card(b.s, WEB).column == "needs_fixes" and card(b.s, WEB).main.label == "Fix with agent")
		assert(card(b.s, API114).pr.tandem and b.watched[WEB] == nil)
		assert(b.cache.counts.needFixes == needFixesOf(b) and w.kv["hub.status"].counts.needFixes == needFixesOf(b))
	end)
end

-- Window A accepted a hand-off; window B stored a newer cache from an older read of Tandem. Adopting it keeps A's flag.
local function sharedCache()
	local KEY = "acme/api#116"
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		reads(w)[1].done(out("WATCH"))
		local fresh: any = { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
		b.cache = Sync.merge(fresh, nil, { added = {}, tandem = Model.tandemFlags(b.watched, fresh.prs) }, Cases.asOf)
		State.replace(b.s, b.cache.prs, Cases.asOf, Cases.asOfIso)
		Block.event(b, { ev = "action", act = "card-handoff", value = KEY } :: any, w.cx)
		handoffs(w)[1].done(out("KEPT"))
		assert(card(b.s, KEY).pr.tandem and b.watched[KEY] == true)

		-- B's cache is newer and does not name the PR. The timers the block armed when it opened run its refresh tick,
		-- which adopts the shared cache before it starts a read of Tandem and a refresh that never answers.
		local theirs = storedCache({ WEB, API114 }, Cases.asOf + 60)
		w.kvIn = { ["hub.cache"] = theirs }
		b.github = quietGithub(function() end)
		runTimers(w)
		assert(b.cache.refreshedAt == theirs.refreshedAt, "the other window's cache was adopted")
		assert(b.cache.counts.needFixes == needFixesOf(b) and w.kv["hub.status"].counts.needFixes == needFixesOf(b), "counted with A's flags")
		for _, cached in b.cache.prs do
			if cached.key == KEY then assert(cached.tandem == true) end
		end
		frozen(b)
		local mine = card(b.s, KEY)
		assert(mine.pr.tandem and mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem", "an accepted hand-off survives adoption")
		assert(mine.main and mine.main.act == "card-handoff" and not offers(mine, "card-agent"))
		assert(card(b.s, WEB).pr.tandem and card(b.s, API114).pr.tandem)

		-- Only a read of Tandem that began after the hand-off and omits the PR clears it.
		assert(#reads(w) == 2)
		reads(w)[2].done(out("WATCH"))
		assert(not card(b.s, KEY).pr.tandem and card(b.s, KEY).column == "needs_fixes" and card(b.s, KEY).main.label == "Fix with agent")
		assert(b.cache.counts.needFixes == needFixesOf(b) and w.kv["hub.status"].counts.needFixes == needFixesOf(b))
	end)
end

-- A card Tandem owns shows Waiting on Tandem and Hand off to Tandem, never the Clone repo or Try again of a fix that
-- cannot start. Whichever way the ownership arrives, a failed or missing-clone state with no worktree is dropped; a
-- failed one that still names a worktree keeps it (Open worktree) and offers no retry.
local function terminalAgents()
	local function projected(w: any, b: any, why: string)
		local mine = card(b.s, TARGET)
		assert(mine.pr.tandem and mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem" and #mine.chips == 1, why)
		assert(mine.main and mine.main.act == "card-handoff" and mine.main.label == "Hand off to Tandem" and mine.main.key == "A", why)
		for _, forbidden in { "card-agent", "card-agent-retry", "card-agent-clone", "card-agent-folder", "card-summarize" } do
			assert(not offers(mine, forbidden), why .. ": " .. forbidden)
		end
		return mine
	end
	local function aPresses(w: any, b: any, why: string)
		State.select(b.s, TARGET)
		local before = #handoffs(w)
		press(w, "a")
		local sent = handoffs(w)
		assert(#sent == before + 1 and sent[#sent].argv[3] == "act" and b.agentFlight == nil and #w.started == 0, why .. ": A hands off")
	end

	for _, terminal in { "failed", "no_clone" } do
		withWorld(function(w, Fetch, Block)
			local b = agentBoard(w, Fetch, Block)
			if terminal == "failed" then State.agentFailed(b.s, TARGET, "No clone was found", nil) else State.noAgentClone(b.s, TARGET, "acme/api") end
			local plain = card(b.s, TARGET)
			assert(plain.main and plain.main.act == (if terminal == "failed" then "card-agent-retry" else "card-agent-clone"), "an unwatched card recovers as before")
			claim(w, Block, b)
			assert(b.s.agents[TARGET] == nil, terminal .. ": the obsolete state is dropped")
			assert(projected(w, b, terminal).agent == nil)
			aPresses(w, b, terminal)
		end)

		-- Ownership that arrives with a hand-off drops it too.
		withWorld(function(w, Fetch, Block)
			local b = agentBoard(w, Fetch, Block)
			if terminal == "failed" then State.agentFailed(b.s, TARGET, "No clone was found", nil) else State.noAgentClone(b.s, TARGET, "acme/api") end
			Block.event(b, { ev = "action", act = "card-handoff", value = TARGET } :: any, w.cx)
			handoffs(w)[1].done(out("DONE"))
			assert(b.s.agents[TARGET] == nil)
			projected(w, b, terminal .. " by hand-off")
		end)

		-- And so does a cache another window stored, adopted by a block whose own set names the PR.
		withWorld(function(w, Fetch, Block)
			local b = agentBoard(w, Fetch, Block)
			if terminal == "failed" then State.agentFailed(b.s, TARGET, "No clone was found", nil) else State.noAgentClone(b.s, TARGET, "acme/api") end
			b.github = quietGithub(function() end)
			b.watched[TARGET] = true
			w.kvIn = { ["hub.cache"] = storedCache({ WEB, API114, TARGET }, Cases.asOf + 60) }
			runTimers(w)
			assert(b.s.agents[TARGET] == nil)
			frozen(b)
			projected(w, b, terminal .. " by shared cache")
		end)
	end

	-- A cache that opens the board with ownership has no state to drop, and shows the Tandem card at once.
	withWorld(function(w, Fetch, Block)
		w.kvIn = { ["hub.cache"] = storedCache({ WEB }, Cases.asOf) }
		local b = live(w, Block, true)
		State.noAgentClone(b.s, WEB, "acme/web")
		assert(b.s.agents[WEB] == nil and card(b.s, WEB).main.act == "card-handoff")
	end)

	-- A failed state that still names a worktree keeps it for cleanup: Open worktree stays, Try again is gone, and the
	-- card's A is the hand-off.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		State.agentFailed(b.s, TARGET, "boom", "/work/tree")
		claim(w, Block, b)
		local kept = b.s.agents[TARGET]
		assert(kept and kept.kind == "failed" and kept.worktree == "/work/tree", "the retained worktree is not discarded")
		local mine = projected(w, b, "retained")
		assert(mine.agent == kept and offers(mine, "card-agent-worktree") and mine.agentMessage ~= nil)
		Block.event(b, { ev = "action", act = "card-agent-retry", value = TARGET } :: any, w.cx)
		assert(b.agentFlight == nil and #w.started == 0 and b.s.agents[TARGET] == kept and #w.toasts == 0)
		aPresses(w, b, "retained")
	end)

	-- A running engine stays Stop's, and its card keeps Stop.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		gh(w).done(out("REFS"))
		claim(w, Block, b)
		local running = card(b.s, TARGET)
		assert(running.agent and running.agent.kind == "running" and running.main and running.main.act == "card-agent-stop")
	end)
end

-- Window B accepted a hand-off and stored a newer cache that flags the PR, while this window's own (older) successful
-- read of Tandem omits it. Adopting B's cache adds the PR to this window's ownership, whatever happens to the next
-- read; only a later successful read of its own clears it.
local function reverseSharedCache()
	local KEY = "acme/api#116"
	local function owned(w: any, b: any, why: string)
		local mine = card(b.s, KEY)
		assert(mine.pr.tandem and mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem" and b.watched[KEY] == true, why)
		assert(mine.main and mine.main.act == "card-handoff" and not offers(mine, "card-agent"), why)
		w.Block.event(b, { ev = "action", act = "card-agent", value = KEY } :: any, w.cx)
		assert(b.agentFlight == nil and b.s.agents[KEY] == nil and gh(w) == nil, why .. ": no local fixer")
	end

	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		reads(w)[1].done(out("WATCH"))
		local fresh: any = { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
		b.cache = Sync.merge(fresh, nil, { added = {}, tandem = Model.tandemFlags(b.watched, fresh.prs) }, Cases.asOf)
		State.replace(b.s, b.cache.prs, Cases.asOf, Cases.asOfIso)
		assert(b.watched[KEY] == nil and not card(b.s, KEY).pr.tandem)

		local theirs = storedCache({ WEB, API114, KEY }, Cases.asOf + 60)
		w.kvIn = { ["hub.cache"] = theirs }
		b.github = quietGithub(function() end)
		runTimers(w)
		assert(b.cache.refreshedAt == theirs.refreshedAt, "the other window's cache was adopted")
		-- The cache already flags the PR, so adopting it moves no card: the counts it carries stand, and the window that
		-- stored it wrote the status, so none is written here.
		assert(b.cache.counts.needFixes == needFixesOf(b), "counted with the new owner")
		frozen(b)
		owned(w, b, "adopted")

		-- The read that follows fails: the ownership stands.
		assert(#reads(w) == 2 and b.flights.tandem)
		reads(w)[2].done(out("nope"))
		owned(w, b, "after a failed read")
		assert(b.s.error == nil and not b.flights.tandem)

		-- A successful read that began after the adoption and omits the PR clears it.
		b.flights.refresh = false
		b.github = { refresh = function() end }
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(#reads(w) == 3)
		reads(w)[3].done(out("WATCH"))
		assert(not card(b.s, KEY).pr.tandem and b.watched[KEY] == nil and card(b.s, KEY).column == "needs_fixes" and card(b.s, KEY).main.label == "Fix with agent")
		assert(b.cache.counts.needFixes == needFixesOf(b) and w.kv["hub.status"].counts.needFixes == needFixesOf(b))
	end)

	-- The block's first read is still out when the cache arrives. It began before the hand-off, so its answer, which
	-- omits the PR, is dropped and read again; a failure of that read keeps the ownership too.
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		assert(#reads(w) == 1 and b.flights.tandem)
		w.kvIn = { ["hub.cache"] = storedCache({ WEB, API114, KEY }, Cases.asOf + 60) }
		b.github = quietGithub(function() end)
		runTimers(w)
		frozen(b)
		owned(w, b, "adopted while a read is out")
		reads(w)[1].done(out("WATCH"))
		owned(w, b, "the older read does not clear it")
		assert(#reads(w) == 2 and b.flights.tandem)
		reads(w)[2].done(out("", 1, "no daemon"))
		owned(w, b, "the newer read failed")
		assert(#reads(w) == 2 and not b.flights.tandem)
	end)
end

-- This window's GitHub refresh is out when window B stores a newer cache that flags a PR this window's set lacks. The
-- delayed answer joins that ownership before it is merged and persisted, so the stored cache keeps the flag, and the
-- read of Tandem that began before the join is read again instead of clearing it.
local function delayedRefresh()
	local KEY = "acme/api#116"
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		reads(w)[1].done(out("WATCH"))
		local fresh: any = { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
		b.cache = Sync.merge(fresh, nil, { added = {}, tandem = Model.tandemFlags(b.watched, fresh.prs) }, Cases.asOf)
		State.replace(b.s, b.cache.prs, Cases.asOf, Cases.asOfIso)
		local answer: any = nil
		b.github = quietGithub(function(_, done) answer = done end)

		-- 1. This window's refresh and its own read of Tandem start, both before B has stored anything.
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(answer ~= nil and b.flights.refresh and b.flights.tandem and #reads(w) == 2)
		assert(b.watched[KEY] == nil and not card(b.s, KEY).pr.tandem)

		-- 2. B stores a newer cache that flags the PR, and nothing here has seen it yet.
		w.kvIn = { ["hub.cache"] = storedCache({ WEB, API114, KEY }, Cases.asOf + 60) }
		assert(b.watched[KEY] == nil)

		-- 3. The delayed GitHub answer arrives. What it persists keeps B's flag, and the board shows it at once.
		answer({ viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }, nil)
		frozen(b)
		assert(b.watched[KEY] == true and b.handoffs >= 1, "B's ownership joined before the merge")
		local stored = w.kv["hub.cache"]
		assert(stored ~= nil)
		for _, saved in { b.cache, stored } do
			local seen = false
			for _, cached in saved.prs do
				if cached.key == KEY then seen = true; assert(cached.tandem == true, "the persisted cache keeps B's flag") end
			end
			assert(seen)
		end
		local mine = card(b.s, KEY)
		assert(mine.pr.tandem and mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem" and mine.main and mine.main.act == "card-handoff" and not offers(mine, "card-agent"))
		w.Block.event(b, { ev = "action", act = "card-agent", value = KEY } :: any, w.cx)
		assert(b.agentFlight == nil and b.s.agents[KEY] == nil and gh(w) == nil, "no local fixer")

		-- 4. The read that began before the join omits the PR. It is dropped and read again, and the ownership stands.
		reads(w)[2].done(out("WATCH"))
		assert(#reads(w) == 3 and b.flights.tandem and b.watched[KEY] == true and card(b.s, KEY).pr.tandem, "the older read did not clear it")
		for _, cached in b.cache.prs do
			if cached.key == KEY then assert(cached.tandem == true) end
		end

		-- 5. Only the read that began after the join clears it.
		reads(w)[3].done(out("WATCH"))
		assert(b.watched[KEY] == nil and not card(b.s, KEY).pr.tandem and card(b.s, KEY).column == "needs_fixes" and card(b.s, KEY).main.label == "Fix with agent")
		assert(b.cache.counts.needFixes == needFixesOf(b))
	end)

	-- B's silence about a PR this window holds never clears it, and an older cache joins nothing.
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		reads(w)[1].done(out("WATCH"))
		local fresh: any = { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
		b.cache = Sync.merge(fresh, nil, { added = {}, tandem = Model.tandemFlags(b.watched, fresh.prs) }, Cases.asOf + 120)
		State.replace(b.s, b.cache.prs, Cases.asOf, Cases.asOfIso)
		local answer: any = nil
		b.github = quietGithub(function(_, done) answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		w.kvIn = { ["hub.cache"] = storedCache({ "acme/api#116" }, Cases.asOf + 60) }
		answer({ viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }, nil)
		assert(b.watched["acme/api#116"] == nil and #reads(w) == 2 and b.watched[WEB] == true and b.watched[API114] == true)
	end)
end

-- Two windows share one store. A hand-off keeps the cache's own `refreshedAt`, so the window that took it stores the
-- stamp the other window already holds, and that window's delayed refresh must still join it. A read of Tandem that
-- returns before the refresh joins a strictly newer cache first, so it is dropped and cannot overwrite it.
local function sharedStore()
	local KEY = "acme/api#116"
	local function keeps(cache: any, why: string)
		local seen = false
		for _, saved in cache.prs do
			if saved.key == KEY then seen = true; assert(saved.tandem == true, why) end
		end
		assert(seen, why)
	end
	local function fresh(): any
		return { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
	end

	-- A cache of the same stamp: window B hands the PR off for real, and window A's delayed refresh keeps the flag.
	withWorld(function(w, Fetch, Block)
		w.shared = true
		w.kv["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf)
		local a = live(w, Block, true)
		local cxA = w.cx
		local other = live(w, Block, true)
		local cxB = w.cx
		assert(#reads(w) == 2 and a.cache.refreshedAt == other.cache.refreshedAt)
		reads(w)[1].done(out("WATCH"))
		reads(w)[2].done(out("WATCH"))
		local answer: any = nil
		a.github = quietGithub(function(_, done) answer = done end)
		Block.event(a, { ev = "action", act = "hub-refresh", value = "" } :: any, cxA)
		assert(answer ~= nil and a.flights.refresh and #reads(w) == 3 and a.watched[KEY] == nil)

		Block.event(other, { ev = "action", act = "card-handoff", value = KEY } :: any, cxB)
		assert(#handoffs(w) == 1)
		handoffs(w)[1].done(out("KEPT"))
		assert(other.watched[KEY] == true and other.cache.refreshedAt == a.cache.refreshedAt)
		keeps(w.kv["hub.cache"], "the hand-off was stored")
		assert(w.kv["hub.cache"].refreshedAt == a.cache.refreshedAt, "the hand-off kept the stamp")
		assert(a.watched[KEY] == nil and a.handoffs == 0, "A has not seen it")

		answer(fresh(), nil)
		frozen(a)
		assert(a.watched[KEY] == true and a.handoffs >= 1, "the same-stamp ownership joined")
		keeps(a.cache, "A's cache")
		keeps(w.kv["hub.cache"], "what A stored")
		local mine = card(a.s, KEY)
		assert(mine.pr.tandem and mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem" and mine.main and mine.main.act == "card-handoff" and not offers(mine, "card-agent"))
		Block.event(a, { ev = "action", act = "card-agent", value = KEY } :: any, cxA)
		assert(a.agentFlight == nil and a.s.agents[KEY] == nil and gh(w) == nil, "no local fixer")

		-- A's read that began before the join is dropped and read again.
		reads(w)[3].done(out("WATCH"))
		assert(#reads(w) == 4 and a.flights.tandem)
	end)

	-- Silence at the same stamp never clears ownership, and a cache that is not newer is not adopted.
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		reads(w)[1].done(out("WATCH"))
		b.cache = Sync.merge(fresh(), nil, { added = {}, tandem = Model.tandemFlags(b.watched, fresh().prs) }, Cases.asOf + 60)
		State.replace(b.s, b.cache.prs, Cases.asOf, Cases.asOfIso)
		local answer: any = nil
		b.github = quietGithub(function(_, done) answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		w.kvIn = { ["hub.cache"] = storedCache({}, Cases.asOf + 60) }
		answer(fresh(), nil)
		assert(b.watched[WEB] == true and b.watched[API114] == true and b.handoffs == 0 and #reads(w) == 2, "nothing joined and nothing cleared")
	end)

	-- Window B stores a strictly newer cache while A's read of Tandem and refresh are out; the read returns first.
	withWorld(function(w, Fetch, Block)
		w.shared = true
		w.kv["hub.cache"] = storedCache({}, Cases.asOf)
		local a = live(w, Block, true)
		reads(w)[1].done(out("WATCH"))
		assert(a.watched[WEB] == true and w.kv["hub.cache"].refreshedAt == a.cache.refreshedAt)
		local answer: any = nil
		a.github = quietGithub(function(_, done) answer = done end)
		Block.event(a, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(answer ~= nil and #reads(w) == 2 and a.flights.tandem)

		local theirs = storedCache({ WEB, API114, KEY }, Cases.asOf + 60)
		w.kv["hub.cache"] = theirs
		assert(a.watched[KEY] == nil)

		-- Its answer names another PR, so applying it would change the board and store A's older cache over B's.
		w.decoded["OLDER"] = watchWith({ "acme/web#101" })
		reads(w)[2].done(out("OLDER"))
		assert(a.watched[KEY] == true and a.watched["acme/web#101"] == nil, "B's ownership joined and the older answer was dropped")
		assert(#reads(w) == 3 and a.flights.tandem, "read again")
		assert(same(w.kv["hub.cache"], theirs), "the older read stored nothing")
		keeps(w.kv["hub.cache"], "B's cache stands")
		assert(not card(a.s, "acme/web#101").pr.tandem)

		-- The GitHub answer then keeps the flag too.
		answer(fresh(), nil)
		frozen(a)
		keeps(a.cache, "A's cache")
		keeps(w.kv["hub.cache"], "what A stored")
		assert(card(a.s, KEY).pr.tandem and card(a.s, KEY).column == "in_review")

		-- The read made after the join is the one that applies.
		reads(w)[3].done(out("OLDER"))
		assert(a.watched["acme/web#101"] == true and card(a.s, "acme/web#101").pr.tandem and not a.flights.tandem)
	end)

	-- Joined ownership guards the card before the read that is read again, or the refresh, answers. A fix still being
	-- set up for the PR ends as stopped, the card drops Fix with agent and the merges, and the older cache is not stored.
	withWorld(function(w, Fetch, Block)
		w.shared = true
		w.kv["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf)
		local b = agentBoard(w, Fetch, Block)
		w.holdRoot = true
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		assert(b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running")
		local lookup = w.finds[#w.finds]
		w.holdRoot = false
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local out_ = #reads(w)
		assert(b.flights.tandem and b.flights.refresh)

		local theirs = storedCache({ WEB, API114, TARGET }, Cases.asOf + 60)
		w.kv["hub.cache"] = theirs
		reads(w)[out_].done(out("WATCH"))
		-- Nothing has answered since: the replacement read and the refresh are both still out.
		assert(#reads(w) == out_ + 1 and b.flights.tandem and b.flights.refresh and b.watched[TARGET] == true)
		local mine = card(b.s, TARGET)
		assert(mine.pr.tandem == true, "the flag is on the card")
		for _, forbidden in { "card-agent", "card-merge", "card-auto", "card-update" } do assert(not offers(mine, forbidden), forbidden) end
		noFixer(w, b, "a fix being set up")
		assert(b.cache.prs == b.s.prs and same(w.kv["hub.cache"], theirs), "the older cache was not stored")
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		Block.event(b, { ev = "action", act = "card-merge", value = TARGET } :: any, w.cx)
		noFixer(w, b, "A on the card")
		-- The late lookup starts nothing, and the read that began after the join is the one that applies.
		lookup.done({ root = REPO_ROOT }, nil)
		noFixer(w, b, "the late lookup")
		assert(#w.clones == 0)
		reads(w)[out_ + 1].done(out("WATCH"))
		assert(not b.flights.tandem and State.prOf(b.s, TARGET).tandem == false, "a read that began after the join clears it")
	end)

	-- Windows A and B hold one cache. A reads Tandem, flags a PR and stores it without moving `refreshedAt`; B's own
	-- hand-off of another PR then stores B's list, which must keep A's flag instead of restoring it to false.
	withWorld(function(w, Fetch, Block)
		w.shared = true
		w.kv["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf)
		local a = live(w, Block, true)
		local cxA = w.cx
		local other = live(w, Block, true)
		local cxB = w.cx
		reads(w)[1].done(out("WATCH"))
		reads(w)[2].done(out("WATCH"))
		a.github = quietGithub(function() end)
		w.decoded["READ_K"] = watchWith({ KEY })
		Block.event(a, { ev = "action", act = "hub-refresh", value = "" } :: any, cxA)
		reads(w)[3].done(out("READ_K"))
		assert(a.watched[KEY] == true and w.kv["hub.cache"].refreshedAt == other.cache.refreshedAt)
		keeps(w.kv["hub.cache"], "A flagged it")
		assert(other.watched[KEY] == nil and not State.prOf(other.s, KEY).tandem, "B has not seen it")

		local HANDED = "acme/web#101"
		Block.event(other, { ev = "action", act = "card-handoff", value = HANDED } :: any, cxB)
		assert(#handoffs(w) == 1)
		handoffs(w)[1].done(out("KEPT"))
		assert(other.watched[HANDED] == true and other.watched[KEY] == true, "B's hand-off joined A's flag")
		assert(State.prOf(other.s, KEY).tandem == true and State.prOf(other.s, HANDED).tandem == true)
		keeps(w.kv["hub.cache"], "B's hand-off kept A's flag")
		local both = 0
		for _, saved in w.kv["hub.cache"].prs do
			if saved.key == HANDED then assert(saved.tandem == true, "and its own"); both += 1 end
		end
		assert(both == 1)
		assert(w.kv["hub.cache"].refreshedAt == a.cache.refreshedAt, "the stamp stays")
	end)

	-- The same for a checks update: it is no word on ownership, so another window's flag at the same stamp stays.
	withWorld(function(w, Fetch, Block)
		w.shared = true
		w.kv["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf)
		local b = live(w, Block, true)
		reads(w)[1].done(out("WATCH"))
		local settle: any = nil
		b.github = setmetatable({ checks = function(_, done) settle = done end }, { __index = function(): any return function() end end })
		b.flights.refresh, b.flights.probe = true, true
		w.timers = {}
		Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, w.cx)
		w.kv["hub.cache"] = storedCache({ WEB, API114, KEY }, Cases.asOf)
		runTimers(w)
		assert(settle ~= nil and b.flights.checks and b.watched[KEY] == nil)
		local running = State.prOf(b.s, API114)
		assert(running and running.checks.state == "pending")
		settle({ byId = { [running.id] = { headOid = running.headOid, checks = { state = "passing", passing = 3, failing = 0, pending = 0 } } } }, nil)
		assert(State.prOf(b.s, API114).checks.state == "passing", "the update applied")
		assert(b.watched[KEY] == true and State.prOf(b.s, KEY).tandem == true)
		keeps(w.kv["hub.cache"], "the checks write kept the flag")
		keeps(b.cache, "the block's cache")
	end)
end

-- Three windows over one store at mixed ages. A and C hold the newer cache (T2) and B the older (T1); C's GitHub refresh is
-- out. A reads Tandem and flags KEY without moving `refreshedAt`. B then writes an action or a checks result. B's write
-- must land on the newer cache: the stamp stays T2, the newer snapshot stays, KEY stays flagged, and C's answer keeps it.
local function mixedAge()
	local KEY, REMOVED, HANDED = "acme/api#116", "acme/web#303", "acme/web#101"
	local T2 = Cases.asOf + 120
	local NEWER = "Retitled by the newer refresh"
	-- The PR REMOVED was added by link: the stored caches say so, as `hub.added` would have when they were written.
	local function added(cache: any): any
		for _, saved in cache.prs do
			if saved.key == REMOVED then saved.addedByMe = true end
		end
		return cache
	end
	local function newer(owned: { string }): any
		local cache = added(storedCache(owned, T2))
		for _, saved in cache.prs do
			if saved.key == API114 then saved.title = NEWER end
		end
		return cache
	end
	local function entry(cache: any, key: string): any
		for _, saved in cache.prs do
			if saved.key == key then return saved end
		end
		return nil
	end
	local stamp = storedCache({}, T2).refreshedAt

	local function schedule(name: string, prepare: ((w: any, b: any, cxB: any) -> any)?, act: (w: any, b: any, cxB: any, held: any) -> ())
		withWorld(function(w, Fetch, Block)
			w.shared = true
			w.kv["hub.cache"] = added(storedCache({ WEB, API114 }, Cases.asOf))
			local a = live(w, Block, true)
			local cxA = w.cx
			local b = live(w, Block, true)
			local cxB = w.cx
			local c = live(w, Block, true)
			local cxC = w.cx
			assert(#reads(w) == 3)
			for i = 1, 3 do reads(w)[i].done(out("WATCH")) end
			local held = if prepare then prepare(w, b, cxB) else nil
			assert(a.cache.refreshedAt == b.cache.refreshedAt and b.watched[KEY] == nil)

			-- A and C take the newer cache, which flags nothing new. C's GitHub refresh is out.
			w.kv["hub.cache"] = newer({ WEB, API114 })
			Block.event(a, { ev = "action", act = "hub-focused", value = "" } :: any, cxA)
			Block.event(c, { ev = "action", act = "hub-focused", value = "" } :: any, cxC)
			assert(a.cache.refreshedAt == stamp and c.cache.refreshedAt == stamp and b.cache.refreshedAt ~= stamp, name .. ": mixed ages")
			local answerC: any = nil
			c.github = quietGithub(function(_, done) answerC = done end)
			Block.event(c, { ev = "action", act = "hub-refresh", value = "" } :: any, cxC)
			assert(answerC ~= nil and c.flights.refresh and #reads(w) == 4)
			reads(w)[4].done(out("WATCH"))

			-- A reads Tandem, which now names KEY: stored at T2 over the newer snapshot.
			a.github = quietGithub(function() end)
			w.decoded["READ_K"] = watchWith({ KEY })
			Block.event(a, { ev = "action", act = "hub-refresh", value = "" } :: any, cxA)
			assert(#reads(w) == 5)
			reads(w)[5].done(out("READ_K"))
			assert(a.watched[KEY] == true and w.kv["hub.cache"].refreshedAt == stamp, name .. ": A stored KEY")
			assert(entry(w.kv["hub.cache"], KEY).tandem == true and entry(w.kv["hub.cache"], API114).title == NEWER)
			assert(b.watched[KEY] == nil and not State.prOf(b.s, KEY).tandem and c.watched[KEY] == nil, name .. ": B and C have not seen it")

			act(w, b, cxB, held)
			local stored = w.kv["hub.cache"]
			assert(stored.refreshedAt == stamp, name .. ": the stamp never goes back")
			assert(entry(stored, API114).title == NEWER, name .. ": the newer snapshot stays")
			assert(entry(stored, KEY).tandem == true and entry(stored, WEB).tandem == true, name .. ": every flag stays")
			assert(b.cache.refreshedAt == stamp and b.watched[KEY] == true and State.prOf(b.s, KEY).tandem == true, name .. ": B joined")

			-- C's answer keeps the flag: Fix with agent never returns on the card.
			answerC({ viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }, nil)
			frozen(c)
			assert(c.watched[KEY] == true and State.prOf(c.s, KEY).tandem == true, name .. ": C joined")
			assert(entry(c.cache, KEY).tandem == true and entry(w.kv["hub.cache"], KEY).tandem == true, name .. ": C stored it")
			local owned = card(c.s, KEY)
			assert(owned.column == "in_review" and owned.chips[1].text == "Waiting on Tandem" and owned.main and owned.main.act == "card-handoff" and not offers(owned, "card-agent"))
			Block.event(c, { ev = "action", act = "card-agent", value = KEY } :: any, cxC)
			assert(c.agentFlight == nil and c.s.agents[KEY] == nil and gh(w) == nil, name .. ": no local fixer")
		end)
	end

	-- B hands another PR off.
	schedule("hand-off", nil, function(w, b, cxB)
		local before = #handoffs(w)
		w.Block.event(b, { ev = "action", act = "card-handoff", value = HANDED } :: any, cxB)
		assert(#handoffs(w) == before + 1)
		handoffs(w)[before + 1].done(out("KEPT"))
		assert(b.watched[HANDED] == true and entry(w.kv["hub.cache"], HANDED).tandem == true, "and its own flag")
	end)

	-- B removes an added PR: that change lands on the newer snapshot, and the PR is gone from what is stored.
	schedule("removal", nil, function(w, b, cxB)
		b.github = quietGithub(function() end)
		assert(entry(b.cache, REMOVED) and entry(w.kv["hub.cache"], REMOVED))
		-- Remove acts only on a visible card added by link, which the Review requests tab shows: without both, it is a no-op.
		State.setTab(b.s, "review")
		local row = State.card(b.s, REMOVED)
		assert(row and row.pr.addedByMe and entry(w.kv["hub.cache"], REMOVED).addedByMe == true, "the removal has something to remove")
		w.Block.event(b, { ev = "action", act = "card-remove", value = REMOVED } :: any, cxB)
		local kept = entry(w.kv["hub.cache"], REMOVED)
		assert(kept == nil or kept.addedByMe == false, "the removal was stored")
		local local_ = State.prOf(b.s, REMOVED)
		assert(local_ == nil or local_.addedByMe == false)
	end)

	-- B's checks result lands on the newer snapshot; its stamp and the newer title stay.
	schedule("checks", function(w, b, cxB)
		local settle: any = { done = nil }
		b.github = setmetatable({ checks = function(_, done) settle.done = done end }, { __index = function(): any return function() end end })
		b.flights.refresh, b.flights.probe = true, true
		w.timers = {}
		w.Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, cxB)
		local mine = w.timers
		w.timers = {}
		return { settle = settle, timers = mine }
	end, function(w, b, cxB, held)
		for _, fn in held.timers do fn() end
		assert(held.settle.done ~= nil and b.flights.checks)
		local running = State.prOf(b.s, API114)
		assert(running and running.checks.state == "pending")
		held.settle.done({ byId = { [running.id] = { headOid = running.headOid, checks = { state = "passing", passing = 3, failing = 0, pending = 0 } } } }, nil)
		assert(State.prOf(b.s, API114).checks.state == "passing", "the update applied")
		assert(entry(w.kv["hub.cache"], API114).checks.state == "passing", "and was stored on the newer snapshot")
	end)

	-- B's read of Tandem is out from the older cache when A stores KEY at T2. B's answer adopts the newer cache and joins
	-- KEY, so it stores nothing older and starts one replacement read; that read keeps KEY, adds OTHER, and stores T2.
	withWorld(function(w, Fetch, Block)
		local OTHER = "acme/api#105"
		w.shared = true
		w.kv["hub.cache"] = added(storedCache({ WEB, API114 }, Cases.asOf))
		-- Every store of the cache, in order.
		local writes: { { stamp: number, key: boolean, other: boolean, title: string? } } = {}
		local kv = getfenv(Block.init).tern.kv
		local set = kv.set
		kv.set = function(name: string, value: any)
			if name == "hub.cache" then
				table.insert(writes, {
					stamp = value.refreshedAt, key = entry(value, KEY).tandem == true,
					other = entry(value, OTHER).tandem == true, title = entry(value, API114).title,
				})
			end
			set(name, value)
		end
		local a = live(w, Block, true)
		local cxA = w.cx
		local b = live(w, Block, true)
		local c = live(w, Block, true)
		local cxC = w.cx
		assert(#reads(w) == 3 and b.flights.tandem and b.handoffs == 0)
		local older = reads(w)[2]
		reads(w)[1].done(out("WATCH"))
		reads(w)[3].done(out("WATCH"))
		assert(b.flights.tandem and not a.flights.tandem and not c.flights.tandem, "only B's read is out")
		local t1 = b.cache.refreshedAt
		assert(a.cache.refreshedAt == t1 and b.watched[KEY] == nil)
		table.clear(writes)

		-- A and C take the newer cache. C's GitHub refresh is out.
		w.kv["hub.cache"] = newer({ WEB, API114 })
		Block.event(a, { ev = "action", act = "hub-focused", value = "" } :: any, cxA)
		Block.event(c, { ev = "action", act = "hub-focused", value = "" } :: any, cxC)
		assert(a.cache.refreshedAt == stamp and c.cache.refreshedAt == stamp and b.cache.refreshedAt == t1 and t1 ~= stamp, "mixed ages")
		local answerC: any = nil
		c.github = quietGithub(function(_, done) answerC = done end)
		Block.event(c, { ev = "action", act = "hub-refresh", value = "" } :: any, cxC)
		assert(answerC ~= nil and c.flights.refresh and #reads(w) == 4)
		reads(w)[4].done(out("WATCH"))

		-- A's successful read names KEY: stored at T2.
		a.github = quietGithub(function() end)
		w.decoded["READ_K"] = watchWith({ KEY })
		Block.event(a, { ev = "action", act = "hub-refresh", value = "" } :: any, cxA)
		assert(#reads(w) == 5)
		reads(w)[5].done(out("READ_K"))
		assert(entry(w.kv["hub.cache"], KEY).tandem == true and w.kv["hub.cache"].refreshedAt == stamp)
		local stored = #writes
		assert(stored >= 1 and b.watched[KEY] == nil and not State.prOf(b.s, KEY).tandem and b.flights.tandem)

		-- B's older answer, which omits KEY, adopts T2 and joins KEY: it stores nothing, and the owned card shows at once.
		local rendered = w.renders
		older.done(out("WATCH"))
		assert(#writes == stored, "the older answer stored nothing")
		assert(b.cache.refreshedAt == stamp and entry(b.cache, API114).title == NEWER, "B holds T2")
		assert(b.watched[KEY] == true and b.handoffs == 1 and State.prOf(b.s, KEY).tandem == true, "B joined KEY")
		assert(w.renders > rendered, "and drew it")
		local mine = card(b.s, KEY)
		assert(mine.column == "in_review" and mine.chips[1].text == "Waiting on Tandem" and not offers(mine, "card-agent"))
		assert(#reads(w) == 6 and b.flights.tandem, "one replacement read is out")
		older.done(out("WATCH"))
		assert(#reads(w) == 6 and #writes == stored, "the older answer counts once")

		-- The replacement read keeps KEY, adds OTHER, and stores the newer snapshot.
		w.decoded["REPLACEMENT"] = watchWith({ KEY, OTHER })
		reads(w)[6].done(out("REPLACEMENT"))
		assert(not b.flights.tandem and #reads(w) == 6)
		assert(b.watched[KEY] == true and b.watched[OTHER] == true and State.prOf(b.s, KEY).tandem and State.prOf(b.s, OTHER).tandem)
		local latest = w.kv["hub.cache"]
		assert(latest.refreshedAt == stamp and entry(latest, KEY).tandem == true and entry(latest, OTHER).tandem == true and entry(latest, API114).title == NEWER)
		assert(#writes == stored + 1, "one store, from the replacement read")

		-- Every store so far is T2 and keeps the newer snapshot; none is the older cache, and no store dropped a flag once set.
		local seenKey, seenOther = false, false
		assert(#writes == stored + 1)
		for i, saved in writes do
			assert(saved.stamp ~= t1 and saved.stamp == stamp, "store " .. i .. " is not the older cache")
			assert(not (seenKey and not saved.key) and not (seenOther and not saved.other), "store " .. i .. " kept every flag")
			assert(saved.title == NEWER, "store " .. i .. " kept the newer snapshot")
			seenKey, seenOther = seenKey or saved.key, seenOther or saved.other
		end
		assert(seenKey and seenOther)

		-- C's delayed GitHub answer (a refresh, so it stamps the real clock) keeps both: Fix with agent never returns on either card.
		answerC({ viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }, nil)
		frozen(c)
		assert(c.watched[KEY] == true and c.watched[OTHER] == true and State.prOf(c.s, KEY).tandem and State.prOf(c.s, OTHER).tandem, "C joined both")
		assert(entry(w.kv["hub.cache"], KEY).tandem == true and entry(w.kv["hub.cache"], OTHER).tandem == true)
		for _, key in { KEY, OTHER } do
			local owned = card(c.s, key)
			assert(owned.chips[1].text == "Waiting on Tandem" and owned.main and owned.main.act == "card-handoff" and not offers(owned, "card-agent"), key)
			Block.event(c, { ev = "action", act = "card-agent", value = key } :: any, cxC)
		end
		assert(c.agentFlight == nil and gh(w) == nil, "no local fixer")
		for i = #writes - 1, #writes do
			assert(writes[i].stamp ~= t1 and writes[i].key and writes[i].other, "store " .. i .. " after C's answer keeps both flags")
		end
	end)
end

-- An Update branch queued before Tandem took the PR sends nothing once it owns it.
local function staleUpdate()
	local KEY = "acme/api#118"
	local function behind(w: any, Block: any): any
		local b = live(w, Block)
		w.runs = {}
		b.github = { refresh = function() end, run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end }
		return b
	end
	local function lag(b: any)
		local target: any = State.prOf(b.s, KEY)
		target.behind, target.conflicts, target.draft = true, false, false
		State.project(b.s)
	end

	-- Not watched: Update branch runs the command, so the guard below is what stops it.
	withWorld(function(w, Fetch, Block)
		local b = behind(w, Block)
		reads(w)[1].done(out("WATCH"))
		lag(b)
		assert(not State.prOf(b.s, KEY).tandem)
		Block.event(b, { ev = "action", act = "card-update", value = KEY } :: any, w.cx)
		assert(#w.runs == 1 and table.find(w.runs[1].command.argv, "update-branch") ~= nil and b.s.busy[KEY] == "Updating…")
	end)

	-- Tandem takes the PR after the action was queued: nothing runs and nothing is marked busy.
	withWorld(function(w, Fetch, Block)
		local b = behind(w, Block)
		lag(b)
		w.decoded["READ_K"] = watchWith({ KEY })
		reads(w)[1].done(out("READ_K"))
		local owned = card(b.s, KEY)
		assert(owned.pr.tandem and owned.column == "in_review" and not offers(owned, "card-update"))
		w.toasts = {}
		Block.event(b, { ev = "action", act = "card-update", value = KEY } :: any, w.cx)
		assert(#w.runs == 0 and gh(w) == nil and b.s.busy[KEY] == nil, "nothing is sent")
		assert(#w.toasts == 1 and w.toasts[1].kind == "error" and string.find(w.toasts[1].title, "Tandem watches this pull request", 1, true))
		assert(State.prOf(b.s, KEY).behind == true and not b.s.acted[KEY], "and nothing changes")
	end)
end

-- A board whose TARGET holds a ready fix on the Review fix page, kept by a retained engine. The push and the lease
-- return are recorded calls (the real `Fetch.pushAgentFix` needs the engine's own lease), settled by hand.
local function withReady(run: (w: any, b: any) -> ())
	withWorld(function(w, Fetch, Block)
		local hostPush, hostReturn = Fetch.pushAgentFix, Fetch.returnAgentFix
		local ok, err = pcall(function()
			local b = agentBoard(w, Fetch, Block)
			local fix: any = copy(ReviewFixture.fix)
			local target: any = State.prOf(b.s, TARGET)
			target.headOid = fix.headOid
			local reviewed: { [string]: boolean } = {}
			for _, hunk in fix.hunks do reviewed[hunk.id] = true end
			b.s.agents[TARGET] = { kind = "ready", fix = fix, reviewed = reviewed, review = ReviewFix.build(fix, ReviewFixture.files, ReviewFixture.details) }
			w.lease, w.pushes, w.returns = fix.worktree, {}, {}
			b.agentFlight = {
				key = TARGET, settled = true, stopping = false, releasing = false,
				engine = {
					stop = function() w.stops += 1 end, begin = function() end, busy = function(): boolean return false end,
					release = function(finished: (boolean?, string?) -> ()) finished(true, nil) end,
					held = function(): any return if w.lease then { path = w.lease } else nil end,
				},
			}
			Fetch.pushAgentFix = function(plan: any, canPush: () -> boolean, done: (boolean?, string?) -> ())
				table.insert(w.pushes, { plan = plan, canPush = canPush, done = done })
			end
			Fetch.returnAgentFix = function(path: string, done: (boolean?, string?) -> ())
				table.insert(w.returns, { path = path, done = done })
			end
			State.project(b.s)
			assert(State.openReviewFix(b.s, TARGET))
			local route: any = b.s.route
			route.loading = false
			run(w, b)
		end)
		Fetch.pushAgentFix, Fetch.returnAgentFix = hostPush, hostReturn
		if not ok then error(err, 0) end
	end)
end

local function own(b: any, on: boolean)
	local target: any = State.prOf(b.s, TARGET)
	target.tandem = on
end

local function pressPush(w: any, b: any)
	w.Block.event(b, { ev = "action", act = "review-fix-push", value = "" } :: any, w.cx)
end

-- The fix is returned and the card cleared: the lease is let go first, as the engine does.
local function finishReturn(w: any, b: any, index: number)
	w.lease = nil
	w.returns[index].done(true, nil)
	assert(b.s.agents[TARGET] == nil and b.agentFlight == nil and b.s.busy[TARGET] == nil)
end

-- A ready fix never pushes to a branch Tandem owns, whenever the ownership arrives; the fix and its lease stay for
-- Discard, and a push that already went out still ends in its lease return.
local function readyPush()
	-- Ownership is there before P: nothing is pushed, and nothing is lost.
	withReady(function(w, b)
		own(b, true)
		pressPush(w, b)
		assert(#w.pushes == 0 and #w.returns == 0, "no push begins")
		assert(b.s.agents[TARGET].kind == "ready" and b.agentFlight ~= nil and w.lease ~= nil and b.s.busy[TARGET] == nil, "the fix and its lease are kept")
		assert(#w.toasts == 1 and w.toasts[1].kind == "error" and string.find(w.toasts[1].title, "Tandem watches this pull request", 1, true))

		-- Discard still returns the lease.
		w.Block.event(b, { ev = "action", act = "review-fix-discard", value = "" } :: any, w.cx)
		w.Block.event(b, { ev = "action", act = "review-fix-discard-confirm", value = "" } :: any, w.cx)
		assert(#w.returns == 1 and #w.pushes == 0)
		finishReturn(w, b, 1)
	end)

	-- Ownership arrives while the push's own reads are out: the next command's gate refuses, and nothing is pushed.
	withReady(function(w, b)
		pressPush(w, b)
		assert(#w.pushes == 1 and w.pushes[1].plan.command ~= nil)
		local run = w.pushes[1]
		assert(run.canPush() == true, "unwatched: the push may begin")
		own(b, true)
		assert(run.canPush() == false, "watched: no command of the push may run")
		run.done(nil, "The selected fix changed")
		assert(#w.pushes == 1 and #w.returns == 0)
		assert(b.s.agents[TARGET].kind == "ready" and b.agentFlight ~= nil and w.lease ~= nil and b.s.busy[TARGET] == nil, "the fix and its lease are kept")
		assert(#w.toasts == 1 and string.find(w.toasts[1].title, "Tandem watches this pull request", 1, true))
		assert(b.s.route ~= nil and string.find((b.s.route :: any).error, "Tandem watches this pull request", 1, true))

		-- P again does not push, and Discard still returns the lease.
		pressPush(w, b)
		assert(#w.pushes == 1)
		w.Block.event(b, { ev = "action", act = "review-fix-discard", value = "" } :: any, w.cx)
		w.Block.event(b, { ev = "action", act = "review-fix-discard-confirm", value = "" } :: any, w.cx)
		assert(#w.returns == 1)
		finishReturn(w, b, 1)
	end)

	-- A push that already went out before the ownership arrived still ends in its lease return.
	withReady(function(w, b)
		pressPush(w, b)
		own(b, true)
		w.pushes[1].done(true, nil)
		assert(#w.returns == 1 and b.s.agents[TARGET].kind == "ready", "the lease is being returned")
		finishReturn(w, b, 1)
		assert(#w.pushes == 1 and w.toasts[#w.toasts].kind == "success")
	end)

	-- A return that failed after the push is retried by P on a watched PR: it pushes nothing and returns the lease.
	withReady(function(w, b)
		pressPush(w, b)
		w.pushes[1].done(true, nil)
		w.returns[1].done(nil, "busy")
		assert(b.s.agents[TARGET].kind == "ready" and (b.s.agents[TARGET] :: any).completion == "push" and w.lease ~= nil)
		own(b, true)
		pressPush(w, b)
		assert(#w.pushes == 1 and #w.returns == 2, "the retry only returns the lease")
		finishReturn(w, b, 2)
	end)
end

-- What the engine does once Treehouse hands it `path` and, later, when it gives up: each event steps the running state
-- and reaches Block through the `changed` callback it was started with, then the engine's own `done` follows.
local function holdWorktree(w: any, b: any, path: string)
	local running = b.s.agents[TARGET]
	assert(running and running.kind == "running")
	w.started[1].changed(AgentFix.step(running.run, { kind = "worktree", path = path }))
end

local function failHeld(w: any, b: any, reason: string)
	local running = b.s.agents[TARGET]
	assert(running and running.kind == "running" and running.run.worktree ~= nil, "the engine's run names its worktree")
	w.started[1].changed(AgentFix.step(running.run, { kind = "failed", reason = reason }))
	w.started[1].done(nil, reason)
end

-- A lease whose return failed keeps its retry on a card Tandem owns: Return worktree returns it through the retained
-- engine, and starts no fixer, whatever Tandem says later.
local function retainedLease()
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		w.lease, w.releases = "/work/tree", {}
		Fetch.startAgentFix = function(request: any, _agent: any, _now: number, changed: any, done: any): any
			table.insert(w.started, { request = request, changed = changed, done = done })
			return {
				stop = function() w.stops += 1 end, begin = function() end, busy = function(): boolean return false end,
				release = function(finished: (boolean?, string?) -> ()) table.insert(w.releases, finished) end,
				held = function(): any return if w.lease then { path = w.lease } else nil end,
			}
		end
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		gh(w).done(out("REFS"))
		assert(#w.started == 1 and b.agentFlight.engine ~= nil)
		holdWorktree(w, b, "/work/tree")
		claim(w, Block, b)
		failHeld(w, b, "boom")
		local flight = b.agentFlight
		assert(flight ~= nil and flight.settled and b.s.agents[TARGET].kind == "failed" and b.s.agents[TARGET].held == true, "the engine still holds the lease")

		local mine = card(b.s, TARGET)
		assert(mine.pr.tandem and mine.chips[1].text == "Waiting on Tandem" and mine.main and mine.main.act == "card-handoff" and mine.main.key == "A")
		local cleanup: any = nil
		for _, more in mine.more do
			if more.act == "card-agent-retry" then cleanup = more end
		end
		assert(cleanup and cleanup.label == "Return worktree" and cleanup.key == "⇧A", "a cleanup-only control")
		assert(offers(mine, "card-agent-worktree") and not offers(mine, "card-agent"))

		-- Its key reaches the return, and a failed return stays recoverable.
		local clones, finds = #w.clones, #w.finds
		State.select(b.s, TARGET)
		b.s.keyed = true
		Block.key(b, { name = "a", shift = true } :: any, w.cx)
		assert(#w.releases == 1 and b.s.agents[TARGET].kind == "failed" and #w.started == 1)
		w.releases[1](false, "still busy")
		local kept = card(b.s, TARGET)
		assert(b.agentFlight == flight and b.s.agents[TARGET].kind == "failed" and b.s.agents[TARGET].held == true and w.lease ~= nil, "a failed return keeps the lease")
		assert(offers(kept, "card-agent-retry") and kept.main.act == "card-handoff")
		assert(#w.started == 1 and #w.clones == clones and #w.finds == finds)

		-- The click sends the same action; on success the state clears and nothing starts.
		Block.event(b, { ev = "action", act = "card-agent-retry", value = TARGET } :: any, w.cx)
		assert(#w.releases == 2)
		w.lease = nil
		w.releases[2](true, nil)
		assert(b.agentFlight == nil and b.s.agents[TARGET] == nil, "the retained state is cleared")
		assert(#w.started == 1 and #w.clones == clones and #w.finds == finds and w.stops == 0)
		local done = card(b.s, TARGET)
		assert(done.pr.tandem and done.main and done.main.act == "card-handoff" and not offers(done, "card-agent-retry") and not offers(done, "card-agent-worktree"))
	end)

	-- Tandem letting go while the return runs does not turn it into a retry of the fix.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		w.lease, w.releases = "/work/tree", {}
		Fetch.startAgentFix = function(request: any, _agent: any, _now: number, changed: any, done: any): any
			table.insert(w.started, { request = request, changed = changed, done = done })
			return {
				stop = function() w.stops += 1 end, begin = function() end, busy = function(): boolean return false end,
				release = function(finished: (boolean?, string?) -> ()) table.insert(w.releases, finished) end,
				held = function(): any return if w.lease then { path = w.lease } else nil end,
			}
		end
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		gh(w).done(out("REFS"))
		holdWorktree(w, b, "/work/tree")
		claim(w, Block, b)
		failHeld(w, b, "boom")
		Block.event(b, { ev = "action", act = "card-agent-retry", value = TARGET } :: any, w.cx)
		assert(#w.releases == 1)
		own(b, false)
		w.lease = nil
		w.releases[1](true, nil)
		assert(b.agentFlight == nil and #w.started == 1 and #w.clones == 1, "no fixer starts after a cleanup")
	end)
end

-- The engine takes its lease before it names the worktree, so it can fail on the path check with the lease held and
-- no worktree event sent. A card Tandem owns drops a failed state with no path, so the block restores it from the
-- engine's held lease: Return worktree stays until a guarded return succeeds. Both callback orders are covered: the
-- failure after the engine handle exists, and during Fetch.startAgentFix before it returns the handle.
local function preWorktreeLease()
	local PATH = "/work/pre-identity"
	local function begin(w: any, Fetch: any, Block: any, sync: boolean): any
		local b = agentBoard(w, Fetch, Block)
		w.lease, w.releases = PATH, {}
		Fetch.startAgentFix = function(request: any, _agent: any, _now: number, changed: any, done: any): any
			table.insert(w.started, { request = request, changed = changed, done = done })
			if sync then
				own(b, true)
				b.watched[TARGET] = true
				changed({ kind = "failed", reason = "The worktree path could not be verified" })
				done(nil, "The worktree path could not be verified")
			end
			return {
				stop = function() w.stops += 1 end, begin = function() end, busy = function(): boolean return false end,
				release = function(finished: (boolean?, string?) -> ()) table.insert(w.releases, finished) end,
				held = function(): any return if w.lease then { path = w.lease } else nil end,
			}
		end
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		gh(w).done(out("REFS"))
		assert(#w.started == 1 and b.agentFlight ~= nil and b.agentFlight.engine ~= nil)
		return b
	end

	-- The lease is held, no worktree event came, the failure and done arrive, Tandem owns the card, and the return fails.
	local function cleanup(w: any, b: any, Block: any, why: string)
		local flight = b.agentFlight
		local agent = b.s.agents[TARGET]
		assert(flight ~= nil and flight.settled and agent ~= nil and agent.kind == "failed" and agent.held == true and agent.worktree == PATH, why .. ": the failed state names the held lease")
		local mine = card(b.s, TARGET)
		assert(mine.pr.tandem and mine.chips[1].text == "Waiting on Tandem" and mine.main and mine.main.act == "card-handoff" and not offers(mine, "card-agent"), why)
		local returning: any = nil
		for _, more in mine.more do
			if more.act == "card-agent-retry" then returning = more end
		end
		assert(returning and returning.label == "Return worktree" and returning.key == "⇧A", why .. ": Return worktree is offered")
		assert(offers(mine, "card-agent-worktree"))

		State.select(b.s, TARGET)
		b.s.keyed = true
		Block.key(b, { name = "a", shift = true } :: any, w.cx)
		assert(#w.releases == 1 and #w.started == 1)
		w.releases[1](false, "still busy")
		assert(b.agentFlight == flight and b.s.agents[TARGET].kind == "failed" and b.s.agents[TARGET].held == true and w.lease == PATH, why .. ": a failed return keeps the lease")
		assert(offers(card(b.s, TARGET), "card-agent-retry"), why .. ": Return worktree stays")

		Block.event(b, { ev = "action", act = "card-agent-retry", value = TARGET } :: any, w.cx)
		assert(#w.releases == 2)
		w.lease = nil
		w.releases[2](true, nil)
		assert(b.agentFlight == nil and b.s.agents[TARGET] == nil and #w.started == 1 and w.stops == 0, why .. ": released")
		assert(not offers(card(b.s, TARGET), "card-agent-retry") and not offers(card(b.s, TARGET), "card-agent-worktree"))
	end

	-- Tandem takes the PR, then the engine fails after its handle exists.
	withWorld(function(w, Fetch, Block)
		local b = begin(w, Fetch, Block, false)
		claim(w, Block, b)
		w.started[1].changed({ kind = "failed", reason = "The worktree path could not be verified" })
		w.started[1].done(nil, "The worktree path could not be verified")
		cleanup(w, b, Block, "owned before the failure")
	end)

	-- The engine fails first and Tandem takes the PR afterwards.
	withWorld(function(w, Fetch, Block)
		local b = begin(w, Fetch, Block, false)
		w.started[1].changed({ kind = "failed", reason = "The worktree path could not be verified" })
		w.started[1].done(nil, "The worktree path could not be verified")
		assert(b.s.agents[TARGET].kind == "failed" and b.s.agents[TARGET].held == true and b.s.agents[TARGET].worktree == PATH)
		claim(w, Block, b)
		cleanup(w, b, Block, "owned after the failure")
	end)

	-- Both callbacks run inside Fetch.startAgentFix, before it returns the handle.
	withWorld(function(w, Fetch, Block)
		local b = begin(w, Fetch, Block, true)
		cleanup(w, b, Block, "synchronous terminal callbacks")
	end)

	-- A lease that is not held leaves nothing to keep: the watched card drops the failed state as before.
	withWorld(function(w, Fetch, Block)
		local b = begin(w, Fetch, Block, false)
		w.lease = nil
		claim(w, Block, b)
		w.started[1].changed({ kind = "failed", reason = "boom" })
		w.started[1].done(nil, "boom")
		assert(b.s.agents[TARGET] == nil and b.agentFlight == nil, "no lease, no cleanup control")
	end)
end

-- A watched PR offers no new merge, by any method, and the handlers send nothing for a stale click. A merge already
-- pending can still be cancelled.
local function watchedMerge()
	local MERGED = "acme/api#109"
	local methods: { [string]: any } = {
		squash = { method = { kind = "squash" }, source = "user", ask = false },
		comment = { method = { kind = "comment", command = "/merge" }, source = "declared", ask = false },
		label = { method = { kind = "label", label = "ready-to-merge" }, source = "declared", ask = false },
	}
	for name, resolution in methods do
		local function boardFor(key: string, tandem: boolean): State.Card
			local s = board({ pr(key, { tandem = tandem }) })
			s.merges["acme/api"], s.autoMerge["acme/api"] = resolution, true
			State.project(s)
			return card(s, key)
		end
		assert(offers(boardFor("acme/api#114", false), "card-auto"), name .. ": an unwatched card offers Merge when ready")
		for _, key in { MERGED, "acme/api#114" } do
			local watched = boardFor(key, true)
			assert(watched.column == "in_review" and watched.chips[1].text == "Waiting on Tandem", name)
			for _, forbidden in { "card-auto", "card-merge", "card-method", "card-update" } do assert(not offers(watched, forbidden), name .. ": " .. forbidden) end
		end
	end

	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		reads(w)[1].done(out("WATCH"))
		w.runs = {}
		b.github = { refresh = function() end, run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end }
		for name, resolution in methods do
			w.toasts = {}
			b.s.merges["acme/api"], b.s.autoMerge["acme/api"] = resolution, true
			local target: any = State.prOf(b.s, MERGED)
			target.tandem, target.pending = false, nil
			State.project(b.s)
			-- The question was asked before Tandem took the PR; the answer arrives after.
			State.askMerge(b.s, MERGED)
			target.tandem = true
			State.project(b.s)
			for _, act in { "card-merge", "card-auto", "hub-confirm" } do
				Block.event(b, { ev = "action", act = act, value = MERGED } :: any, w.cx)
			end
			assert(#w.runs == 0 and b.s.busy[MERGED] == nil and State.prOf(b.s, MERGED).pending == nil, name .. ": nothing is sent")
		end

		-- A merge that was pending before the ownership arrived can still be cancelled.
		b.s.merges["acme/api"], b.s.autoMerge["acme/api"] = methods.squash, true
		State.setPending(b.s, MERGED, { method = "queue", at = "2026-10-10T00:00:00Z" })
		local pending = card(b.s, MERGED)
		assert(pending.pr.tandem and offers(pending, "card-cancel") and not offers(pending, "card-auto"))
		Block.event(b, { ev = "action", act = "card-cancel", value = MERGED } :: any, w.cx)
		assert(#w.runs == 1 and table.find(w.runs[1].command.argv, "--disable-auto") ~= nil, "Cancel merge still runs")
	end)
end

-- A batch holds the pull requests it captured. While the first merge is out, Tandem takes the second and the board
-- loses it (the open-PR limit); the durable set still owns it, so its merge sends nothing and the batch stops there.
local function queuedMerge()
	local FIRST, SECOND = "acme/api#109", "acme/api#116"
	withWorld(function(w, Fetch, Block)
		local b = live(w, Block)
		reads(w)[1].done(out("WATCH"))
		w.runs = {}
		b.github = { refresh = function() end, run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end }
		b.s.confirm = { kind = "batch-merge", keys = { FIRST, SECOND } } :: any
		assert(not State.prOf(b.s, SECOND).tandem)
		Block.event(b, { ev = "action", act = "hub-confirm", value = "" } :: any, w.cx)
		assert(#w.runs == 1 and b.s.busy[FIRST] ~= nil and b.s.busy[SECOND] == nil, "the first merge is out")

		b.watched[SECOND] = true
		State.dropPr(b.s, SECOND)
		assert(State.prOf(b.s, SECOND) == nil)
		w.toasts = {}
		w.runs[1].done(nil, nil)
		assert(#w.runs == 1 and b.s.busy[SECOND] == nil, "nothing is sent for the second")
		assert(#w.toasts == 1 and w.toasts[1].kind == "error", "the batch reports it")
		assert(string.find(w.toasts[1].title, "Merged #109. Couldn't merge #116: Tandem watches this pull request", 1, true), w.toasts[1].title)
	end)
end

-- Two windows share one store. Window B stores ownership of a PR, at this window's cache's stamp or later, before any
-- callback of this window (a read of Tandem, a refresh, a hand-off) has joined it. Every guard reads the shared store
-- itself, so no command reaches the branch. The ownership comes only through the shared KV: this window runs no read of
-- Tandem and no hand-off, and stores nothing.
local function sharedOwnership()
	-- This window holds the cache the store held before B wrote, naming only what Tandem's recorded watch names.
	local function holdCache(w: any, b: any)
		w.shared = true
		w.kv["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf)
		b.cache = Sync.load(copy(w.kv["hub.cache"]))
		assert(b.cache ~= nil, "this window holds a cache of the store's stamp")
	end
	local function storeOwned(w: any, owned: { string }, at: number): any
		local theirs = storedCache(owned, at)
		w.kv["hub.cache"] = theirs
		return theirs
	end

	-- A push whose command check is out: the next check joins what B stored and refuses, whatever the stamp's age.
	for _, at in { Cases.asOf, Cases.asOf + 60 } do
		withReady(function(w, b)
			holdCache(w, b)
			local watches, joined = #reads(w), b.handoffs
			pressPush(w, b)
			assert(#w.pushes == 1 and w.pushes[1].plan.command ~= nil)
			local run = w.pushes[1]
			assert(run.canPush() == true, "unwatched: the push may begin")
			local theirs = storeOwned(w, { WEB, API114, TARGET }, at)
			assert(b.watched[TARGET] == nil and not State.prOf(b.s, TARGET).tandem and b.handoffs == joined, "this window has not heard of it")
			assert(run.canPush() == false, "the next check joins the store's ownership and refuses")
			assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true and b.handoffs == joined + 1)
			assert(#reads(w) == watches and #handoffs(w) == 0 and gh(w) == nil, "only the store told this window")
			assert(same(w.kv["hub.cache"], theirs), "nothing was stored")
			-- Fetch stops the push there; the ready fix and its lease are kept, and Discard still returns the lease.
			run.done(nil, "The selected fix changed")
			assert(#w.pushes == 1 and #w.returns == 0)
			assert(b.s.agents[TARGET].kind == "ready" and b.agentFlight ~= nil and w.lease ~= nil and b.s.busy[TARGET] == nil, "the fix and its lease are kept")
			assert(#w.toasts == 1 and string.find(w.toasts[1].title, "Tandem watches this pull request", 1, true))
			pressPush(w, b)
			assert(#w.pushes == 1)
			w.Block.event(b, { ev = "action", act = "review-fix-discard", value = "" } :: any, w.cx)
			w.Block.event(b, { ev = "action", act = "review-fix-discard-confirm", value = "" } :: any, w.cx)
			assert(#w.returns == 1)
			finishReturn(w, b, 1)
		end)
	end

	-- B's ownership arrives before the click's own check: the press itself joins it, so the push never begins.
	withReady(function(w, b)
		holdCache(w, b)
		storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
		assert(not State.prOf(b.s, TARGET).tandem)
		pressPush(w, b)
		assert(#w.pushes == 0 and #w.returns == 0 and State.prOf(b.s, TARGET).tandem == true)
		assert(b.s.agents[TARGET].kind == "ready" and b.agentFlight ~= nil and w.lease ~= nil, "the fix and its lease are kept")
	end)

	-- A click whose card was drawn before B's write sends nothing. Each action also sends its command once on a PR nobody
	-- watches, so the empty result is the guard's.
	for _, act in { "card-merge", "card-auto", "card-update" } do
		for _, stale in { false, true } do
			withWorld(function(w, Fetch, Block)
				local b = live(w, Block)
				reads(w)[1].done(out("WATCH"))
				w.runs = {}
				b.github = { refresh = function() end, run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end }
				local key = if act == "card-update" then "acme/api#118" else "acme/api#109"
				if act == "card-update" then
					local lagging: any = State.prOf(b.s, key)
					lagging.behind, lagging.conflicts, lagging.draft = true, false, false
				else
					b.s.merges["acme/api"] = { method = { kind = "comment", command = "/merge" }, source = "declared", ask = false }
					b.s.autoMerge["acme/api"] = true
				end
				State.project(b.s)
				holdCache(w, b)
				local watches = #reads(w)
				local theirs = if stale then storeOwned(w, { WEB, API114, key }, Cases.asOf + 60) else nil
				assert(b.watched[key] == nil and not State.prOf(b.s, key).tandem)
				w.toasts = {}
				Block.event(b, { ev = "action", act = act, value = key } :: any, w.cx)
				if not stale then
					assert(#w.runs == 1 and b.s.busy[key] ~= nil, act .. ": an unwatched PR sends it")
				else
					assert(#w.runs == 0 and gh(w) == nil and b.s.busy[key] == nil, act .. ": nothing is sent")
					assert(b.watched[key] == true and State.prOf(b.s, key).tandem == true and #reads(w) == watches and #handoffs(w) == 0, act .. ": the store told this window")
					assert(same(w.kv["hub.cache"], theirs), act .. ": nothing was stored")
					assert(State.prOf(b.s, key).pending == nil, act .. ": and nothing is marked pending")
				end
			end)
		end
	end

	-- A fix started from a click that predates B's write never begins either.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		local finds = #w.finds
		local theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		noFixer(w, b, "a stale Fix with agent")
		assert(#w.finds == finds and #w.clones == 0 and gh(w) == nil and #w.toasts == 0)
		assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true and same(w.kv["hub.cache"], theirs))
	end)

	-- Setup that is waiting on a lookup when B stores the ownership: the next step's own check joins it, so that step
	-- stops the fix and nothing goes on to the clone, the refs or the engine. Without B's write the same step goes on.
	for _, stage in { "root", "clone", "refs" } do
		for _, stale in { false, true } do
			withWorld(function(w, Fetch, Block)
				local b = agentBoard(w, Fetch, Block)
				holdCache(w, b)
				w.holdRoot = stage == "root"
				Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
				assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and b.s.agents[TARGET].kind == "running")
				local held: any = nil
				if stage == "root" then
					held = w.finds[#w.finds]
				elseif stage == "clone" then
					held = w.clones[1]
				else
					w.clones[1].done("/clone", nil)
					held = gh(w)
				end
				assert(held ~= nil, stage .. ": a step is out")
				local watches = #reads(w)
				local theirs = if stale then storeOwned(w, { WEB, API114, TARGET }, Cases.asOf) else nil
				assert(b.watched[TARGET] == nil and not State.prOf(b.s, TARGET).tandem and b.agentFlight ~= nil, stage .. ": not heard of yet")
				if stage == "root" then held.done({ root = REPO_ROOT }, nil)
				elseif stage == "clone" then held.done("/clone", nil)
				else held.done(out("REFS")) end
				if stale then
					noFixer(w, b, stage)
					assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, stage .. ": joined from the store")
					assert(#w.clones == (if stage == "root" then 0 else 1) and (stage == "refs" or gh(w) == nil), stage .. ": nothing went on")
					assert(#w.toasts == 0 and #reads(w) == watches and same(w.kv["hub.cache"], theirs), stage)
				elseif stage == "root" then assert(#w.clones == 1 and b.agentFlight ~= nil)
				elseif stage == "clone" then assert(gh(w) ~= nil and b.agentFlight ~= nil)
				else assert(#w.started == 1 and b.agentFlight ~= nil and b.agentFlight.engine ~= nil) end
			end)
		end
	end

	-- A running engine is never cut off by the join: it is Stop's.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		gh(w).done(out("REFS"))
		assert(#w.started == 1 and b.agentFlight.engine ~= nil)
		storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		assert(State.prOf(b.s, TARGET).tandem == true and #w.started == 1 and b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running" and w.stops == 0)
	end)

	-- An older cache joins nothing, at a guard or in a callback.
	withReady(function(w, b)
		holdCache(w, b)
		w.kv["hub.cache"] = storedCache({ WEB, API114, TARGET }, Cases.asOf - 60)
		pressPush(w, b)
		assert(#w.pushes == 1 and w.pushes[1].canPush() == true)
		assert(b.watched[TARGET] == nil and not State.prOf(b.s, TARGET).tandem)
	end)

	-- A successful read of Tandem that omits A clears it while B's fix is still being set up. B's reconciliation does not
	-- replay the shared cache the answer supersedes, so A stays cleared in the model and in what is stored, and B's setup
	-- goes on from the next step. When the same answer names B, B ends as stopped and A is still cleared.
	for _, names in { "none", "target" } do
		withWorld(function(w, Fetch, Block)
			local b = agentBoard(w, Fetch, Block)
			holdCache(w, b)
			Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
			assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and #w.clones == 1)
			assert(State.prOf(b.s, WEB).tandem == true and b.watched[WEB] == true)
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			local later = if names == "target" then watchWith({ TARGET }) else copy(RawWatch)
			local rows = {}
			for _, row in later.rows do
				if row.number ~= 104 then table.insert(rows, row) end
			end
			later.rows = rows
			w.decoded["CLEARS"] = later
			reads(w)[2].done(out("CLEARS"))
			assert(not State.prOf(b.s, WEB).tandem and b.watched[WEB] == nil, names .. ": A is cleared")
			assert(card(b.s, WEB).column == "needs_fixes" and card(b.s, WEB).main.label == "Fix with agent", names)
			assert(State.prOf(b.s, API114).tandem == true, names .. ": the PRs it still names stay")
			for _, saved in { b.cache, w.kv["hub.cache"] } do
				for _, cached in saved.prs do
					if cached.key == WEB then assert(not cached.tandem, names .. ": A is stored cleared") end
					if cached.key == API114 then assert(cached.tandem == true, names) end
				end
			end
			assert(b.cache.counts.needFixes == needFixesOf(b) and w.kv["hub.status"].counts.needFixes == needFixesOf(b), names)
			if names == "target" then
				noFixer(w, b, "named by the answer")
				w.clones[1].done("/clone", nil)
				assert(gh(w) == nil and #w.toasts == 0, "the late lookup reads no refs")
			else
				assert(b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running" and #w.started == 0, "B's setup is untouched")
				w.clones[1].done("/clone", nil)
				assert(gh(w) ~= nil and b.agentFlight ~= nil, "and goes on")
			end
			assert(not State.prOf(b.s, WEB).tandem and b.watched[WEB] == nil and #w.started == 0 and w.stops == 0, names .. ": A is not restored")
			assert(w.kv["hub.cache"] ~= nil and #handoffs(w) == 0)
		end)
	end

	-- B's setup is waiting on its repository lookup when window C stores ownership of an unrelated PR. The lookup's answer
	-- joins it, and the card is drawn then, before the read of Tandem that began earlier returns. That read is stale (the
	-- join moved the hand-offs it read before), so it is dropped, and its replacement read fails; the card stays
	-- flagged, B's fix goes on, and nothing is sent.
	withWorld(function(w, Fetch, Block)
		local OTHER = "acme/api#116"
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		w.holdRoot = true
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		local held = w.finds[#w.finds]
		assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and held ~= nil)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(#reads(w) == 2 and b.flights.tandem, "a read that began before is out")
		storeOwned(w, { WEB, API114, OTHER }, Cases.asOf)
		assert(not State.prOf(b.s, OTHER).tandem and b.watched[OTHER] == nil)
		local drawn = w.renders
		held.done({ root = REPO_ROOT }, nil)
		assert(State.prOf(b.s, OTHER).tandem == true and b.watched[OTHER] == true, "the lookup joined it")
		assert(w.renders > drawn, "and drew it at once")
		assert(card(b.s, OTHER).chips[1].text == "Waiting on Tandem" and not offers(card(b.s, OTHER), "card-agent"))
		assert(b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running" and #w.clones == 1, "B goes on")

		local watches = #reads(w)
		reads(w)[2].done(out("WATCH"))
		assert(#reads(w) == watches + 1 and b.flights.tandem, "the stale answer asks again")
		reads(w)[watches + 1].done(out("nope"))
		assert(not b.flights.tandem and b.s.error == nil and #w.toasts == 0)
		assert(State.prOf(b.s, OTHER).tandem == true and b.watched[OTHER] == true, "a failed read clears nothing")
		assert(b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running" and #w.started == 0 and w.stops == 0)
		assert(gh(w) == nil and #handoffs(w) == 0, "nothing is sent")
	end)

	-- B's refs read is out when window C stores ownership of an unrelated PR and the draw that shows it raises (the block
	-- is gone). The join's draw closed the block and stopped B's flight (it stays held for the closed block, unsettled and
	-- without an engine), so the refs answer never goes on to start an engine.
	withWorld(function(w, Fetch, Block)
		local OTHER = "acme/api#116"
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		w.clones[1].done("/clone", nil)
		local held, flight = gh(w), b.agentFlight
		assert(held ~= nil and flight ~= nil and flight.engine == nil and #w.started == 0, "the refs read is out")
		local theirs = storeOwned(w, { WEB, API114, OTHER }, Cases.asOf)
		w.cx.render = function() error("the window is gone", 0) end
		local calls, finds = #w.calls, #w.finds
		held.done(out("REFS"))
		assert(State.prOf(b.s, OTHER).tandem == true and b.watched[OTHER] == true, "the lookup joined it before the draw")
		assert(b.closed and flight.stopping and flight.engine == nil, "the failed draw closed the block and stopped its flight")
		assert(#w.started == 0 and w.stops == 0, "no engine started")
		assert(#w.calls == calls and #w.finds == finds and #w.clones == 1 and #w.details == 0 and #handoffs(w) == 0, "no external work went on")
		assert(b.watched[OTHER] == true and same(w.kv["hub.cache"], theirs) and #w.toasts == 0)
	end)

	-- A successful read of Tandem clears A, and its save fails: the store still holds the cache it superseded, at the same
	-- stamp. Navigation and a setup continuation that read the store do not bring A back. A cache another window stores
	-- later at that same stamp (its own write id) is a hand-off and joins, and it stops the fix being set up.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		local retained = copy(w.kv["hub.cache"])
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and #w.clones == 1)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local later = copy(RawWatch)
		local rows = {}
		for _, row in later.rows do
			if row.number ~= 104 then table.insert(rows, row) end
		end
		later.rows = rows
		w.decoded["CLEARS"] = later
		w.failKv = true
		reads(w)[2].done(out("CLEARS"))
		assert(not State.prOf(b.s, WEB).tandem and b.watched[WEB] == nil, "A is cleared in memory")
		assert(b.s.error ~= nil and b.s.error.operation == "hub.cache" and string.find(b.s.error.message, "couldn't be saved", 1, true), "the cache error is shown")
		assert(same(w.kv["hub.cache"], retained), "the store still holds the superseded cache")
		assert(b.cache.counts.needFixes == needFixesOf(b) and State.prOf(b.s, API114).tandem == true, "memory state is valid")

		local function stays(step: string)
			assert(not State.prOf(b.s, WEB).tandem and b.watched[WEB] == nil and card(b.s, WEB).main.label == "Fix with agent", step .. ": A stays cleared")
			assert(#w.started == 0 and w.stops == 0 and #handoffs(w) == 0 and same(w.kv["hub.cache"], retained), step .. ": no effect and nothing stored")
		end
		Block.event(b, { ev = "action", act = "hub-move", value = "down" } :: any, w.cx)
		stays("navigation")
		Block.event(b, { ev = "action", act = "hub-select", value = API114 } :: any, w.cx)
		stays("selection")
		w.clones[1].done("/clone", nil)
		assert(gh(w) ~= nil and b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running", "B's setup goes on")
		stays("setup continuation")

		local theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
		theirs.writeId = "another-window#1"
		gh(w).done(out("REFS"))
		noFixer(w, b, "a hand-off stored after the clear")
		assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, "the later write joins")
		assert(b.watched[WEB] == true and State.prOf(b.s, WEB).tandem == true, "and brings its own flags")
		assert(#w.toasts == 0 and #handoffs(w) == 0 and same(w.kv["hub.cache"], theirs), "nothing was sent or stored")
	end)

	-- The identity retired is the cache the store held when the answer arrived, not whatever the store holds when the save
	-- fails. Another window stores a hand-off at the same stamp while the failing save is in flight (before any bookkeeping
	-- could read the store): it has its own id, is not retired, and joins at the next guard.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		w.kv["hub.cache"].writeId = "other-window#1"
		local retained = copy(w.kv["hub.cache"])
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and #w.clones == 1)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local later = copy(RawWatch)
		local rows = {}
		for _, row in later.rows do
			if row.number ~= 104 then table.insert(rows, row) end
		end
		later.rows = rows
		w.decoded["CLEARS"] = later
		local theirs: any
		w.failKv = true
		w.whileFailing = function()
			w.whileFailing = nil
			theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
			theirs.writeId = "another-window#2"
		end
		reads(w)[2].done(out("CLEARS"))
		assert(theirs ~= nil, "the later write landed during the failed save")
		assert(not State.prOf(b.s, WEB).tandem and b.watched[WEB] == nil, "A is cleared in memory")
		assert(b.s.error ~= nil and b.s.error.operation == "hub.cache" and string.find(b.s.error.message, "couldn't be saved", 1, true))
		local retired = {}
		for id in b.retired do table.insert(retired, id) end
		assert(#retired == 1 and b.retired["other-window#1"] == true, "only the cache the answer superseded is retired")
		assert(b.retired["another-window#2"] == nil and same(w.kv["hub.cache"], theirs))
		assert(not State.prOf(b.s, TARGET).tandem and b.agentFlight ~= nil, "the later write is not joined until a guard reads it")
		w.failKv = false
		w.clones[1].done("/clone", nil)
		noFixer(w, b, "the later write stops the fix being set up")
		assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, "it joined")
		assert(b.watched[WEB] == true and State.prOf(b.s, WEB).tandem == true, "and brought its own flags")
		assert(gh(w) == nil and #handoffs(w) == 0 and #w.toasts == 0 and same(w.kv["hub.cache"], theirs))
	end)

	-- The store cannot be read when the answer arrives, so the superseded cache cannot be identified: the clear fails closed.
	-- Nothing changes, no id is guessed, and a later answer with a readable store clears and retires as usual.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
		holdCache(w, b)
		w.kv["hub.cache"].writeId = "other-window#1"
		local retained = copy(w.kv["hub.cache"])
		local later = copy(RawWatch)
		local rows = {}
		for _, row in later.rows do
			if row.number ~= 104 then table.insert(rows, row) end
		end
		later.rows = rows
		w.decoded["CLEARS"] = later
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		w.failGet, w.failKv = true, true
		reads(w)[2].done(out("CLEARS"))
		w.failGet, w.failKv = false, false
		assert(State.prOf(b.s, WEB).tandem == true and b.watched[WEB] == true, "A is not cleared")
		assert(next(b.retired) == nil and same(w.kv["hub.cache"], retained), "nothing was retired or stored")
		assert(b.s.error == nil or b.s.error.operation ~= "hub.cache", "no save was tried")
		local clones = #w.clones
		Block.event(b, { ev = "action", act = "card-agent", value = WEB } :: any, w.cx)
		assert(#w.clones == clones and #w.started == 0 and b.agentFlight == nil and gh(w) == nil and #handoffs(w) == 0, "no effect reaches A's branch")

		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		reads(w)[3].done(out("CLEARS"))
		assert(not State.prOf(b.s, WEB).tandem and b.watched[WEB] == nil, "a readable store lets the next answer clear it")
		assert(w.kv["hub.cache"].writeId ~= "other-window#1", "and it is saved")
	end)

	-- This window owns TARGET and another window then stores a strictly newer cache that lacks it. The answer that clears
	-- TARGET adopts that cache first, which would restore TARGET and store the restored board; that intermediate write
	-- would succeed and stay joinable after the answer's own save fails. Adoption writes nothing here, so the failed save
	-- is the only attempt, the store keeps the cache the answer superseded (retired), and TARGET stays cleared.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
		holdCache(w, b)
		claim(w, Block, b)
		assert(b.watched[TARGET] == true and w.kv["hub.cache"].refreshedAt == b.cache.refreshedAt, "this window owns TARGET and stored it")

		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local answer = reads(w)[#reads(w)]
		local theirs = storedCache({ WEB, API114 }, Cases.asOf + 60)
		theirs.writeId = "other-window#1"
		w.kv["hub.cache"] = theirs
		assert((Model.epoch(theirs.refreshedAt) :: number) > (Model.epoch(b.cache.refreshedAt) :: number), "the store holds a strictly newer cache without TARGET")
		-- A store of the board that still flags TARGET succeeds (what adoption's own write would be); one that clears it fails.
		w.failWhen = function(key: string, value: any): boolean
			if key ~= "hub.cache" then return false end
			for _, cached in value.prs do
				if cached.key == TARGET then return cached.tandem ~= true end
			end
			return false
		end
		local before = w.cacheSets or 0
		answer.done(out("WATCH"))
		w.failWhen = nil
		assert(not State.prOf(b.s, TARGET).tandem and b.watched[TARGET] == nil, "the answer cleared TARGET in memory")
		assert(b.cache.refreshedAt == theirs.refreshedAt, "the newer cache was adopted")
		assert((w.cacheSets or 0) == before + 1, "adopting wrote nothing: the answer's own save is the only attempt")
		assert(same(w.kv["hub.cache"], theirs) and w.kv["hub.cache"].writeId == "other-window#1", "the store still holds the superseded cache")
		assert(b.s.error ~= nil and b.s.error.operation == "hub.cache" and string.find(b.s.error.message, "couldn't be saved", 1, true))
		assert(b.retired["other-window#1"] == true, "the superseded cache is retired")

		local function stays(step: string, label: string)
			assert(not State.prOf(b.s, TARGET).tandem and b.watched[TARGET] == nil, step .. ": TARGET stays cleared")
			assert(card(b.s, TARGET).main.label == label, step .. ": the card offers " .. label)
			assert(#w.started == 0 and w.stops == 0 and #handoffs(w) == 0 and same(w.kv["hub.cache"], theirs), step .. ": no effect and nothing stored")
			assert((w.cacheSets or 0) == before + 1, step .. ": no write")
		end
		Block.event(b, { ev = "action", act = "hub-move", value = "down" } :: any, w.cx)
		stays("navigation", "Fix with agent")
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and #w.clones == 1, "the fix is being set up for TARGET")
		stays("dispatch", "Stop")
		w.clones[1].done("/clone", nil)
		assert(gh(w) ~= nil and b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running", "its setup goes on")
		stays("setup continuation", "Stop")

		-- A write another window stores later has its own id, is not retired, and joins.
		local later = storedCache({ WEB, API114, TARGET }, Cases.asOf + 60)
		later.writeId = "another-window#1"
		w.kv["hub.cache"] = later
		gh(w).done(out("REFS"))
		noFixer(w, b, "a hand-off stored after the clear")
		assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, "the later write joins")
		assert(#w.toasts == 0 and #handoffs(w) == 0 and same(w.kv["hub.cache"], later), "nothing was sent or stored")
	end)

	-- Only the answer's first read of the store fails; adoption's later read succeeds and restores TARGET. The answer
	-- fails closed and stores nothing, so no write is even attempted, and the ownership adoption restored is stored by the
	-- next answer, which clears TARGET and retires the cache the store held.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
		holdCache(w, b)
		claim(w, Block, b)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local answer = reads(w)[#reads(w)]
		local theirs = storedCache({ WEB, API114 }, Cases.asOf + 60)
		theirs.writeId = "other-window#1"
		w.kv["hub.cache"] = theirs
		local before = w.cacheSets or 0
		w.failGets = 1
		answer.done(out("WATCH"))
		assert(w.failGets == 0, "only the first read of the store failed")
		assert(b.cache.refreshedAt == theirs.refreshedAt, "the newer cache was adopted")
		assert(State.prOf(b.s, TARGET).tandem == true and b.watched[TARGET] == true, "adoption restored TARGET and the answer cleared nothing")
		assert((w.cacheSets or 0) == before, "no write was attempted")
		assert(same(w.kv["hub.cache"], theirs) and next(b.retired) == nil, "nothing was stored or retired")
		assert(b.s.error == nil or b.s.error.operation ~= "hub.cache", "no save was tried")
		assert(b.unsaved == true, "the restored ownership waits for a successful answer")

		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		reads(w)[#reads(w)].done(out("WATCH"))
		local stored = w.kv["hub.cache"]
		assert((w.cacheSets or 0) == before + 1 and stored.writeId ~= "other-window#1", "the next answer is the one write")
		assert(not State.prOf(b.s, TARGET).tandem and b.watched[TARGET] == nil and not b.unsaved and next(b.retired) == nil)
		for _, cached in stored.prs do
			if cached.key == TARGET then assert(cached.tandem ~= true, "and it stores TARGET cleared") end
		end
	end)

	-- Another window stores a cache with a PR this window has not heard of between this answer's adoption and its join:
	-- at the adopted stamp or strictly newer. The answer is stale, so it stores nothing: the later write survives
	-- untouched until the replacement read, whose own save keeps both flags and never lowers the stamp.
	for _, bump in { 0, 60 } do
		withWorld(function(w, Fetch, Block)
			local what = if bump == 0 then "same stamp" else "newer stamp"
			local OTHER = "acme/api#116"
			local b = agentBoard(w, Fetch, Block)
			b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
			holdCache(w, b)
			claim(w, Block, b)
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			local answer = reads(w)[#reads(w)]
			local theirs = storedCache({ WEB, API114 }, Cases.asOf + 60)
			theirs.writeId = "other-window#1"
			w.kv["hub.cache"] = theirs
			local later = storedCache({ WEB, API114, TARGET, OTHER }, Cases.asOf + 60 + bump)
			later.writeId = "another-window#1"
			w.onGet = function()
				if b.cache.refreshedAt == theirs.refreshedAt then
					w.onGet = nil
					w.kv["hub.cache"] = later
				end
			end
			local before, answered = w.cacheSets or 0, #reads(w)
			answer.done(out("WATCH"))
			assert(w.onGet == nil, what .. ": the other window wrote after the adoption")
			assert((w.cacheSets or 0) == before and same(w.kv["hub.cache"], later), what .. ": the later write stands and nothing was written")
			assert(b.watched[OTHER] == true and State.prOf(b.s, OTHER).tandem and b.watched[TARGET] == true, what .. ": both are owned in memory")
			assert(#reads(w) == answered + 1 and b.flights.tandem and b.unsaved, what .. ": the replacement read is out and the restore waits")

			w.decoded["BOTH"] = watchWith({ TARGET, OTHER })
			reads(w)[#reads(w)].done(out("BOTH"))
			local stored = w.kv["hub.cache"]
			assert((w.cacheSets or 0) == before + 1 and stored.writeId ~= "another-window#1" and not b.unsaved, what .. ": the replacement answer is the one write")
			assert((Model.epoch(stored.refreshedAt) :: number) >= (Model.epoch(later.refreshedAt) :: number), what .. ": the stamp never goes down")
			local flagged = {}
			for _, cached in stored.prs do
				if cached.tandem == true then flagged[cached.key] = true end
			end
			assert(flagged[WEB] and flagged[API114] and flagged[TARGET] and flagged[OTHER], what .. ": every flag is stored")
		end)
	end

	-- The answer confirms the ownership adoption restored, so nothing is visibly different and the answer's own save is
	-- the one write that stores it: exactly one, none for a failed read before it, none for an unchanged answer after.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
		holdCache(w, b)
		claim(w, Block, b)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local answer = reads(w)[#reads(w)]
		local theirs = storedCache({ WEB, API114 }, Cases.asOf + 60)
		theirs.writeId = "other-window#1"
		w.kv["hub.cache"] = theirs
		local before = w.cacheSets or 0
		answer.done(out("", 127, "tandem: not found"))
		assert(b.cache.refreshedAt == theirs.refreshedAt and b.unsaved and (w.cacheSets or 0) == before, "a failed read stores nothing")
		assert(same(w.kv["hub.cache"], theirs))

		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		reads(w)[#reads(w)].done(out("CLAIM"))
		local stored = w.kv["hub.cache"]
		assert((w.cacheSets or 0) == before + 1 and stored.writeId ~= "other-window#1" and not b.unsaved, "one write")
		assert(stored.refreshedAt == theirs.refreshedAt and b.watched[TARGET] == true, "on the newer stamp, keeping TARGET")
		local owned = false
		for _, cached in stored.prs do
			if cached.key == TARGET then owned = cached.tandem == true end
		end
		assert(owned, "TARGET's flag is stored")
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		reads(w)[#reads(w)].done(out("CLAIM"))
		assert((w.cacheSets or 0) == before + 1, "an unchanged answer writes nothing more")
	end)

	-- A batch is out when another window stores ownership of a PR whose fix this window is still setting up. The first
	-- command's answer keeps the cache, adopts that ownership and draws it, and the draw raises (the block is gone): the batch
	-- sends no second command, shows no toast and draws nothing, for a merge and for a close.
	for _, merge in { true, false } do
		withWorld(function(w, Fetch, Block)
			local what = if merge then "batch merge" else "batch close"
			local FIRST, SECOND = "acme/api#109", "acme/api#116"
			local b = agentBoard(w, Fetch, Block)
			holdCache(w, b)
			w.runs = {}
			b.github.run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end
			Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
			assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and #w.clones == 1, what .. ": TARGET's setup is pending")
			b.s.confirm = { kind = if merge then "batch-merge" else "batch-close", keys = { FIRST, SECOND } } :: any
			Block.event(b, { ev = "action", act = "hub-confirm", value = "" } :: any, w.cx)
			assert(#w.runs == 1 and b.s.busy[FIRST] ~= nil and b.s.busy[SECOND] == nil, what .. ": the first command is out")

			local theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf + 60)
			w.cx.render = function() error("the window is gone", 0) end
			w.toasts = {}
			local sets = w.cacheSets or 0
			w.runs[1].done(nil, nil)
			assert(b.closed and b.watched[TARGET] == true, what .. ": adopting the ownership drew it and the draw closed the block")
			assert(#w.runs == 1 and b.s.busy[SECOND] == nil, what .. ": no second command")
			assert(#w.toasts == 0 and #w.started == 0 and #handoffs(w) == 0, what .. ": nothing else went on")
			assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], theirs), what .. ": nothing was stored")
		end)
	end

	-- Another window's ownership of an unrelated PR joins at dispatch, the draw that shows it raises (the block is gone), and
	-- the requested action on a PR nobody watches sends nothing.
	for _, act in { "card-auto", "card-update" } do
		withWorld(function(w, Fetch, Block)
			local b = live(w, Block)
			reads(w)[1].done(out("WATCH"))
			w.runs = {}
			b.github = { refresh = function() end, run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end }
			local key = if act == "card-update" then "acme/api#118" else "acme/api#109"
			if act == "card-update" then
				local lagging: any = State.prOf(b.s, key)
				lagging.behind, lagging.conflicts, lagging.draft = true, false, false
			else
				b.s.merges["acme/api"] = { method = { kind = "comment", command = "/merge" }, source = "declared", ask = false }
				b.s.autoMerge["acme/api"] = true
			end
			State.project(b.s)
			holdCache(w, b)
			local OTHER = "acme/api#116"
			local theirs = storeOwned(w, { WEB, API114, OTHER }, Cases.asOf)
			w.cx.render = function() error("the window is gone", 0) end
			Block.event(b, { ev = "action", act = act, value = key } :: any, w.cx)
			assert(b.watched[OTHER] == true and b.closed, act .. ": the join was drawn and the draw closed the block")
			assert(#w.runs == 0 and gh(w) == nil and b.s.busy[key] == nil and State.prOf(b.s, key).pending == nil, act .. ": nothing is sent")
			assert(same(w.kv["hub.cache"], theirs) and #handoffs(w) == 0, act .. ": nothing was stored")
		end)
	end

	-- This window already holds TARGET, and its read of Tandem (which omits TARGET) is out when another window hands TARGET to
	-- Tandem again and stores it, at this cache's stamp or a newer one. Joining that cache moves nothing here (the flag is
	-- held), yet the answer predates the write: it clears nothing and stores nothing, and a replacement read is asked for. That
	-- read, which began after the write, is the one that may clear TARGET.
	for _, bump in { 0, 60 } do
		withWorld(function(w, Fetch, Block)
			local what = if bump == 0 then "same stamp" else "newer stamp"
			local b = agentBoard(w, Fetch, Block)
			b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
			holdCache(w, b)
			claim(w, Block, b)
			assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, what .. ": this window holds TARGET")
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			local answer = reads(w)[#reads(w)]
			local theirs = storedCache({ WEB, API114, TARGET }, Cases.asOf + bump)
			theirs.writeId = "other-window#1"
			w.kv["hub.cache"] = theirs
			local before, asked, joined = w.cacheSets or 0, #reads(w), b.handoffs
			answer.done(out("WATCH"))
			assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, what .. ": TARGET stays owned")
			local owned = card(b.s, TARGET)
			assert(owned.column == "in_review" and owned.main.label == "Hand off to Tandem" and not offers(owned, "card-agent"), what .. ": no Fix with agent")
			assert((w.cacheSets or 0) == before and same(w.kv["hub.cache"], theirs), what .. ": the old answer wrote nothing")
			assert(b.handoffs == joined + 1, what .. ": it counted as a hand-off")
			assert(#reads(w) == asked + 1 and b.flights.tandem, what .. ": a replacement read is out")
			assert(#w.started == 0 and #handoffs(w) == 0 and gh(w) == nil, what .. ": nothing was sent")

			-- The same answer from the read that began after the write does clear it, once.
			reads(w)[asked + 1].done(out("WATCH"))
			assert(not State.prOf(b.s, TARGET).tandem and b.watched[TARGET] == nil and #reads(w) == asked + 1, what .. ": the replacement read decides")
			assert((w.cacheSets or 0) == before + 1 and w.kv["hub.cache"].writeId ~= "other-window#1", what .. ": and stores once")
			for _, cached in w.kv["hub.cache"].prs do
				if cached.key == TARGET then assert(cached.tandem ~= true, what .. ": TARGET is stored cleared") end
			end
		end)
	end

	-- Redraws that close the block end the callback that drew them. Each setup is B's fix for TARGET still being set up when
	-- another window stores ownership of TARGET at this cache's stamp, so the callback's own reconciliation stops the fix and
	-- draws; the draw raises (the window is gone). Nothing is stored, read, queued or armed after that.
	local function settingUp(w: any, Fetch: any, Block: any): any
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		assert(b.agentFlight ~= nil and b.agentFlight.engine == nil and #w.clones == 1, "TARGET's setup is pending")
		return b
	end
	local function gone(w: any)
		w.cx.render = function() error("the window is gone", 0) end
	end

	-- A GitHub refresh's answer, with a refresh already queued behind it.
	withWorld(function(w, Fetch, Block)
		local b = settingUp(w, Fetch, Block)
		local answer: any = nil
		w.refreshes = 0
		b.github = quietGithub(function(_, done) w.refreshes += 1; answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(answer ~= nil and b.flights.refresh and w.refreshes == 1)
		b.refetch = true
		local theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
		gone(w)
		local sets, asked, armed = w.cacheSets or 0, #reads(w), #w.timers
		answer({ viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }, nil)
		assert(b.closed and b.watched[TARGET] == true, "the reconciliation drew and the draw closed the block")
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], theirs), "refresh: nothing was stored")
		assert(w.refreshes == 1 and #reads(w) == asked and #w.timers == armed and not b.flights.refresh, "refresh: nothing was queued, read or armed")
		assert(#w.started == 0 and #handoffs(w) == 0, "refresh: nothing else went on")
	end)

	-- A read of Tandem whose answer names TARGET: stopping the fix draws before the answer is counted and stored.
	withWorld(function(w, Fetch, Block)
		local b = settingUp(w, Fetch, Block)
		b.github = quietGithub(function() end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local answer = reads(w)[#reads(w)]
		local held = copy(w.kv["hub.cache"])
		gone(w)
		local sets, asked = w.cacheSets or 0, #reads(w)
		answer.done(out("CLAIM"))
		assert(b.closed and b.watched[TARGET] == true, "the answer named TARGET and the draw closed the block")
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], held), "watch: nothing was stored")
		assert(#reads(w) == asked and #w.started == 0 and #handoffs(w) == 0 and #w.toasts == 0, "watch: nothing else went on")
	end)

	-- A checks result: applying the ownership stored meanwhile draws before the result is projected and stored.
	withWorld(function(w, Fetch, Block)
		local b = settingUp(w, Fetch, Block)
		local settle: any = nil
		local touched: { [string]: boolean } = {}
		b.github = setmetatable({ checks = function(_, done) settle = done end }, { __index = function(_, name: string): any
			touched[name] = true
			return function() end
		end })
		b.flights.refresh, b.flights.probe = true, true
		w.timers = {}
		Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, w.cx)
		local theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
		runTimers(w)
		assert(settle ~= nil and b.flights.checks and b.watched[TARGET] == nil, "the checks read is out")
		local running = State.prOf(b.s, API114)
		assert(running and running.checks.state == "pending")
		gone(w)
		local sets, armed = w.cacheSets or 0, #w.timers
		settle({ byId = { [running.id] = { headOid = running.headOid, checks = { state = "passing", passing = 3, failing = 0, pending = 0 } } } }, nil)
		assert(b.closed and b.watched[TARGET] == true, "applying the ownership drew and the draw closed the block")
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], theirs), "checks: nothing was stored")
		assert(next(touched) == nil and #w.timers == armed and #w.started == 0 and #handoffs(w) == 0, "checks: nothing was read or armed")
	end)

	-- A hand-off's answer, taken while the same PR's fix is being set up: stopping the fix draws before the card is counted,
	-- stored and toasted.
	withWorld(function(w, Fetch, Block)
		local b = settingUp(w, Fetch, Block)
		Block.event(b, { ev = "action", act = "card-handoff", value = TARGET } :: any, w.cx)
		assert(#handoffs(w) == 1, "the request is out")
		local held = copy(w.kv["hub.cache"])
		gone(w)
		local sets = w.cacheSets or 0
		handoffs(w)[1].done(out("DONE"))
		assert(b.closed and b.watched[TARGET] == true, "stopping the fix drew and the draw closed the block")
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], held), "hand-off: nothing was stored")
		assert(#w.toasts == 0 and #w.started == 0 and #handoffs(w) == 1, "hand-off: nothing else went on")
	end)

	-- A batch whose first command answers after another window stored the ownership at the same stamp: no cache is adopted,
	-- so keeping the cache reaches its own ownership step, which draws and closes the block. Nothing is stored, no second
	-- command is sent and nothing is shown, for a merge and for a close.
	for _, merge in { true, false } do
		withWorld(function(w, Fetch, Block)
			local what = if merge then "same-stamp batch merge" else "same-stamp batch close"
			local FIRST, SECOND = "acme/api#109", "acme/api#116"
			local b = settingUp(w, Fetch, Block)
			w.runs = {}
			b.github.run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end
			b.s.confirm = { kind = if merge then "batch-merge" else "batch-close", keys = { FIRST, SECOND } } :: any
			Block.event(b, { ev = "action", act = "hub-confirm", value = "" } :: any, w.cx)
			assert(#w.runs == 1 and b.s.busy[FIRST] ~= nil and b.s.busy[SECOND] == nil, what .. ": the first command is out")

			local theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
			gone(w)
			w.toasts = {}
			local sets = w.cacheSets or 0
			w.runs[1].done(nil, nil)
			assert(b.closed and b.watched[TARGET] == true, what .. ": the ownership step drew and the draw closed the block")
			assert(#w.runs == 1 and b.s.busy[SECOND] == nil, what .. ": no second command")
			assert(#w.toasts == 0 and #w.started == 0 and #handoffs(w) == 0, what .. ": nothing else went on")
			assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], theirs), what .. ": nothing was stored")
		end)
	end

	-- Adopting another window's newer cache (T2) restores this block's ownership onto it and stores it. That save fails, and a
	-- distinct newer cache (T3) lands during the failure. The write that follows (the hand-off's own) must not lay T2 over T3:
	-- the hand-off stays on the board, nothing more is stored, and the store keeps T3 whole, with its stamp and its data.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		Block.event(b, { ev = "action", act = "card-handoff", value = TARGET } :: any, w.cx)
		assert(#handoffs(w) == 1, "the request is out")
		local t2 = storedCache({ WEB, API114 }, Cases.asOf + 60)
		t2.writeId = "other-window#2"
		w.kv["hub.cache"] = t2
		local t3: any = nil
		local failed = false
		w.failWhen = function(key: string): boolean
			if key ~= "hub.cache" or failed then return false end
			failed = true
			return true
		end
		w.whileFailing = function()
			w.whileFailing = nil
			t3 = storedCache({ WEB, API114, TARGET }, Cases.asOf + 120)
			t3.writeId = "other-window#3"
			for _, cached in t3.prs do
				if cached.key == API114 then cached.title = "Retitled by T3" end
			end
			w.kv["hub.cache"] = t3
		end
		local before = w.cacheSets or 0
		handoffs(w)[1].done(out("DONE"))
		w.failWhen = nil
		assert(failed and t3 ~= nil, "T3 landed while the adoption's save failed")
		assert(b.cache.refreshedAt == t3.refreshedAt and b.held == "other-window#3", "this board is T3's, installed whole by the last read")
		assert(State.prOf(b.s, API114).title == "Retitled by T3", "with T3's data")
		assert(State.prOf(b.s, TARGET).tandem == true and b.watched[TARGET] == true, "the hand-off stays on the board")
		assert((w.cacheSets or 0) == before + 1, "the failed adoption save was the only attempt: nothing was stored after it")
		assert(same(w.kv["hub.cache"], t3) and w.kv["hub.cache"].writeId == "other-window#3", "the store keeps T3 whole")
		assert((Model.epoch(w.kv["hub.cache"].refreshedAt) :: number) > (Model.epoch(b.cache.refreshedAt) :: number), "and its stamp is not lowered")
		for _, cached in w.kv["hub.cache"].prs do
			if cached.key == API114 then assert(cached.title == "Retitled by T3", "with T3's data") end
			if cached.key == TARGET then assert(cached.tandem == true, "and its ownership") end
		end
		assert(#w.toasts == 0 and #w.started == 0, "no toast or effect")
	end)

	-- A merge-when-ready on a PR nobody watches: a cache-writing action that says nothing about Tandem and adds no hand-off.
	local MERGE_KEY = "acme/api#109"
	local function mergeWhenReady(w: any, Block: any, b: any): any
		w.runs = {}
		b.github.run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end
		b.s.merges["acme/api"] = { method = { kind = "comment", command = "/merge" }, source = "declared", ask = false }
		b.s.autoMerge["acme/api"] = true
		State.project(b.s)
		Block.event(b, { ev = "action", act = "card-auto", value = MERGE_KEY } :: any, w.cx)
		assert(#w.runs == 1, "the command is out")
		return w.runs[1]
	end

	-- This window already holds TARGET and its read of Tandem (which omits TARGET) is out. Another window renews the hand-off
	-- and stores it (same stamp or newer), and this window then joins it through an unrelated action whose own save replaces the
	-- stored id. Joining moved nothing (the flag was held), so only the record of the join says the old answer predates the
	-- write: it clears nothing and stores nothing, and a replacement read, which began after the write, may clear TARGET.
	for _, bump in { 0, 60 } do
		withWorld(function(w, Fetch, Block)
			local what = if bump == 0 then "same stamp" else "newer stamp"
			local b = agentBoard(w, Fetch, Block)
			b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
			holdCache(w, b)
			claim(w, Block, b)
			assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, what .. ": this window holds TARGET")
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			local answer = reads(w)[#reads(w)]
			local theirs = storedCache({ WEB, API114, TARGET }, Cases.asOf + bump)
			theirs.writeId = "other-window#1"
			w.kv["hub.cache"] = theirs
			local asked, joined, sets = #reads(w), b.handoffs, w.cacheSets or 0

			local run = mergeWhenReady(w, Block, b)
			run.done(nil, nil)
			local mine = copy(w.kv["hub.cache"])
			assert((w.cacheSets or 0) == sets + 1 and mine.writeId ~= "other-window#1", what .. ": a local save replaced the stored id")
			assert(State.prOf(b.s, MERGE_KEY).pending ~= nil, what .. ": and it is the action's own")
			assert(b.handoffs == joined and b.watched[TARGET] == true, what .. ": joining moved nothing")

			local before = w.cacheSets or 0
			answer.done(out("WATCH"))
			assert(b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem == true, what .. ": TARGET stays owned")
			local owned = card(b.s, TARGET)
			assert(owned.column == "in_review" and owned.main.label == "Hand off to Tandem" and not offers(owned, "card-agent"), what .. ": no Fix with agent")
			assert((w.cacheSets or 0) == before and same(w.kv["hub.cache"], mine), what .. ": the old answer attempted no write")
			assert(b.handoffs == joined + 1, what .. ": it counted as a hand-off")
			assert(#reads(w) == asked + 1 and b.flights.tandem, what .. ": a replacement read is out")
			assert(#w.started == 0 and #handoffs(w) == 0 and gh(w) == nil, what .. ": nothing was sent")

			reads(w)[asked + 1].done(out("WATCH"))
			assert(not State.prOf(b.s, TARGET).tandem and b.watched[TARGET] == nil, what .. ": the replacement read decides")
			assert(#reads(w) == asked + 1 and not b.flights.tandem, what .. ": and ends normally")
			assert((w.cacheSets or 0) == before + 1 and w.kv["hub.cache"].writeId ~= mine.writeId, what .. ": it stores once")
			for _, cached in w.kv["hub.cache"].prs do
				if cached.key == TARGET then assert(cached.tandem ~= true, what .. ": TARGET is stored cleared") end
			end
		end)
	end

	-- Adopting T2 restores ownership and its save fails; T3 (its own id, the SAME stamp, changed data on another PR) lands
	-- during the failure. The board is T2's, so the store's identity is unreconciled until T3 is adopted whole: the next
	-- cache-writing action, or the next answer of a read of Tandem, adopts it before the one write that follows, and
	-- neither lays T2 over it.
	local PENDING = { method = "comment", at = "2026-10-09T11:00:00Z" }
	local function failedAdoption(w: any, Fetch: any, Block: any, pending: boolean?): (any, any, number)
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		Block.event(b, { ev = "action", act = "card-handoff", value = TARGET } :: any, w.cx)
		assert(#handoffs(w) == 1, "the request is out")
		local t2 = storedCache({ WEB, API114 }, Cases.asOf + 60)
		t2.writeId = "other-window#2"
		w.kv["hub.cache"] = t2
		local t3: any = nil
		local failed = false
		w.failWhen = function(key: string): boolean
			if key ~= "hub.cache" or failed then return false end
			failed = true
			return true
		end
		w.whileFailing = function()
			w.whileFailing = nil
			t3 = storedCache({ WEB, API114, TARGET }, Cases.asOf + 60)
			t3.writeId = "other-window#3"
			for _, cached in t3.prs do
				if cached.key == API114 then cached.title = "Retitled by T3" end
				if pending and cached.key == MERGE_KEY then cached.pending = copy(PENDING) end
			end
			w.kv["hub.cache"] = t3
		end
		local before = w.cacheSets or 0
		handoffs(w)[1].done(out("DONE"))
		w.failWhen = nil
		assert(failed and t3 ~= nil, "T3 landed while the adoption's save failed")
		assert(b.cache.refreshedAt == t3.refreshedAt and b.held == "other-window#3", "this board is T3's, installed whole by the last read")
		assert(State.prOf(b.s, API114).title == "Retitled by T3", "with T3's data")
		assert((w.cacheSets or 0) == before + 1 and same(w.kv["hub.cache"], t3), "the failed save was the only attempt and T3 stands")
		return b, t3, before + 1
	end
	local function wholeT3(w: any, b: any, t3: any, sets: number, what: string, flagged: boolean)
		assert((w.cacheSets or 0) == sets + 1, what .. ": exactly one write followed")
		local stored = w.kv["hub.cache"]
		assert(stored.writeId ~= t3.writeId and stored.refreshedAt == t3.refreshedAt, what .. ": it is a new write at T3's stamp")
		for _, cached in stored.prs do
			if cached.key == API114 then assert(cached.title == "Retitled by T3", what .. ": with T3's data") end
			if cached.key == TARGET then assert((cached.tandem == true) == flagged, what .. ": and TARGET as expected") end
		end
		assert(State.prOf(b.s, API114).title == "Retitled by T3" and not b.unsaved, what .. ": the board is T3's")
	end

	withWorld(function(w, Fetch, Block)
		local b, t3, sets = failedAdoption(w, Fetch, Block)
		local run = mergeWhenReady(w, Block, b)
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], t3), "nothing is written before the command answers")
		run.done(nil, nil)
		wholeT3(w, b, t3, sets, "cache-writing action", true)
		assert(State.prOf(b.s, MERGE_KEY).pending ~= nil and w.kv["hub.cache"].prs ~= nil, "the action's change is on T3")
		assert(#w.toasts == 1 and #w.started == 0 and #handoffs(w) == 1, "nothing else went on")
	end)

	for _, answers in { "CLAIM", "WATCH" } do
		withWorld(function(w, Fetch, Block)
			local b, t3, sets = failedAdoption(w, Fetch, Block)
			b.github = quietGithub(function() end)
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			local answer = reads(w)[#reads(w)]
			assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], t3), "nothing is written before the answer")
			answer.done(out(answers))
			wholeT3(w, b, t3, sets, "watch answer " .. answers, answers == "CLAIM")
			assert(#w.started == 0 and #handoffs(w) == 1, "nothing else went on")
		end)
	end

	-- The same failed adoption, and then the store cannot be read when the next cache-writing callback's adoption looks at it.
	-- "No cache" there is a guess, not an answer: while the board's ownership is unstored, that adoption is unsafe, so nothing
	-- is written (not the action's change, not a watch answer's clear). A later read that succeeds adopts T3 whole, and the
	-- write that follows is T3's.
	local function unsafeBoard(w: any, b: any, t3: any, sets: number, what: string)
		assert((w.cacheSets or 0) == sets, what .. ": no write was attempted")
		assert(same(w.kv["hub.cache"], t3) and w.kv["hub.cache"].writeId == "other-window#3", what .. ": T3 stands whole")
		assert(b.cache.refreshedAt == t3.refreshedAt and b.unsaved, what .. ": the board is still T2's, its ownership unstored")
		assert(State.prOf(b.s, API114).title ~= "Retitled by T3", what .. ": and it lacks T3's data")
		assert(State.prOf(b.s, TARGET).tandem == true and b.watched[TARGET] == true, what .. ": TARGET stays owned")
		assert(next(b.retired) == nil and w.failGets == 0, what .. ": nothing retired, and only the one read failed")
		assert(#w.started == 0 and #handoffs(w) == 1, what .. ": no effect reached a branch")
	end

	-- The action's change is a successful local edit the unreadable store could not take. It is laid back onto T3 when the next
	-- read adopts it, and stored with it, while the PR still has the head the edit was made on; a PR that T3 moved is T3's.
	for _, headMoved in { false, true } do
		withWorld(function(w, Fetch, Block)
			local what = if headMoved then "head moved" else "head kept"
			local b, t3, sets = failedAdoption(w, Fetch, Block)
			local run = mergeWhenReady(w, Block, b)
			w.failGets = 1
			run.done(nil, nil)
			unsafeBoard(w, b, t3, sets, "unreadable action")
			assert(State.prOf(b.s, MERGE_KEY).pending ~= nil and #w.toasts == 1, "the action's change stays on the board")
			if headMoved then
				for _, cached in w.kv["hub.cache"].prs do
					if cached.key == MERGE_KEY then cached.headOid = "moved-head" end
				end
			end

			b.github = quietGithub(function() end)
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			reads(w)[#reads(w)].done(out("WATCH"))
			wholeT3(w, b, t3, sets, "watch answer after an unreadable action (" .. what .. ")", false)
			local stored = false
			for _, cached in w.kv["hub.cache"].prs do
				if cached.key == MERGE_KEY then stored = cached.pending ~= nil end
			end
			assert((State.prOf(b.s, MERGE_KEY).pending ~= nil) == not headMoved, what .. ": the board keeps the action's change only on its head")
			assert(stored == not headMoved, what .. ": and so does the cache that was stored")
			assert(#w.started == 0 and #handoffs(w) == 1, "nothing else went on")
		end)
	end

	withWorld(function(w, Fetch, Block)
		local b, t3, sets = failedAdoption(w, Fetch, Block)
		b.github = quietGithub(function() end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local answer = reads(w)[#reads(w)]
		local asked, toasts = #reads(w), #w.toasts
		-- The answer reads the store twice before it decides: the identity it would retire, then the adoption. The second fails.
		local gets = 0
		w.onGet = function()
			gets += 1
			if gets == 2 then w.failGets = 1 end
		end
		answer.done(out("WATCH"))
		w.onGet = nil
		unsafeBoard(w, b, t3, sets, "unreadable watch answer")
		assert(not b.flights.tandem and #reads(w) == asked and #w.toasts == toasts, "the answer is dropped: no clear, no replacement read")

		local run = mergeWhenReady(w, Block, b)
		run.done(nil, nil)
		wholeT3(w, b, t3, sets, "action after an unreadable watch answer", true)
		assert(State.prOf(b.s, MERGE_KEY).pending ~= nil and #w.started == 0 and #handoffs(w) == 1, "the action's change is on T3")
	end)

	-- The store is unreadable for every path that could write a snapshot, whether or not this board's ownership is unstored. The
	-- watch answer here arrives on a board with nothing unsaved: it saw a distinct newer cache (T3) when it looked at the store
	-- first, and then the store failed when it adopted it. The answer would clear this window's flag, and the clear would lay
	-- the older snapshot over T3. It changes nothing instead, and the next answer that can read the store adopts T3 whole.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		b.github = quietGithub(function(_, done) done(nil, { operation = "hub", message = "no answer" }) end)
		holdCache(w, b)
		claim(w, Block, b)
		assert(b.watched[TARGET] == true and not b.unsaved, "this window owns TARGET and nothing is unsaved")
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		local answer = reads(w)[#reads(w)]
		local t3 = storedCache({ WEB, API114 }, Cases.asOf + 120)
		t3.writeId = "other-window#3"
		for _, cached in t3.prs do
			if cached.key == API114 then cached.title = "Retitled by T3" end
		end
		w.kv["hub.cache"] = t3
		local sets, asked, toasts, stamp = w.cacheSets or 0, #reads(w), #w.toasts, b.cache.refreshedAt
		local gets = 0
		w.onGet = function()
			gets += 1
			if gets == 2 then w.failGets = 1 end
		end
		answer.done(out("WATCH"))
		w.onGet = nil
		assert(gets == 2 and w.failGets == 0, "the answer read the store twice and the second read failed")
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], t3), "no write was attempted and T3 stands whole")
		assert(not b.unsaved and b.cache.refreshedAt == stamp and State.prOf(b.s, API114).title ~= "Retitled by T3", "the board is still its own")
		assert(State.prOf(b.s, TARGET).tandem == true and b.watched[TARGET] == true, "TARGET is not cleared")
		assert(next(b.retired) == nil and not b.flights.tandem and #reads(w) == asked, "nothing retired and no replacement read")
		assert(#w.toasts == toasts and #w.started == 0 and #handoffs(w) == 0 and gh(w) == nil, "no effect")

		-- The recovery refresh's GitHub request stays out. One that answers at once (as this board's did above) re-arms the
		-- schedule, whose adoption reads the store, takes T3 and stores TARGET restored onto it before the Tandem answer
		-- comes: that is a second write. Here the answer is the one that adopts T3 whole, then clears and stores once.
		b.github = quietGithub(function() end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(b.flights.refresh and b.flights.tandem and #reads(w) == asked + 1, "the recovery read of Tandem is out, with GitHub's request")
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], t3), "nothing is stored before the answer")
		reads(w)[#reads(w)].done(out("WATCH"))
		wholeT3(w, b, t3, sets, "watch answer after the unreadable one", false)
		assert(#w.started == 0 and #handoffs(w) == 0, "nothing else went on")
	end)

	-- Adopting T2 failed to store its ownership, and T3 (same stamp, changed data, and a pending merge on another PR) is
	-- stored. No refresh may start or finish a snapshot write while the store cannot be read: a GitHub answer carries no
	-- pending record, so a merge against T2 would drop T3's. A refresh that reads the store again keeps it.
	local function freshAnswer(): any
		return { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
	end
	local function pendingOf(cache: any): any
		for _, cached in cache.prs do
			if cached.key == MERGE_KEY then return cached.pending end
		end
		return nil
	end
	local function intactT3(w: any, b: any, t3: any, sets: number, what: string)
		assert((w.cacheSets or 0) == sets, what .. ": no write was attempted")
		assert(same(w.kv["hub.cache"], t3) and w.kv["hub.cache"].writeId == "other-window#3", what .. ": T3 stands whole")
		assert(same(pendingOf(w.kv["hub.cache"]), PENDING), what .. ": with its pending merge")
		assert(b.unsaved and b.cache.refreshedAt == t3.refreshedAt, what .. ": the board is still T2's, its ownership unstored")
		assert(State.prOf(b.s, API114).title ~= "Retitled by T3" and State.prOf(b.s, MERGE_KEY).pending == nil, what .. ": and it lacks T3's data")
		assert(State.prOf(b.s, TARGET).tandem == true and b.watched[TARGET] == true and next(b.retired) == nil, what .. ": TARGET stays owned")
		assert(#w.started == 0 and #handoffs(w) == 1, what .. ": no effect reached a branch")
	end
	local function keptT3(w: any, b: any, t3: any, sets: number, what: string)
		assert((w.cacheSets or 0) == sets + 1, what .. ": the refresh wrote once")
		local stored = w.kv["hub.cache"]
		assert(stored.writeId ~= t3.writeId, what .. ": it is a new write")
		assert(same(pendingOf(stored), PENDING) and State.prOf(b.s, MERGE_KEY).pending ~= nil, what .. ": T3's pending merge went through Sync.merge")
		assert(not b.unsaved, what .. ": the board's ownership is stored")
	end

	-- The scheduled refresh: its adoption cannot read the store, so no request is made and no write is tried. The attempt
	-- counts as tried, so it does not run again at once. A later explicit refresh reads the store and keeps T3.
	withWorld(function(w, Fetch, Block)
		local b, t3, sets = failedAdoption(w, Fetch, Block, true)
		local asked, answer: any = 0, nil
		b.github = quietGithub(function(_, done) asked += 1; answer = done end)
		b.flights.probe = true
		w.timers = {}
		w.failGet = true
		Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, w.cx)
		runTimers(w)
		assert(asked == 0 and not b.flights.refresh and b.sched.refreshTried == w.now, "no request was made, and the attempt counts")
		intactT3(w, b, t3, sets, "scheduled refresh")

		w.failGet = false
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(asked == 1 and b.flights.refresh, "the explicit refresh asks GitHub")
		answer(freshAnswer(), nil)
		keptT3(w, b, t3, sets, "explicit refresh after the unreadable one")
		assert(not b.flights.refresh and not b.s.loading, "and the refresh ended")
	end)

	-- An explicit refresh whose request is out while the store cannot be read: its answer drops. It clears no ownership, writes
	-- nothing, merges nothing and chains no second refresh, even though one was asked for; it shows why, and the next answer
	-- that can read the store adopts T3 whole and writes once.
	withWorld(function(w, Fetch, Block)
		local b, t3, sets = failedAdoption(w, Fetch, Block, true)
		local asked, answer: any = 0, nil
		b.github = quietGithub(function(_, done) asked += 1; answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(asked == 1 and b.flights.refresh and b.refetch, "one request is out and another is asked for")
		w.failGet = true
		answer(freshAnswer(), nil)
		assert(asked == 1 and not b.flights.refresh and not b.s.loading and b.refetch, "the answer chained no refresh")
		assert(b.s.error ~= nil and b.s.error.operation == "hub.cache", "it says why")
		intactT3(w, b, t3, sets, "explicit refresh")

		w.failGet = false
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(asked == 2, "the next refresh asks GitHub")
		answer(freshAnswer(), nil)
		keptT3(w, b, t3, sets, "refresh after the unreadable answer")
		assert(asked == 3 and b.s.error == nil, "only now is the asked-for refresh run")
	end)

	-- A refresh that was out when T3 landed: its answer looks at the store again, adopts T3 whole (its stamp, its data and its
	-- pending merge) and then merges, so the one write that follows keeps the pending merge.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		local asked, answer: any = 0, nil
		b.github = quietGithub(function(_, done) asked += 1; answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(asked == 1 and b.flights.refresh and not pendingOf(w.kv["hub.cache"]), "the request is out")
		local t3 = storedCache({ WEB, API114 }, Cases.asOf + 120)
		t3.writeId = "other-window#3"
		for _, cached in t3.prs do
			if cached.key == MERGE_KEY then cached.pending = copy(PENDING) end
		end
		w.kv["hub.cache"] = t3
		local sets = w.cacheSets or 0
		answer(freshAnswer(), nil)
		keptT3(w, b, t3, sets, "refresh that was out when T3 landed")
		assert(asked == 1 and not b.flights.refresh and not b.s.loading and #handoffs(w) == 0 and #w.started == 0, "nothing else went on")
	end)

	-- Window B stores a cache at the stamp this board holds, with a pending merge on a PR, and this window's next successful
	-- write finds nothing unsaved. The stamp is the same, so only the id tells B's cache from this window's own: it is adopted
	-- whole before the write, which keeps B's pending merge (Cancel merge and its failure tracking still work).
	for _, via in { "hand-off", "refresh" } do
		withWorld(function(w, Fetch, Block)
			local b = agentBoard(w, Fetch, Block)
			holdCache(w, b)
			local answer: any = nil
			b.github = quietGithub(function(_, done) answer = done end)
			local function handOff()
				Block.event(b, { ev = "action", act = "card-handoff", value = TARGET } :: any, w.cx)
				handoffs(w)[#handoffs(w)].done(out("DONE"))
			end
			local function stores(id: string)
				local theirs = storedCache({ WEB, API114 }, Cases.asOf)
				theirs.writeId = id
				for _, cached in theirs.prs do
					if cached.key == MERGE_KEY then cached.pending = copy(PENDING) end
				end
				w.kv["hub.cache"] = theirs
				assert(b.cache.refreshedAt == theirs.refreshedAt and not b.unsaved, via .. ": B stored at this board's stamp")
			end
			local id = "other-window#1"
			if via == "refresh" then
				-- This window has stored before, so its own id is the one it holds when B writes.
				handOff()
				assert(w.kv["hub.cache"].writeId ~= nil and not b.unsaved and State.prOf(b.s, TARGET).tandem == true, via .. ": this window stored")
				id = "other-window#2"
			end
			stores(id)
			assert(State.prOf(b.s, MERGE_KEY).pending == nil, via .. ": this board lacks B's pending merge")
			local sets = w.cacheSets or 0
			if via == "hand-off" then
				handOff()
			else
				Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
				assert(answer ~= nil and b.flights.refresh, via .. ": the request is out")
				answer(freshAnswer(), nil)
			end
			local stored = w.kv["hub.cache"]
			assert((w.cacheSets or 0) > sets and stored.writeId ~= id, via .. ": this window's write followed")
			assert(same(pendingOf(stored), PENDING) and State.prOf(b.s, MERGE_KEY).pending ~= nil, via .. ": B's pending merge went through")
			assert(not b.unsaved and State.prOf(b.s, TARGET).tandem == true and b.watched[TARGET] == true, via .. ": and TARGET stays owned")
			for _, cached in stored.prs do
				if cached.key == TARGET then assert(cached.tandem == true, via .. ": and the hand-off is stored") end
			end
		end)
	end

	-- A closed block's entry paths are dead ends. The busy draw of a hand-off raises (the window is gone): no root is looked
	-- up and nothing is sent, shown or armed.
	withWorld(function(w, Fetch, Block)
		local b = agentBoard(w, Fetch, Block)
		assert(b.root == REPO_ROOT, "the root is known")
		b.root = nil
		w.finds, w.toasts = {}, {}
		gone(w)
		local calls, armed = #w.calls, #w.timers
		Block.event(b, { ev = "action", act = "card-handoff", value = TARGET } :: any, w.cx)
		assert(b.closed, "the busy draw closed the block")
		assert(#w.finds == 0 and b.rootWaiters == nil and b.root == nil, "no root lookup")
		assert(#w.calls == calls and #handoffs(w) == 0 and #w.toasts == 0 and #w.timers == armed, "nothing was sent, shown or armed")
	end)

	-- A refresh whose read of Tandem answers at once, and the reconciliation's draw raises: the refresh reads nothing and
	-- asks GitHub for nothing, and nothing is stored, armed or sent.
	withWorld(function(w, Fetch, Block)
		local b = settingUp(w, Fetch, Block)
		local touched: { [string]: boolean } = {}
		b.github = setmetatable({}, { __index = function(_, name: string): any
			touched[name] = true
			return function() end
		end })
		local base = Fetch.runner
		local theirs: any = nil
		Fetch.runner = function(argv: { string }, opts: any, done: (any) -> ())
			base(argv, opts, done)
			if argv[2] == "watch" then
				theirs = storeOwned(w, { WEB, API114, TARGET }, Cases.asOf)
				done(out("WATCH"))
			end
		end
		gone(w)
		local sets, armed, asked = w.cacheSets or 0, #w.timers, #reads(w)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(theirs ~= nil and #reads(w) == asked + 1, "the read answered at once")
		assert(b.closed and b.watched[TARGET] == true, "its reconciliation drew and the draw closed the block")
		assert(next(touched) == nil, "GitHub was not asked")
		assert((w.cacheSets or 0) == sets and same(w.kv["hub.cache"], theirs), "nothing was stored")
		assert(#w.timers == armed and #w.started == 0 and #handoffs(w) == 0 and #w.toasts == 0 and #reads(w) == asked + 1, "nothing was armed, read or sent")
	end)
end

-- A fix still being set up for a PR whose ownership arrives in a whole board (another window's newer cache adopted on
-- focus, or this window's own GitHub answer) ends as stopped at once, before the clone lookup or the read of Tandem
-- answers, and neither answer starts anything. A running engine and a fix for another PR are left alone.
local function wholeBoard()
	local OTHER = "acme/api#116"
	local function opened(w: any, Fetch: any, Block: any, engine: boolean): any
		local b = agentBoard(w, Fetch, Block)
		b.github = quietGithub(function(_, done) w.answer = done end)
		Block.event(b, { ev = "action", act = "card-agent", value = TARGET } :: any, w.cx)
		if engine then
			w.clones[1].done("/clone", nil)
			gh(w).done(out("REFS"))
			assert(#w.started == 1 and b.agentFlight.engine ~= nil)
		else
			assert(#w.clones == 1 and b.agentFlight ~= nil and b.agentFlight.engine == nil)
		end
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(w.answer ~= nil and b.flights.refresh and b.flights.tandem and #reads(w) == 2, "the read of Tandem is out")
		return b
	end
	local function arrive(w: any, Block: any, b: any, how: string, owned: { string })
		w.kvIn = { ["hub.cache"] = storedCache(owned, Cases.asOf + 60) }
		if how == "focus" then
			Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, w.cx)
		else
			w.answer({ viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }, nil)
		end
	end

	for _, how in { "focus", "refresh" } do
		withWorld(function(w, Fetch, Block)
			local b = opened(w, Fetch, Block, false)
			arrive(w, Block, b, how, { WEB, API114, TARGET })
			assert(State.prOf(b.s, TARGET).tandem == true and b.watched[TARGET] == true, how)
			noFixer(w, b, how .. ": stopped before any answer")
			assert(#reads(w) == 2 and b.flights.tandem and #w.clones == 1, how .. ": both answers are still out")
			w.clones[1].done("/clone", nil)
			assert(gh(w) == nil, how .. ": the late lookup reads no refs")
			noFixer(w, b, how .. ": after the lookup")
			reads(w)[2].done(out("WATCH"))
			noFixer(w, b, how .. ": after the read of Tandem")
			frozen(b)
			assert(#w.toasts == 0 and card(b.s, TARGET).chips[1].text == "Waiting on Tandem", how)
		end)

		-- A running engine is Stop's.
		withWorld(function(w, Fetch, Block)
			local b = opened(w, Fetch, Block, true)
			arrive(w, Block, b, how, { WEB, API114, TARGET })
			assert(State.prOf(b.s, TARGET).tandem == true)
			assert(#w.started == 1 and b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running" and w.stops == 0, how .. ": the engine stays")
		end)

		-- Ownership of another PR leaves this setup going.
		withWorld(function(w, Fetch, Block)
			local b = opened(w, Fetch, Block, false)
			arrive(w, Block, b, how, { WEB, API114, OTHER })
			assert(State.prOf(b.s, OTHER).tandem == true and not State.prOf(b.s, TARGET).tandem)
			assert(b.agentFlight ~= nil and b.s.agents[TARGET].kind == "running" and #w.clones == 1, how .. ": an unrelated fix stays")
			w.clones[1].done("/clone", nil)
			assert(gh(w) ~= nil, how .. ": and goes on")
		end)
	end
end

local function fixture()
	withWorld(function(w, Fetch, Block)
		local cx: any = { cwd = REPO_ROOT }
		function cx:render() w.renders += 1 end
		function cx:toast(kind: string, title: string, detail: string?) table.insert(w.toasts, { kind = kind, title = title, detail = detail }) end
		function cx:frame() end
		function cx:open() end
		local b: any = Block.init(cx, { "fixture=cases" }, nil)
		w.b, w.cx = b, cx
		local function chip(key: string): string
			return card(b.s, key).chips[1].text
		end
		assert(#w.calls == 0 and #w.finds == 0 and b.s.error == nil, "the sample board runs no process")
		assert(chip("acme/web#104") == "Waiting on Tandem" and card(b.s, "acme/web#104").column == "in_review")
		assert(chip("acme/api#114") == "Waiting on Tandem" and not Cases.prs[1].tandem, "the recorded boards are not edited")
		for _, source in Cases.prs do assert(source.tandem == false, source.key) end

		-- Every ⌘R brings its own boards, flagged from the same recorded read.
		for _ = 1, 3 do
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, cx)
			runTimers(w)
			assert(#w.calls == 0 and #w.finds == 0)
			assert(chip("acme/web#104") == "Waiting on Tandem" and card(b.s, "acme/web#104").pr.tandem)
			assert(card(b.s, "acme/api#112").column == "needs_fixes" and not card(b.s, "acme/api#112").pr.tandem)
		end

		-- The sample board hands nothing off.
		w.toasts = {}
		State.select(b.s, "acme/web#104")
		press(w, "a")
		assert(#w.calls == 0 and #w.finds == 0 and #w.toasts == 1 and w.toasts[1].kind == "info")
		for _, source in Cases.prs do assert(source.tandem == false, source.key) end
	end)
end

-- Local edits a store could not take, and the actions that make them. A replay keeps the stamp the edit was made with; an
-- edit applies only on the head its action began on; a refresh that was out when the edit was made cannot bring the PR back.
local function replayedEdits()
	local KEY = "acme/api#109"
	local function iso(at: number): string
		return os.date("!%Y-%m-%dT%H:%M:%SZ", at) :: string
	end
	local function holdCache(w: any, b: any)
		w.shared = true
		w.kv["hub.cache"] = storedCache({ WEB, API114 }, Cases.asOf)
		b.cache = Sync.load(copy(w.kv["hub.cache"]))
		assert(b.cache ~= nil, "this window holds a cache of the store's stamp")
	end
	-- Another window's newer cache, at `Cases.asOf + 60`, with `patch` applied to KEY's stored PR.
	local function theirs(w: any, patch: ((any) -> ())?): any
		local cache = storedCache({ WEB, API114 }, Cases.asOf + 60)
		cache.writeId = "other-window#1"
		-- A refresh that began after the edit's snapshot was stamped: its heads are the later word on them.
		cache.sinceAt = Cases.asOf + 30
		for _, cached in cache.prs do
			if cached.key == KEY and patch then patch(cached) end
		end
		w.kv["hub.cache"] = cache
		return cache
	end
	local function stored(cache: any): any
		for _, cached in cache.prs do
			if cached.key == KEY then return cached end
		end
		return nil
	end
	local function freshAnswer(): any
		return { viewer = "jubbydev", prs = copy(Cases.prs), rateLimit = nil, calls = {}, truncated = false }
	end
	local function board(w: any, Fetch: any, Block: any): any
		local b = agentBoard(w, Fetch, Block)
		holdCache(w, b)
		w.runs = {}
		b.github = quietGithub(function() end)
		b.github.run = function(command: any, done: any) table.insert(w.runs, { command = command, done = done }) end
		b.s.merges["acme/api"] = { method = { kind = "comment", command = "/merge" }, source = "declared", ask = false }
		b.s.autoMerge["acme/api"] = true
		State.project(b.s)
		return b
	end
	local function auto(w: any, Block: any, b: any): any
		Block.event(b, { ev = "action", act = "card-auto", value = KEY } :: any, w.cx)
		assert(#w.runs == 1, "the command is out")
		return w.runs[1]
	end
	local function closeBatch(w: any, Block: any, b: any): any
		w.runs = {}
		b.s.confirm = { kind = "batch-close", keys = { KEY } } :: any
		Block.event(b, { ev = "action", act = "hub-confirm", value = "" } :: any, w.cx)
		assert(#w.runs == 1, "the close is out")
		return w.runs[1]
	end
	local function holds(b: any, key: string): boolean
		return State.prOf(b.s, key) ~= nil
	end

	-- A comment merge succeeds at T0 and its save fails; a bot rejects it at T1; recovery at T2 replays the edit. The pending
	-- record keeps T0, so the rejection (after T0) still counts, on the board and in what is stored.
	withWorld(function(w, Fetch, Block)
		local b = board(w, Fetch, Block)
		local run = auto(w, Block, b)
		local t0 = w.now
		local t1, t2 = t0 + 60, t0 + 120
		local failed = false
		w.failWhen = function(key: string): boolean
			if key ~= "hub.cache" or failed then return false end
			failed = true
			return true
		end
		run.done(nil, nil)
		w.failWhen = nil
		assert(failed and #b.replays == 1, "the save failed and the edit is retained")
		assert(State.prOf(b.s, KEY).pending.at == iso(t0), "the merge is pending since T0")

		w.now = t2
		theirs(w, nil)
		local answer: any = nil
		b.github = quietGithub(function(_, done) answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(answer ~= nil, "the refresh is out")
		answer(freshAnswer(), nil)
		assert(#b.replays == 0, "the stored write holds the edit")
		for _, at in { State.prOf(b.s, KEY).pending.at, stored(w.kv["hub.cache"]).pending.at } do
			assert(at == iso(t0) and at < iso(t1), "replay at T2 kept T0, so a rejection at T1 is after it")
		end
	end)

	-- A merge action began on H1 and another window stored H2 before the answer. The edit applies on neither the board nor the
	-- store, and nothing is retained for a later replay; on H1 it applies (the control).
	for _, act in { "auto", "close" } do
		for _, moved in { false, true } do
			withWorld(function(w, Fetch, Block)
				local what = act .. (if moved then " on a moved head" else " on the same head")
				local b = board(w, Fetch, Block)
				local run = if act == "auto" then auto(w, Block, b) else closeBatch(w, Block, b)
				theirs(w, function(cached: any) if moved then cached.headOid = "moved-head" end end)
				run.done(nil, nil)
				local applied = if act == "auto" then State.prOf(b.s, KEY).pending ~= nil else not holds(b, KEY)
				assert(applied == not moved, what .. ": the board")
				local there = stored(w.kv["hub.cache"])
				assert((if act == "auto" then there.pending ~= nil else there == nil) == not moved, what .. ": the store")
				assert(#b.replays == 0 or not moved, what .. ": no stale replay is retained")
				if moved then
					assert(State.prOf(b.s, KEY).headOid == "moved-head" and #b.replays == 0, what .. ": H2 stands")
				end
			end)
		end
	end

	-- A close succeeds while a refresh is out, and the unreadable store retains its removal. When reads recover the adoption
	-- replays it; the older refresh result then brings the same-head PR back through the merge. It is removed again before the
	-- counts and the write, so the stored cache and its counts lack it.
	withWorld(function(w, Fetch, Block)
		local b = board(w, Fetch, Block)
		local answer: any = nil
		b.github.refresh = function(_, done) answer = done end
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(answer ~= nil and b.flights.refresh, "the refresh is out")
		local run = closeBatch(w, Block, b)
		w.failGets = 1
		run.done(nil, nil)
		assert(w.failGets == 0 and not holds(b, KEY) and #b.replays == 1, "the removal is retained: the store could not be read")
		assert(stored(w.kv["hub.cache"]) ~= nil, "and the store still holds the PR")

		theirs(w, nil)
		local sets = w.cacheSets or 0
		answer(freshAnswer(), nil)
		assert(not holds(b, KEY) and stored(b.cache) == nil, "the answer did not bring the PR back")
		assert((w.cacheSets or 0) == sets + 1 and stored(w.kv["hub.cache"]) == nil and #b.replays == 0, "the one write lacks it, and clears the replay")
		assert(w.kv["hub.cache"].counts.toReview == b.cache.counts.toReview and b.cache.prs == b.s.prs, "the counts follow the board")
		local count = 0
		for _, pr in b.s.prs do
			if Model.classify(pr, b.s.now) == "needs_fixes" then count += 1 end
		end
		assert(b.cache.counts.needFixes == count, "and so do the Needs fixes")
	end)

	-- An edit retained after a failed save is dropped for good once an adoption sees the PR at another head in a snapshot
	-- requested after the edit's own, so a refresh that was out from before and answers on the old head neither replays it nor
	-- stores it.
	for _, act in { "auto", "close" } do
		withWorld(function(w, Fetch, Block)
			local what = act .. " retained on H1, adopted H2, then the older refresh"
			local b = board(w, Fetch, Block)
			local answer: any = nil
			b.github.refresh = function(_, done) answer = done end
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			assert(answer ~= nil and b.flights.refresh, what .. ": the refresh is out")
			local run = if act == "auto" then auto(w, Block, b) else closeBatch(w, Block, b)
			local failed = false
			w.failWhen = function(key: string): boolean
				if key ~= "hub.cache" or failed then return false end
				failed = true
				return true
			end
			run.done(nil, nil)
			w.failWhen = nil
			assert(failed and #b.replays == 1, what .. ": the save failed and the edit is retained")

			theirs(w, function(cached: any) cached.headOid = "moved-head" end)
			Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, w.cx)
			assert(State.prOf(b.s, KEY).headOid == "moved-head" and #b.replays == 0, what .. ": the adoption drops the H1 edit")
			assert(State.prOf(b.s, KEY).pending == nil and holds(b, KEY), what .. ": and does not apply it to H2")

			answer(freshAnswer(), nil)
			assert(#b.replays == 0, what .. ": the older answer retains nothing")
			assert(State.prOf(b.s, KEY) == nil or State.prOf(b.s, KEY).pending == nil, what .. ": and replays nothing onto the board")
			local there = stored(w.kv["hub.cache"])
			assert(there == nil or there.pending == nil, what .. ": nor into the store")
			assert(holds(b, KEY) == (stored(b.cache) ~= nil), what .. ": the board and the cache agree")
		end)
	end

	-- This window saw KEY on H2 (the recorded head) and keeps an H2 edit after a failed save. Another window's refresh carries
	-- H1 and is stamped later, but its request began before this window's snapshot, or says when it began nowhere: the stamp
	-- proves nothing about the head, so adopting it drops nothing. The next answer on H2 applies the edit and stores it.
	for _, variant in { "a delayed request", "no request time", "a request in the same second" } do
		withWorld(function(w, Fetch, Block)
			local b = board(w, Fetch, Block)
			local run = auto(w, Block, b)
			local failed = false
			w.failWhen = function(key: string): boolean
				if key ~= "hub.cache" or failed then return false end
				failed = true
				return true
			end
			run.done(nil, nil)
			w.failWhen = nil
			local t0 = w.now
			assert(failed and #b.replays == 1 and b.replays[1].at == Cases.asOf, variant .. ": retained, seen by the snapshot's stamp")
			local h2 = State.prOf(b.s, KEY).headOid

			local delayed = theirs(w, function(cached: any) cached.headOid = "h1-delayed" end)
			if variant == "a delayed request" then
				delayed.sinceAt = Cases.asOf - 10
			elseif variant == "no request time" then
				delayed.sinceAt = nil
			else
				delayed.sinceAt = Cases.asOf
			end
			assert(delayed.refreshedAt > b.cache.refreshedAt, variant .. ": its stamp is later")
			Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, w.cx)
			assert(State.prOf(b.s, KEY).headOid == "h1-delayed" and b.cache.refreshedAt == delayed.refreshedAt, variant .. ": it is adopted")
			assert(#b.replays == 1 and b.replays[1].head == h2 and not b.replays[1].applied, variant .. ": the H2 edit waits")
			assert(State.prOf(b.s, KEY).pending == nil, variant .. ": and is not applied to H1")

			w.now += 120
			local answer: any = nil
			b.github = quietGithub(function(_, done) answer = done end)
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
			assert(answer ~= nil, variant .. ": the refresh is out")
			local requested = w.now
			answer(freshAnswer(), nil)
			assert(State.prOf(b.s, KEY).headOid == h2 and State.prOf(b.s, KEY).pending.at == iso(t0), variant .. ": H2 comes back with its edit")
			assert(#b.replays == 0 and stored(w.kv["hub.cache"]).pending.at == iso(t0), variant .. ": the write holds it")
			assert(w.kv["hub.cache"].sinceAt == requested, variant .. ": and says when its request began")
		end)
	end

	-- An edit retained on H1 stays through a successful write that does not hold it: a capped cache another window stored omits
	-- the PR (absence proves nothing about its head), an unrelated hand-off then stores the board, and the replay is still
	-- there when a refresh returns the PR on H1, which gets its pending merge back.
	withWorld(function(w, Fetch, Block)
		local b = board(w, Fetch, Block)
		local run = auto(w, Block, b)
		local failed = false
		w.failWhen = function(key: string): boolean
			if key ~= "hub.cache" or failed then return false end
			failed = true
			return true
		end
		run.done(nil, nil)
		w.failWhen = nil
		local t0 = w.now
		assert(failed and #b.replays == 1, "the save failed and the edit is retained")

		local capped = theirs(w, nil)
		local kept: { any } = {}
		for _, cached in capped.prs do
			if cached.key ~= KEY then table.insert(kept, cached) end
		end
		capped.prs = kept
		Block.event(b, { ev = "action", act = "hub-focused", value = "" } :: any, w.cx)
		assert(not holds(b, KEY) and b.cache.refreshedAt == capped.refreshedAt, "the capped cache is adopted")
		assert(#b.replays == 1 and not b.replays[1].applied, "its absence neither applies nor drops the edit")

		local sets = w.cacheSets or 0
		Block.event(b, { ev = "action", act = "card-handoff", value = WEB } :: any, w.cx)
		assert(#handoffs(w) == 1, "the hand-off is out")
		handoffs(w)[1].done(out("DONE"))
		assert((w.cacheSets or 0) == sets + 1 and w.kv["hub.cache"].writeId == b.held, "the hand-off stored the board")
		assert(not holds(b, KEY) and stored(w.kv["hub.cache"]) == nil, "and that board lacks the PR")
		assert(#b.replays == 1, "the write held no effect of the edit, so it stays")

		w.now += 120
		local answer: any = nil
		b.github = quietGithub(function(_, done) answer = done end)
		Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
		assert(answer ~= nil, "the refresh is out")
		answer(freshAnswer(), nil)
		assert(holds(b, KEY) and State.prOf(b.s, KEY).pending.at == iso(t0), "the PR returns on H1 with its pending merge")
		assert(stored(w.kv["hub.cache"]).pending.at == iso(t0) and #b.replays == 0, "which the write stores and clears")
	end)

	-- Another window stores a complete cache with a pending merge and an ownership between this action's first adoption and
	-- its last read before the write. The write is built on that cache: it keeps what it holds, with this window's edit on it.
	withWorld(function(w, Fetch, Block)
		local b = board(w, Fetch, Block)
		local run = auto(w, Block, b)
		local external = storedCache({ WEB, API114, TARGET }, Cases.asOf + 60)
		external.writeId = "other-window#1"
		for _, cached in external.prs do
			if cached.key == TARGET then cached.pending = { method = "comment", at = iso(Cases.asOf + 50) } end
		end
		w.onGet = function()
			-- The edit lands after the first adoption, so this is the read that decides the write.
			local mine = State.prOf(b.s, KEY)
			if mine and mine.pending ~= nil then
				w.onGet = nil
				w.kv["hub.cache"] = external
			end
		end
		local sets = w.cacheSets or 0
		run.done(nil, nil)
		assert(w.onGet == nil, "the other window wrote before the final read")
		local there = w.kv["hub.cache"]
		assert((w.cacheSets or 0) == sets + 1 and there.writeId == b.held and there.writeId ~= "other-window#1", "one write built on it")
		assert(there.refreshedAt == external.refreshedAt, "the stamp never goes down")
		local other, own
		for _, cached in there.prs do
			if cached.key == TARGET then other = cached end
			if cached.key == KEY then own = cached end
		end
		assert(other and other.pending and other.pending.at == iso(Cases.asOf + 50), "the other window's pending merge survives")
		assert(other.tandem == true and b.watched[TARGET] == true and State.prOf(b.s, TARGET).tandem, "and so does its ownership")
		assert(own and own.pending and State.prOf(b.s, KEY).pending ~= nil, "this window's edit is on it")
		assert(#b.replays == 0 and not b.unsaved and b.cache.prs == b.s.prs, "the write holds it all")
	end)
end

return function()
	parser()
	placement()
	fetching()
	blockPaths()
	rootPaths()
	staleRead()
	counts()
	agentOverlap()
	cachedStartup()
	sharedCache()
	terminalAgents()
	reverseSharedCache()
	delayedRefresh()
	sharedStore()
	mixedAge()
	staleUpdate()
	readyPush()
	retainedLease()
	preWorktreeLease()
	watchedMerge()
	queuedMerge()
	sharedOwnership()
	wholeBoard()
	replayedEdits()
	fixture()
end
