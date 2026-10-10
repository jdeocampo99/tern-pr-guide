--!strict
-- The Tandem hand-off: the watch parser, where a watched PR sits and what its card offers, the exact argv and
-- stdin of both Tandem calls, and the real hub block driven through them. `tern` is stubbed in the module
-- environments of block and fetch, and every process effect is a recorded call that a scenario settles by hand.
local Cases: any = require("../fixtures/hub/cases")
local Model = require("../src/hub/model")
local State = require("../src/hub/state")
local Sync = require("../src/hub/sync")
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
		kv = { get = function(key: string): any return if w.kvIn then w.kvIn[key] else nil end, set = function(key: string, value: any) w.kv[key] = value end },
	}
end

local function withWorld(run: (w: any, Fetch: any, Block: any) -> ())
	local Block: any = require("../src/hub/block")
	local Fetch: any = require("../src/fetch")
	local blockEnv: any, fetchEnv: any = getfenv(Block.init), getfenv(Fetch.tandemWatch)
	local hostBlock, hostFetch, hostRunner, hostFind = blockEnv.tern, fetchEnv.tern, Fetch.runner, Fetch.findRepo
	local hostClone, hostStart = Fetch.findAgentClone, Fetch.startAgentFix
	local w: any = {
		decoded = {}, encoded = {}, timers = {}, calls = {}, toasts = {}, renders = 0, throws = false, Block = Block,
		finds = {}, holdRoot = false, rootFails = false, findThrows = false, kv = {},
	}
	local stub = stubTern(w)
	blockEnv.tern, fetchEnv.tern = stub, stub
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
			b.watched[TARGET] = true
			w.kvIn = { ["hub.cache"] = storedCache({ WEB, API114, TARGET }, Cases.asOf + 60) }
			Block.event(b, { ev = "action", act = "hub-refresh", value = "" } :: any, w.cx)
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
	fixture()
end
