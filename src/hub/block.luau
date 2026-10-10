--!strict
-- The PR hub block: reads its arguments, loads the board's pull requests (for now only the recorded
-- fixture), draws it, and turns clicks and keys into state changes plus the scrolling, focusing and toasts
-- only a live window can do. Clicks (`event`) and keys (`key`) both run one ACTIONS table.
local Agent = require("../agent")
local AgentFix = require("./agent-fix")
local Board = require("../view/hub/board")
local Fetch = require("../fetch")
local Fields = require("../text-field")
local FixesPage = require("../view/hub/fixes")
local Fixes = require("./fixes")
local Github = require("../github")
local Keys = require("../keys")
local Model = require("./model")
local Paths = require("../view/hub/paths")
local ReviewFix = require("./review-fix")
local ReviewFixPage = require("../view/hub/review-fix")
local State = require("./state")
local Sync = require("./sync")

type State = State.State

export type Timers = { probe: TimerHandle?, refresh: TimerHandle?, checks: TimerHandle?, debounce: TimerHandle?, ring: TimerHandle? }

-- What the schedule reads, kept between ticks. Times are seconds since the epoch.
type Sched = {
	probedAt: number?, probeChanged: boolean, -- the last probe, and whether it saw a change no refresh has covered
	focusedAt: number?, -- a focus (or the open) no refresh has covered
	checksAt: number?,
	refreshTried: number?, -- the last refresh attempt, kept on failure so a failed refresh never retries at once
	lastModified: string?, -- the probe's validator
}

-- Only Block holds an engine or a pending folder callback. The token survives synchronous
-- completion before Fetch.startAgentFix returns its handle.
type AgentFlight = {
	key: string, engine: AgentFix.Engine?, settled: boolean, stopping: boolean,
	cancel: (() -> ())?, releasing: boolean, starting: boolean?, fixtureStep: number?,
}

-- The hub block's own state.
export type Block = {
	s: State,
	cache: Sync.Cache?, -- what `hub.cache` last held (or this block last wrote)
	fixture: string?, -- `fixture=cases`: recorded data, no network, no timers
	generate: boolean, -- ⏎ opens the PR with the AI guide started
	agent: Agent.Agent?, -- the reader's own agent, once found (never with a fixture)
	agentFlight: AgentFlight?, -- lookup, engine and retained lease; never serialized
	github: Github.Client, timers: Timers,
	flights: { refresh: boolean, checks: boolean, probe: boolean, flake: boolean }, -- one call of each kind at a time
	sched: Sched,
	closed: boolean, -- a render failed: the window is gone, so no timer starts anything
	refetch: boolean, -- a refresh was asked for while one was running: run another when it ends
	show: Model.PRRef?, -- a pull request just added by link: select it when the refresh brings it
	records: { [string]: Sync.MergeRecord }, -- each repo's hub.merge.* record, read once
	detecting: { [string]: boolean }, -- repos whose merge method was asked for this session (once each, success or not)
	histories: Github.HistoryCache, -- each repo's base-branch run history, read once an hour (memory only: no kv key)
	flakeTried: { [string]: boolean }, -- cards (by key and head) whose evidence was read this session, success or not
	step: number, -- fixture only: how many `refreshes` entries ⌘R has applied
}

type Handler = (b: Block, cx: BlockCx, value: string) -> ()

local ARGS = "generate=true|false and fixture=<name> (cases, rereview, agent-cards, review-fix)"

-- Fixtures by name, loaded only when asked for. `cases` is the rules' recorded pull requests.
local FIXTURES: { [string]: () -> any } = {
	cases = function() return require("../../fixtures/hub/cases") end,
	rereview = function() return require("../../fixtures/hub/rereview") end,
	["agent-cards"] = function() return require("../../fixtures/hub/agent-cards") end,
	["review-fix"] = function() return require("../../fixtures/hub/review-fix") end,
}

-- The recently opened pull requests a fixture board shows, so the fold has rows without a kv store.
local SAMPLE_RECENT: { Sync.Opened } = {
	{ repo = "acme/api", number = 412, title = "Add retry budget to the billing client", author = "dana", at = "2026-10-08T09:12:33Z" },
	{ repo = "acme/web", number = 977, title = "Move the settings tabs into the sidebar", author = "ruben", at = "2026-10-06T16:40:02Z" },
	{ repo = "acme/api", number = 398, title = "Drop the unused webhook table", author = "mei", at = "2026-09-29T11:05:48Z" },
}


-- The agent a fixture board shows, so ⇧M has something to choose from without running omp.
local SAMPLE_AGENT: State.AgentChoice = {
	models = {
		{ selector = "anthropic/claude-opus", name = "claude-opus", efforts = { "low", "medium", "high" } },
		{ selector = "anthropic/claude-sonnet", name = "claude-sonnet", efforts = { "low", "medium", "high" } },
		{ selector = "openai/gpt", name = "gpt", efforts = {} },
	},
	model = "anthropic/claude-opus", effort = "high",
}

-- Sends frame ops after the render that draws their targets. A target the render dropped makes the frame
-- fail, which leaves nothing to do.
local function frameLater(cx: BlockCx, ops: { any })
	tern.timer(1, function()
		pcall(function() cx:frame(ops) end)
	end)
end

local function revealSelected(b: Block, cx: BlockCx)
	local card = State.selectedCard(b.s)
	if card then return frameLater(cx, { { "reveal", Paths.card(card), "nearest" } }) end
	local recent = State.selectedRecent(b.s)
	if recent then frameLater(cx, { { "reveal", Paths.recentRow(State.recentKey(recent)), "nearest" } }) end
end

-- Reads `name=value` block arguments.
local function options(args: { string }): ({ generate: boolean, fixture: string? }?, string?)
	local out: { generate: boolean, fixture: string? } = { generate = false, fixture = nil }
	for _, arg in args do
		local name, value = string.match(arg, "^(%a+)=(.*)$")
		if name ~= "generate" and name ~= "fixture" then
			return nil, "Unknown argument \"" .. arg .. "\". The block takes " .. ARGS .. "."
		end
		if name == "generate" then
			if value ~= "true" and value ~= "false" then
				return nil, "generate= takes true or false, not \"" .. (value :: string) .. "\". The block takes " .. ARGS .. "."
			end
			out.generate = value == "true"
		elseif FIXTURES[value :: string] == nil then
			return nil, "Unknown fixture \"" .. (value :: string) .. "\". The block takes " .. ARGS .. "."
		else
			out.fixture = value
		end
	end
	return out, nil
end

-- A card action whose effect arrives with its own change: the card shows its label and key already.
local function notYet(what: string): Handler
	return function(b, cx, value)
		local card = State.card(b.s, value)
		cx:toast("info", what .. " isn't available yet", if card then card.pr.key else nil)
	end
end

-- Opens PR `number` of `slug` ("owner/repo") in the guide. The block can't open blocks, so it finds a
-- checkout of the repo (beside the hub's folder, else PR Guide's own copy) and opens a link the window
-- routes to the guide (`State.openPlan`). With no checkout and no copy to make, it says why and opens
-- nothing. A card's open action uses this too.
local function openPr(b: Block, cx: BlockCx, slug: string, number: number, generate: boolean)
	local dir = cx.cwd or tern.getenv("HOME") or ""
	Fetch.checkoutFor(nil, dir, slug, function(found)
		if b.closed then return end
		local _, why = Fetch.savedCopy("github.com", slug)
		local plan = State.openPlan(slug, number, generate, if found then found.root else nil, why, dir)
		if plan.kind == "open" then
			cx:open(plan.url)
		else
			cx:toast("error", plan.text, plan.sub)
		end
	end)
end

local openFixes: (b: Block, cx: BlockCx, key: string) -> ()
local openReviewFix: (b: Block, cx: BlockCx, key: string) -> ()

-- ⏎ and a double-click open the selected row; ⇧⏎ (or a hub opened for AI guides) starts the AI guide too.
local function openRow(b: Block, cx: BlockCx, value: string, withGuide: boolean)
	local s = b.s
	if value ~= "" then State.select(s, value) end
	local generate = withGuide or b.generate
	local recent = State.selectedRecent(s)
	if recent then return openPr(b, cx, recent.repo, recent.number, generate) end
	local card = State.selectedCard(s)
	if card == nil then return end
	if card.agent and card.agent.kind == "ready" then return openReviewFix(b, cx, card.pr.key) end
	-- A Needs fixes card opens at what needs fixing; the AI guide still opens the whole pull request.
	if card.column == "needs_fixes" and not generate then return openFixes(b, cx, card.pr.key) end
	openPr(b, cx, card.pr.repo, card.pr.number, generate)
end

local function openCard(b: Block, cx: BlockCx, value: string)
	openRow(b, cx, value, false)
end

local function closeMenu(b: Block)
	State.closeMenu(b.s)
end

-- Remembers the agent choice for guides and the hub after the agent menu picked one.
local function keepAgentChoice(b: Block)
	local choice, agent = b.s.agent, b.agent
	if choice and agent then
		agent.model, agent.effort = choice.model, choice.effort
		Fetch.saveChoice(agent)
	end
end

local chooseMergeRow: (b: Block, cx: BlockCx, index: number) -> ()

-- Chooses the highlighted row: a card's other action runs, a model is remembered.
local function pickRow(b: Block, cx: BlockCx, index: number, ACTIONS: { [string]: Handler })
	local s = b.s
	if s.menu == "actions" then
		local more = State.actionAt(s, index)
		local card = State.selectedCard(s)
		State.closeMenu(s)
		local handler = if more then ACTIONS[more.act] else nil
		if handler and card then handler(b, cx, card.pr.key) end
		return
	end
	if s.menu == "merge" then return chooseMergeRow(b, cx, index) end
	local menu = s.menu
	State.menuPick(s, index)
	if menu == "agent" then keepAgentChoice(b) end
end

-- Sync: the cache, the timers and the live data ----------------------------------------------------------
-- Visibility is not observable from a block, so the hub polls for as long as the block exists (parked or in a
-- background tab). A closed block is found out by a failing render, which ends every chain.

local KV_CACHE, KV_ADDED, KV_STATUS = "hub.cache", "hub.added", "hub.status"
local CACHE_CAP_BYTES = 1024 * 1024

local function kvGet(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

-- The cache other windows (or an earlier run) stored, if it is a valid schema 1.
local function readCache(): Sync.Cache?
	return Sync.load(kvGet(KV_CACHE))
end

-- Facts only this machine knows. `tandem` waits for the Tandem change.
local function readLocal(): Sync.Local
	local added: Sync.Added = {}
	local raw = kvGet(KV_ADDED)
	if type(raw) == "table" then
		for key, ref in raw do
			if type(key) == "string" and type(ref) == "table" and type(ref.repo) == "string" and type(ref.number) == "number" then
				added[key] = { repo = ref.repo, number = ref.number }
			end
		end
	end
	return { added = added, tandem = {} }
end

-- The tiny record the window's status segment reads every 2 s, so it never decodes the whole cache.
local function writeStatus(cache: Sync.Cache)
	local counts = cache.counts
	pcall(tern.kv.set, KV_STATUS, {
		refreshedAt = cache.refreshedAt,
		counts = { toReview = counts.toReview, needFixes = counts.needFixes, flashAt = counts.flashAt },
	})
end

-- Writes the cache under the size cap. Returns why it failed; memory state stands either way.
local function persist(b: Block): string?
	local cache = b.cache
	if not cache then return nil end
	local ok, err = pcall(function()
		tern.kv.set(KV_CACHE, Sync.save(cache, CACHE_CAP_BYTES, function(value: any): number return #tern.json.encode(value) end))
	end)
	if ok then writeStatus(cache) end
	return if ok then nil else tostring(err)
end

local function cachedAt(b: Block): number?
	return if b.cache then Model.epoch(b.cache.refreshedAt) else nil
end

local function running(b: Block): { string }
	local ids = {}
	for _, pr in b.s.prs do
		if pr.checks.state == "pending" then table.insert(ids, pr.id) end
	end
	return ids
end

-- The reason alone from a "Couldn't …: reason" message; the board adds its own lead-in.
local function reasonOf(message: string): string
	return string.match(message, "^Couldn't [^:]*: (.*)$") or message
end

local onProbe: (b: Block, cx: BlockCx) -> ()
local onRefresh: (b: Block, cx: BlockCx) -> ()
local onChecks: (b: Block, cx: BlockCx) -> ()

-- Cancels the named timer's old handle, then arms a one-shot after `seconds` (nil leaves it off).
local function arm(b: Block, cx: BlockCx, name: "probe" | "refresh" | "checks" | "debounce", seconds: number?, fn: (Block, BlockCx) -> ())
	local timers = b.timers :: any
	local old: TimerHandle? = timers[name]
	if old then old:cancel() end
	timers[name] = nil
	if seconds == nil or b.closed then return end
	timers[name] = tern.timer(math.max(1, math.ceil(seconds * 1000)), function()
		timers[name] = nil
		if b.closed then return end
		fn(b, cx)
	end)
end

local function forgetReturned(b: Block, flight: AgentFlight): string
	local disposition
	if b.fixture then
		disposition = if flight.settled then "forget" else "wait"
	else
		local lease = if flight.engine then flight.engine.held() else nil
		disposition = State.agentFlight(b.s, flight.key, {
			settled = flight.settled, starting = flight.starting == true, releasing = flight.releasing,
			busy = flight.engine ~= nil and flight.engine.busy(), worktree = if lease then lease.path else nil,
		})
	end
	if disposition == "forget" and b.agentFlight == flight then b.agentFlight = nil end
	return disposition
end

-- Retry and close return through the same retained engine. A callback alone is not
-- proof of return: re-read held() before dropping the handle or allowing another run.
local function returnAgentLease(b: Block, flight: AgentFlight, done: (boolean?, string?) -> ())
	local engine = flight.engine
	if not engine or flight.releasing then return end
	flight.releasing = true
	local called = false
	local function returned(ok: boolean?, err: string?)
		if called then return end
		called = true
		flight.releasing = false
		local disposition = forgetReturned(b, flight)
		if disposition == "release" then ok, err = nil, err or "The worktree lease could not be returned" end
		done(ok, err)
	end
	local ok, err = pcall(engine.release, returned)
	if not ok then returned(nil, tostring(err)) end
end

local function closeAgentFlight(b: Block, flight: AgentFlight)
	local disposition = forgetReturned(b, flight)
	if disposition == "ready" then return end
	if not flight.settled then
		flight.stopping = true
		if flight.cancel then flight.cancel() end
		-- stop waits for any worker, then returns its lease.
		if flight.engine then flight.engine.stop() end
	elseif disposition == "release" then
		returnAgentLease(b, flight, function(ok, err)
			if not ok then
				local lease = (flight.engine :: AgentFix.Engine).held()
				State.agentFailed(b.s, flight.key, err or "The worktree lease could not be returned", if lease then lease.path else nil)
			end
		end)
	end
end

local function stop(b: Block)
	if b.closed then return end
	b.closed = true
	local flight = b.agentFlight
	State.closeAgent(b.s)
	if flight then closeAgentFlight(b, flight) end
	local timers = b.timers :: any
	for _, name in { "probe", "refresh", "checks", "debounce", "ring" } do
		local handle: TimerHandle? = timers[name]
		if handle then handle:cancel() end
		timers[name] = nil
	end
end

-- Renders; a render that raises means the block is gone.
local function draw(b: Block, cx: BlockCx)
	if b.closed then return end
	if not pcall(function() cx:render() end) then stop(b) end
end

-- Folder selection is the smallest host bridge available. No shell interpolation, and all
-- process effects use Fetch.runner. Cancel is an ordinary nil answer.
local function agentFolder(b: Block, flight: AgentFlight, prompt: string, done: (string?, string?) -> ())
	local replied = false
	local function finish(path: string?, err: string?)
		if replied then return end
		replied = true
		flight.cancel = nil
		done(path, err)
	end
	flight.cancel = function() finish(nil, nil) end
	local ok, err = pcall(Fetch.runner, {
		"osascript", "-e", "on run argv\ntry\nreturn POSIX path of (choose folder with prompt (item 1 of argv))\non error number -128\nreturn \"\"\nend try\nend run", prompt,
	}, { timeout_ms = 5 * 60_000 }, function(out)
		if b.closed or flight.stopping then return finish(nil, nil) end
		if out.status ~= 0 or out.timed_out then
			return finish(nil, if out.timed_out then "Folder selection timed out" else reasonOf(out.stderr))
		end
		local path = string.gsub(out.stdout, "[\r\n]+$", "")
		finish(if path == "" then nil else path, nil)
	end)
	if not ok then finish(nil, tostring(err)) end
end

local function currentFlight(b: Block, flight: AgentFlight): boolean
	return not b.closed and b.agentFlight == flight and not flight.settled and not flight.stopping
end

local function settleAgent(b: Block, cx: BlockCx, flight: AgentFlight, outcome: AgentFix.Outcome)
	if b.agentFlight ~= flight or flight.settled then return end
	if outcome.kind == "running" then
		if not b.closed and not flight.stopping then State.agentOutcome(b.s, flight.key, outcome); draw(b, cx) end
		return
	end
	flight.settled = true
	-- A ready callback is preserved even if closure was detected just before it arrived.
	if outcome.kind == "ready" then
		b.s.agents[flight.key] = { kind = "ready", fix = outcome.fix, reviewed = {} }
		State.project(b.s)
	elseif outcome.kind == "failed" and b.closed then
		State.agentFailed(b.s, flight.key, outcome.reason, outcome.worktree)
	elseif not b.closed then
		State.agentOutcome(b.s, flight.key, outcome)
	end
	forgetReturned(b, flight)
	if not b.closed then draw(b, cx) end
end

local function startAgentEngine(b: Block, cx: BlockCx, flight: AgentFlight, clone: string, checkout: string, pr: Model.HubPR)
	if not currentFlight(b, flight) then return end
	-- HubPR has baseBranch and headOid, but no head branch. Read and revalidate all three
	-- together; never guess a branch from a local checkout or pass a stale head to the engine.
	local replied = false
	local function metadata(out: Github.Out)
		if replied then return end
		replied = true
		if not currentFlight(b, flight) then return end
		local ok, meta = pcall(tern.json.decode, out.stdout)
		local latest = State.prOf(b.s, pr.key)
		if out.status ~= 0 or out.timed_out or not ok or type(meta) ~= "table" then
			settleAgent(b, cx, flight, { kind = "failed", reason = if out.timed_out then "Reading PR refs timed out" else reasonOf(out.stderr ~= "" and out.stderr or "No PR refs were returned") })
			return forgetReturned(b, flight)
		end
		if not latest or latest.headOid ~= pr.headOid or latest.baseBranch ~= pr.baseBranch or meta.headRefOid ~= pr.headOid or meta.baseRefName ~= pr.baseBranch
			or type(meta.headRefName) ~= "string" or meta.headRefName == "" then
			settleAgent(b, cx, flight, { kind = "failed", reason = "PR refs changed or are missing; refresh the board" })
			return forgetReturned(b, flight)
		end
		local doneCalled = false
		local function completed(fix: AgentFix.Fix?, err: string?)
			if doneCalled then return end
			doneCalled = true
			if err == "An agent fix already holds a worktree" and not flight.settled then
				settleAgent(b, cx, flight, { kind = "stopped" })
				if not b.closed then cx:toast("info", "One fix at a time") end
			end
			if not flight.settled then
				settleAgent(b, cx, flight, if fix then { kind = "ready", fix = fix }
					elseif err == "stopped" then { kind = "stopped" }
					else { kind = "failed", reason = err or "The agent returned no result" })
			end
			-- During a synchronous callback the handle is assigned just after this returns.
			if flight.engine then forgetReturned(b, flight) end
		end
		flight.starting = true
		local started, engine = pcall(Fetch.startAgentFix, {
			key = pr.key, clone = clone, checkout = checkout, branch = meta.headRefName,
			base = pr.baseBranch, headOid = pr.headOid, number = pr.number,
		}, b.agent :: Agent.Agent, b.s.now, function(outcome) settleAgent(b, cx, flight, outcome) end, completed)
		if started then flight.engine = engine else completed(nil, tostring(engine)) end
		flight.starting = false
		if not flight.engine then
			completed(nil, "The agent could not start")
			forgetReturned(b, flight)
		else
			-- Reconcile synchronous terminal callbacks once the handle is available.
			forgetReturned(b, flight)
			if b.closed or flight.stopping then closeAgentFlight(b, flight) end
		end
		if not b.closed then draw(b, cx) end
	end
	local ok, err = pcall(Fetch.runner, { "gh", "pr", "view", tostring(pr.number), "--repo", pr.repo, "--json", "headRefName,baseRefName,headRefOid" }, { timeout_ms = 30_000 }, metadata)
	if not ok then metadata({ status = -1, stdout = "", stderr = tostring(err), timed_out = false }) end
end

local function beginAgent(b: Block, cx: BlockCx, key: string, mode: "fix" | "clone" | "folder")
	if b.closed then return end
	local pr = State.prOf(b.s, if key ~= "" then key else b.s.selected or "")
	if not pr then return end
	if b.agentFlight then forgetReturned(b, b.agentFlight) end
	if b.agentFlight or State.agentRunning(b.s) then return cx:toast("info", "One fix at a time") end
	local existing = b.s.agents[pr.key]
	if existing and (existing.kind == "ready" or existing.kind == "pushing") then return end
	if not b.fixture and not b.agent then
		State.agentFailed(b.s, pr.key, "No agent is available", if existing and existing.kind == "failed" then existing.worktree else nil)
		return draw(b, cx)
	end
	if pr.baseBranch == "" or pr.headOid == "" or pr.number < 1 then
		State.agentFailed(b.s, pr.key, "PR refs are missing; refresh the board", if existing and existing.kind == "failed" then existing.worktree else nil)
		return draw(b, cx)
	end
	b.s.now = if b.fixture then b.s.now else os.time()
	if not State.beginAgent(b.s, pr.key, b.s.now) then return cx:toast("info", "One fix at a time") end
	local flight: AgentFlight = { key = pr.key, settled = false, stopping = false, releasing = false }
	b.agentFlight = flight
	draw(b, cx)
	if not currentFlight(b, flight) then return end
	if b.fixture then
		-- Even ordinary sample boards stay entirely local. ⌘R advances one recorded event.
		local data: any = FIXTURES["agent-cards"]()
		b.s.agents[pr.key] = { kind = "running", run = AgentFix.bind(AgentFix.start(pr.key, b.s.now), data.spec(pr.key)) }
		flight.fixtureStep = 0
		State.project(b.s)
		return draw(b, cx)
	end
	local dir = cx.cwd or tern.getenv("HOME") or ""
	local near: Fetch.Repo? = nil
	local checkout: string? = nil
	local cancelled, missing, answered = false, false, false
	local function cloned(path: string?, err: string?)
		if answered then return end
		answered = true
		if not currentFlight(b, flight) then return end
		if path then return startAgentEngine(b, cx, flight, path, checkout or path, pr) end
		flight.settled = true
		b.agentFlight = nil
		if cancelled or missing then State.noAgentClone(b.s, pr.key, pr.repo)
		else State.agentFailed(b.s, pr.key, err or "No clone was found", nil) end
		draw(b, cx)
	end
	local function find(allowClone: boolean)
		local ok, err = pcall(Fetch.findAgentClone, near, dir, pr.repo, function(slug, answer)
			if not currentFlight(b, flight) then return answer(nil) end
			if not allowClone then missing = true; return answer(nil) end
			agentFolder(b, flight, "Choose a parent folder for " .. slug, function(parent, why)
				if not currentFlight(b, flight) then return answer(nil) end
				if why then cloned(nil, why); return answer(nil) end
				if not parent then cancelled = true; return answer(nil) end
				local name = string.match(slug, "[^/]+$") :: string
				answer(string.gsub(parent, "/+$", "") .. "/" .. name)
			end)
		end, cloned)
		if not ok then cloned(nil, tostring(err)) end
	end
	local function choose()
		if mode ~= "folder" then return find(mode == "clone") end
		agentFolder(b, flight, "Choose the existing clone of " .. pr.repo, function(path, err)
			if not currentFlight(b, flight) then return end
			if err then return cloned(nil, err) end
			if not path then cancelled = true; return cloned(nil, nil) end
			local checked = false
			local function selected(repo: Fetch.Repo?, why: string?)
				if checked then return end
				checked = true
				if not currentFlight(b, flight) then return end
				if not repo then return cloned(nil, why or "The selected folder is not a clone") end
				local ok, problem = pcall(Fetch.rememberAgentClone, pr.repo, repo.root)
				if not ok or problem then return cloned(nil, tostring(problem)) end
				near = repo
				find(false)
			end
			local ok, why = pcall(Fetch.findRepo, path, selected)
			if not ok then selected(nil, tostring(why)) end
		end)
	end
	-- Resolve the reader's root even when cwd is a subfolder. Both it and the source clone
	-- are protected by #15's physical-path check at worktree acquisition.
	local checked = false
	local function found(repo: Fetch.Repo?)
		if checked then return end
		checked = true
		if not currentFlight(b, flight) then return end
		near, checkout = repo, if repo then repo.root else nil
		choose()
	end
	local ok, err = pcall(Fetch.findRepo, dir, found)
	if not ok then cloned(nil, tostring(err)) end
end

local function advanceAgentFixture(b: Block, cx: BlockCx): boolean
	local flight = b.agentFlight
	if not flight or flight.fixtureStep == nil or flight.settled then return false end
	local data: any = FIXTURES["agent-cards"]()
	flight.fixtureStep += 1
	local event = data.events()[flight.fixtureStep]
	local current = b.s.agents[flight.key]
	if event and current and current.kind == "running" then
		settleAgent(b, cx, flight, AgentFix.step(current.run, event))
	end
	if flight.settled then b.agentFlight = nil end
	return true
end

-- How long an arrival's ring or wash is held before it fades, and how long the fade takes (--gp-dur-rare, plus a
-- little slack so the class outlives the transition).
local RING_HOLD_MS, RING_FADE_MS = 1400, 360

-- Alerts for one refresh: `fresh` against `old` (nil on a first load, which shows nothing). Sets the rings
-- and washes the next projection paints, shows the one toast, and starts the timers that fade and then end
-- the ring. The viewer's own actions (`s.acted`) are skipped and then forgotten. Call before `State.replace`.
local function announce(b: Block, cx: BlockCx, old: Sync.Cache?, fresh: { Model.HubPR }, now: number)
	local s = b.s
	local alerts = Sync.alerts(Sync.diff(old, fresh, now, s.acted))
	s.acted = {}
	if alerts.toast then cx:toast("error", alerts.toast.text, alerts.toast.sub) end
	if #alerts.rings + #alerts.good == 0 then return end
	s.ringed = {}
	for _, key in alerts.rings do s.ringed[key] = "bad" end
	for _, key in alerts.good do s.ringed[key] = "good" end
	-- A background refresh is not a key press: the arrival may animate.
	s.keyed = false
	local timers = b.timers :: any
	local running: TimerHandle? = timers.ring
	if running then running:cancel() end
	local function after(ms: number, fn: () -> ())
		timers.ring = tern.timer(ms, function()
			timers.ring = nil
			if b.closed then return end
			fn()
			State.project(b.s)
			draw(b, cx)
		end)
	end
	after(RING_HOLD_MS, function()
		for key, kind in b.s.ringed do b.s.ringed[key] = (kind .. "-out") :: any end
		after(RING_FADE_MS, function() b.s.ringed = {} end)
	end)
end

-- Takes another window's newer cache, so windows share one refresh.
local function adoptShared(b: Block, cx: BlockCx)
	local shared = readCache()
	if not shared then return end
	local theirs, mine = Model.epoch(shared.refreshedAt), cachedAt(b)
	if theirs and (mine == nil or theirs > mine) then
		local now = os.time()
		announce(b, cx, b.cache, shared.prs, now)
		b.cache = shared
		State.replace(b.s, shared.prs, now, shared.refreshedAt)
	end
end

-- Arms the probe, refresh (as the debounce while a change or focus waits) and checks timers from the schedule.
local function rearm(b: Block, cx: BlockCx)
	if b.fixture or b.closed then return end
	adoptShared(b, cx)
	local sched = b.sched
	local last, tried = cachedAt(b), sched.refreshTried
	local plan = Sync.schedule({
		now = os.time(), refreshedAt = if last and tried then math.max(last, tried) else (last or tried),
		refreshing = b.flights.refresh, probedAt = sched.probedAt, probeChanged = sched.probeChanged,
		focusedAt = sched.focusedAt, checksAt = sched.checksAt, running = running(b),
	})
	local early = sched.probeChanged or sched.focusedAt ~= nil
	arm(b, cx, "probe", plan.probe, onProbe)
	arm(b, cx, "refresh", if early then nil else plan.refresh, onRefresh)
	arm(b, cx, "debounce", if early then plan.refresh else nil, onRefresh)
	arm(b, cx, "checks", plan.checks, onChecks)
end

onProbe = function(b, cx)
	if b.flights.probe then return end
	b.flights.probe = true
	b.github.probe(b.sched.lastModified, function(value, err)
		b.flights.probe = false
		if b.closed then return end
		b.sched.probedAt = os.time()
		-- A failed probe is "no change", never an error on screen and never a retry before the next minute: the
		-- viewer's gh token often lacks the `notifications` scope, so /notifications answers 404, and the
		-- five-minute refresh still runs. The first answer only sets the validator.
		if value then
			if value.changed and b.sched.lastModified ~= nil then b.sched.probeChanged = true end
			if value.lastModified then b.sched.lastModified = value.lastModified end
		end
		rearm(b, cx)
		draw(b, cx)
	end)
end

local startRefresh: (b: Block, cx: BlockCx) -> ()

-- Writes hub.added. Returns why it failed.
local function writeAdded(added: Sync.Added): string?
	local ok, err = pcall(tern.kv.set, KV_ADDED, added)
	return if ok then nil else tostring(err)
end

-- After a refresh: a pull request just added by link is selected and brought into view, or, when GitHub
-- didn't return it, forgotten with the reason.
local function showAdded(b: Block, cx: BlockCx)
	local ref = b.show
	if not ref then return end
	b.show = nil
	local pr = State.find(b.s, ref.repo, ref.number)
	if pr and State.show(b.s, pr.key) then
		revealSelected(b, cx)
		return
	end
	local added = readLocal().added
	for key, entry in added do
		if entry.number == ref.number and string.lower(entry.repo) == string.lower(ref.repo) then added[key] = nil end
	end
	writeAdded(added)
	cx:toast("error", "Couldn't add #" .. ref.number .. ": GitHub has no pull request " .. ref.repo .. "#" .. ref.number)
end

-- Merge methods: hub.merge.<owner>/<repo> -----------------------------------------------------------------

local KV_MERGE = "hub.merge."

local function isoNow(): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()) :: string
end

-- The repo's saved record, read from kv once. A fixture board keeps its records in memory only.
local function readRecord(b: Block, repo: string): Sync.MergeRecord?
	local known = b.records[repo]
	if known or b.fixture then return known end
	local record = Sync.loadMerge(kvGet(KV_MERGE .. repo))
	b.records[repo] = record
	return record
end

-- Resolves the repo's method from its record (user, declared, learned, GitHub default) into the state.
local function resolveRepo(b: Block, repo: string)
	local record = readRecord(b, repo)
	if not record then return end
	local default: "squash" | "merge" | "rebase" = "squash"
	if record.viewerDefault == "merge" or record.viewerDefault == "rebase" then default = record.viewerDefault end
	State.setMerge(b.s, repo, Model.resolveMergeMethod(Sync.mergeEvidence(record, default)))
end

-- Saves the record (a fixture board keeps it in memory) and resolves the repo again. Returns why it failed.
local function saveRecord(b: Block, repo: string, record: Sync.MergeRecord): string?
	b.records[repo] = record
	local why: string? = nil
	if not b.fixture then
		local ok, err = pcall(tern.kv.set, KV_MERGE .. repo, record)
		if not ok then why = tostring(err) end
	end
	resolveRepo(b, repo)
	return why
end

local function recordOf(b: Block, repo: string): Sync.MergeRecord
	return readRecord(b, repo) or { schema = 1, learnedAnswered = false }
end

-- Resolves every repo with a saved record, so the cards know how their repo merges.
local function loadMerges(b: Block)
	local seen: { [string]: boolean } = {}
	for _, pr in b.s.prs do
		if pr.role == "mine" and not seen[pr.repo] then
			seen[pr.repo] = true
			resolveRepo(b, pr.repo)
		end
	end
end

-- Asks GitHub how a repo merges, once per repo: what it declares and the habit of its last 8 merges (1 point).
-- The same answer carries the repo's "Allow auto-merge" setting, which Merge when ready needs: with `needAuto`, a repo
-- whose record is saved is asked once per session for that alone.
local function detectRepo(b: Block, cx: BlockCx, repo: string, needAuto: boolean?)
	if b.fixture or b.closed or b.detecting[repo] then return end
	local known = readRecord(b, repo)
	if known and not (needAuto and b.s.autoMerge[repo] == nil) then return end
	b.detecting[repo] = true
	b.github.detect(repo, function(found, err)
		if b.closed then return end
		if found then
			State.setAutoMerge(b.s, repo, found.autoMergeAllowed)
			if not known then
				local record = recordOf(b, repo)
				record.declared, record.learned, record.viewerDefault, record.checkedAt = found.declared, found.learned, found.viewerDefault, isoNow()
				local why = saveRecord(b, repo, record)
				if why then cx:toast("error", "Couldn't save how " .. repo .. " merges: " .. why) end
			end
		else
			b.detecting[repo] = nil
			cx:toast("error", "Couldn't check how " .. repo .. " merges: " .. reasonOf(if err then err.message else "no answer"))
		end
		draw(b, cx)
	end)
end

-- After a refresh: every repo with a Ready card that has no record yet is checked.
local function detectMerges(b: Block, cx: BlockCx)
	if b.fixture then return end
	for _, entry in b.s.board.columns do
		if entry.column == "ready" then
			for _, card in entry.cards do detectRepo(b, cx, card.pr.repo) end
		elseif entry.column == "in_review" then
			for _, card in entry.cards do detectRepo(b, cx, card.pr.repo, true) end
		end
	end
end

-- Flake evidence ----------------------------------------------------------------------------------------------
-- For each Needs fixes card with a failing check, the block reads what the verdict needs: the details (annotations,
-- changed files, run ids), the base branch's recent runs (once an hour per repo) and the runs of the head commit.
-- Nothing here re-runs anything: that is a press on Re-run failed checks.
local FLAKE_PRS = 10 -- the most cards read in one pass

local function flakeOf(pr: Model.HubPR, d: Fixes.FixDetails, history: Github.RepoHistory?, runs: { Github.RunRow }?): State.Flake
	local verdicts: { Model.FlakeVerdict } = {}
	local ids: { number } = {}
	for _, check in d.checks do
		if check.runId then
			table.insert(verdicts, Model.flake(Github.evidenceFor(check, d.changedPaths, history, runs)))
			if table.find(ids, check.runId) == nil then table.insert(ids, check.runId) end
		end
	end
	local verdict = Model.flakeAll(verdicts)
	return { flaky = verdict.flaky and #ids > 0, reason = verdict.reason, runs = ids, headOid = d.headOid }
end

local function loadFlakes(b: Block, cx: BlockCx)
	if b.fixture or b.closed or b.flights.flake then return end
	local queue: { Model.HubPR } = {}
	for _, entry in b.s.board.columns do
		if entry.column == "needs_fixes" then
			for _, card in entry.cards do
				local pr = card.pr
				local wants = table.find(card.reasons, "checks") ~= nil and pr.checks.failing > 0
				if wants and not b.flakeTried[pr.key .. "@" .. pr.headOid] and State.flakeOf(b.s, pr.key) == nil and #queue < FLAKE_PRS then
					table.insert(queue, pr)
				end
			end
		end
	end
	if #queue == 0 then return end
	b.flights.flake = true
	local function step(i: number)
		local pr = queue[i]
		if pr == nil or b.closed then
			b.flights.flake = false
			return
		end
		b.flakeTried[pr.key .. "@" .. pr.headOid] = true
		b.github.details(pr, function(d, _)
			if b.closed then return end
			if d == nil then return step(i + 1) end
			b.histories.read(pr.repo, pr.baseBranch, os.time(), function(history)
				b.github.runs(pr.repo, d.headOid, function(runs, _)
					if b.closed then return end
					State.setFlake(b.s, pr.key, flakeOf(pr, d, history, runs))
					draw(b, cx)
					step(i + 1)
				end)
			end)
		end)
	end
	step(1)
end

startRefresh = function(b: Block, cx: BlockCx)
	b.flights.refresh = true
	b.s.loading = true
	local refs: { Model.PRRef } = {}
	for _, ref in readLocal().added do table.insert(refs, ref) end
	b.github.refresh({ added = refs, previous = b.s.prs }, function(fresh, err)
		b.flights.refresh = false
		if b.closed then return end
		local now = os.time()
		b.sched.refreshTried = now
		if not fresh then
			b.s.loading = false
			b.s.error = { operation = if err then err.operation else "hub", message = reasonOf(if err then err.message else "no answer"), rateLimit = if err then err.rateLimit else nil }
		else
			local canon, moved = State.canonicalAdded(readLocal().added, fresh.prs)
			if moved then writeAdded(canon) end
			local cache = Sync.merge(fresh, b.cache, readLocal(), now)
			cache.lastModified = b.sched.lastModified
			announce(b, cx, b.cache, cache.prs, now)
			b.cache = cache
			b.sched.probeChanged, b.sched.focusedAt = false, nil
			State.replace(b.s, cache.prs, now, cache.refreshedAt)
			local why = persist(b)
			if why then b.s.error = { operation = KV_CACHE, message = "the cache couldn't be saved: " .. why } end
			showAdded(b, cx)
			loadMerges(b)
			detectMerges(b, cx)
			loadFlakes(b, cx)
		end
		if b.refetch then
			b.refetch = false
			return startRefresh(b, cx)
		end
		rearm(b, cx)
		draw(b, cx)
	end)
	draw(b, cx)
end

onRefresh = function(b, cx)
	if b.flights.refresh then return end
	adoptShared(b, cx)
	-- Another window refreshed a moment ago: its cache is the answer.
	local last = cachedAt(b)
	if last and os.time() - last < Sync.DEBOUNCE then
		rearm(b, cx)
		draw(b, cx)
		return
	end
	startRefresh(b, cx)
end

onChecks = function(b, cx)
	if b.flights.checks then return end
	local ids = running(b)
	if #ids == 0 then return rearm(b, cx) end
	b.flights.checks = true
	b.github.checks(ids, function(update, err)
		b.flights.checks = false
		if b.closed then return end
		b.sched.checksAt = os.time()
		if update then
			local changed = false
			for _, pr in b.s.prs do
				local result = update.byId[pr.id]
				-- A moved head means the next full refresh knows better.
				if result and result.headOid == pr.headOid then
					pr.checks = result.checks
					changed = true
				end
			end
			if changed then
				b.s.now = os.time()
				State.project(b.s)
				local why = persist(b)
				if why then b.s.error = { operation = KV_CACHE, message = "the cache couldn't be saved: " .. why } end
				loadFlakes(b, cx)
			end
		end
		rearm(b, cx)
		draw(b, cx)
	end)
end

local ACTIONS: { [string]: Handler } = {}

-- The window sends this when the hub's pane gains focus; the schedule applies the debounce.
ACTIONS["hub-focused"] = function(b, cx)
	if b.fixture then return end
	State.setRecent(b.s, Fetch.recentPrs())
	b.sched.focusedAt = os.time()
	rearm(b, cx)
end

-- The window sends this when ⌥⇧⌘R (true) or ⌥⌘R (false) finds the hub already open.
ACTIONS["set-generate"] = function(b, cx, value)
	b.generate = value == "true"
end

ACTIONS["hub-select"] = function(b, cx, key)
	State.select(b.s, key)
end
ACTIONS["hub-open"] = openCard
ACTIONS["hub-open-generate"] = function(b, cx, value)
	openRow(b, cx, value, true)
end
ACTIONS["open"] = openCard
ACTIONS["hub-move"] = function(b, cx, direction)
	if State.move(b.s, direction :: any) then revealSelected(b, cx) end
end
ACTIONS["hub-tab"] = function(b, cx, id)
	if id == "mine" then
		State.setTab(b.s, "mine")
	elseif id == "review" then
		State.setTab(b.s, "review")
	else
		State.switchTab(b.s)
	end
end
ACTIONS["hub-next"] = function(b, cx)
	if State.walk(b.s) then revealSelected(b, cx) end
end
ACTIONS["hub-fold"] = function(b, cx, name)
	State.toggleFold(b.s, name)
end
ACTIONS["hub-escape"] = function(b, cx)
	local s = b.s
	if State.clearMarks(s) then return end
	if s.search.text ~= "" then
		State.setSearch(s, "")
	else
		State.select(s, nil)
	end
end

-- search
ACTIONS["hub-search"] = function(b, cx)
	State.openSearch(b.s)
	frameLater(cx, { { "focus", Paths.searchField } })
end
ACTIONS["hub-searched"] = function(b)
	State.searched(b.s)
end
ACTIONS["hub-search-done"] = function(b)
	State.closeSearch(b.s, false)
end
ACTIONS["hub-search-clear"] = function(b)
	State.closeSearch(b.s, true)
end

-- menus and the key panel
ACTIONS["hub-menu"] = function(b, cx, id)
	local s = b.s
	if s.menu == id then return closeMenu(b) end
	State.openMenu(s, id :: State.MenuId)
end
ACTIONS["hub-actions"] = function(b, cx, key)
	local s = b.s
	State.select(s, key)
	if s.menu == "actions" or s.menu == "merge" then return closeMenu(b) end
	-- A Ready card's only alternative is the merge method, so its ▾ opens the chooser itself.
	local card = State.card(s, key)
	if card and #card.more == 1 and card.more[1].act == "card-method" then return State.openMenu(s, "merge") end
	State.openMenu(s, "actions")
end
ACTIONS["hub-menu-move"] = function(b, cx, delta)
	State.menuMove(b.s, tonumber(delta) or 0)
end
ACTIONS["hub-menu-close"] = function(b)
	closeMenu(b)
end
ACTIONS["hub-menu-pick"] = function(b, cx, index)
	pickRow(b, cx, tonumber(index) or 0, ACTIONS)
end
-- Space chooses the highlighted row (a repository toggles and the menu stays open).
ACTIONS["hub-menu-select"] = function(b, cx)
	pickRow(b, cx, b.s.menuCursor, ACTIONS)
end
-- ⏎ chooses it too, except in the repository list, where it closes the menu on the choices made.
ACTIONS["hub-menu-enter"] = function(b, cx)
	local s = b.s
	local row = State.menuRows(s)[s.menuCursor]
	if s.menu == "repositories" and not (row and row.kind == "clear") then return closeMenu(b) end
	pickRow(b, cx, s.menuCursor, ACTIONS)
end
ACTIONS["hub-menu-effort"] = function(b, cx, delta)
	State.stepEffort(b.s, tonumber(delta) or 0)
	keepAgentChoice(b)
end
ACTIONS["hub-menu-effort-set"] = function(b, cx, level)
	State.setEffort(b.s, level)
	keepAgentChoice(b)
end
ACTIONS["hub-help"] = function(b)
	State.openHelp(b.s)
end
ACTIONS["hub-help-close"] = function(b)
	State.closeHelp(b.s)
end

-- Card actions: shown with their labels and keys; their effects arrive with the changes that build them.
ACTIONS["card-agent"] = function(b, cx, key) beginAgent(b, cx, key, "fix") end
ACTIONS["card-agent-clone"] = function(b, cx, key) beginAgent(b, cx, key, "clone") end
ACTIONS["card-agent-folder"] = function(b, cx, key) beginAgent(b, cx, key, "folder") end
ACTIONS["card-agent-stop"] = function(b, cx, key)
	local flight = b.agentFlight
	local agent = b.s.agents[key]
	if not agent or agent.kind ~= "running" then return end
	if flight and flight.key == key then
		if flight.stopping then return end
		flight.stopping = true
		if flight.cancel then flight.cancel() end
		if flight.engine then return flight.engine.stop() end
		if flight.starting then return end
		flight.settled = true
		b.agentFlight = nil
	end
	State.agentOutcome(b.s, key, { kind = "stopped" })
	draw(b, cx)
end
ACTIONS["card-agent-retry"] = function(b, cx, key)
	local agent, flight = b.s.agents[key], b.agentFlight
	if not agent or agent.kind ~= "failed" then return end
	-- A failed lease return retains the handle. Retry first retries that exact guarded
	-- return, and starts no engine until it succeeds. Never release a ready worktree.
	if flight and flight.key == key then
		local disposition = forgetReturned(b, flight)
		if disposition == "wait" then return cx:toast("info", "One fix at a time") end
		if disposition ~= "release" then return beginAgent(b, cx, key, "fix") end
		returnAgentLease(b, flight, function(ok, err)
			if not ok then
				local lease = (flight.engine :: AgentFix.Engine).held()
				State.agentFailed(b.s, key, err or "The worktree lease could not be returned", if lease then lease.path else nil)
				return draw(b, cx)
			end
			if b.closed then return end
			beginAgent(b, cx, key, "fix")
		end)
		return
	end
	beginAgent(b, cx, key, "fix")
end
ACTIONS["card-agent-worktree"] = function(b, cx, key)
	local agent = b.s.agents[key]
	if not agent or agent.kind ~= "failed" or not agent.worktree then return end
	if b.fixture then return cx:toast("info", "Sample worktree", agent.worktree) end
	-- Finder is the available folder-opening surface; the path stays a single argv.
	local replied = false
	local function opened(out: Github.Out)
		if replied then return end
		replied = true
		if b.closed then return end
		if out.status ~= 0 or out.timed_out then cx:toast("error", "Couldn't open worktree: " .. reasonOf(out.stderr ~= "" and out.stderr or "Opening the folder failed")) end
	end
	local ok, err = pcall(Fetch.runner, { "open", agent.worktree }, { timeout_ms = 15_000 }, opened)
	if not ok then opened({ status = -1, stdout = "", stderr = tostring(err), timed_out = false }) end
end
ACTIONS["card-handoff"] = notYet("Hand off to Tandem")
ACTIONS["card-summarize"] = notYet("Summarize")
ACTIONS["card-method"] = function(b, cx, key)
	if not State.card(b.s, key) then return end
	State.select(b.s, key)
	State.openMenu(b.s, "merge")
end

-- A refresh now: after an add, a remove, a merge or a branch update. One running already runs again when it ends.
local function refetch(b: Block, cx: BlockCx)
	if b.fixture or b.closed then return end
	if b.flights.refresh then
		b.refetch = true
	else
		startRefresh(b, cx)
	end
end

-- A refresh a few seconds on, for changes GitHub's search takes a moment to show (a merge, a branch update).
local function refetchSoon(b: Block, cx: BlockCx)
	tern.timer(3000, function()
		if not b.closed then refetch(b, cx) end
	end)
end

-- The sample board's ⌘R: applies the next `refreshes` entry (after the last, the first again) through the same
-- announce path as a live refresh. The entry's earlier board shows first, so the arrival is seen. It never
-- touches kv or `b.cache`: the sample board must not change what the real status segment shows.
local SETTLE_MS = 450

local function fixtureRefresh(prs: { Model.HubPR }): Model.Refresh
	return { prs = prs, viewer = "", rateLimit = nil, calls = {}, truncated = false, partial = nil } :: any
end

local function stepFixture(b: Block, cx: BlockCx)
	if b.flights.refresh then return end
	local data = FIXTURES[b.fixture :: string]()
	local list = data.refreshes
	if not list or #list == 0 then return end
	b.step = b.step % #list + 1
	local entry = list[b.step]
	local none: Sync.Local = { added = {}, tandem = {} }
	local before: Sync.Cache? = nil
	if entry.previous then
		local built = Sync.merge(fixtureRefresh(entry.previous), nil, none, data.asOf)
		built.prs = entry.previous
		before = built
	end
	local function apply()
		b.flights.refresh = false
		if b.closed then return end
		local acted: { [string]: boolean } = {}
		for key in entry.suppressed do acted[key] = true end
		b.s.acted = acted
		announce(b, cx, before, entry.prs, data.asOf)
		State.replace(b.s, entry.prs, data.asOf, data.asOfIso)
		draw(b, cx)
	end
	local timers = b.timers :: any
	local running: TimerHandle? = timers.ring
	if running then running:cancel() end
	timers.ring = nil
	b.s.ringed = {}
	if not before then return apply() end
	b.flights.refresh = true
	State.replace(b.s, entry.previous, data.asOf, data.asOfIso)
	draw(b, cx)
	tern.timer(SETTLE_MS, apply)
end

-- ⌘R: refresh now. The sample board steps through its `refreshes` instead of asking GitHub.
ACTIONS["hub-refresh"] = function(b, cx)
	if b.fixture and advanceAgentFixture(b, cx) then return end
	if b.fixture == "agent-cards" then return end
	if b.fixture then return stepFixture(b, cx) end
	refetch(b, cx)
end

-- Keeps the cache in step with a change the viewer just made to the board.
local function keepCache(b: Block)
	if b.cache then
		b.cache.prs = b.s.prs
		persist(b)
	end
end

-- Copy link (C): "title url" as plain text, which is all Tern's clipboard takes.
ACTIONS["card-copy"] = function(b, cx, key)
	local card = State.card(b.s, key)
	if not card then return end
	State.select(b.s, key)
	cx:copy(card.pr.title .. " " .. card.pr.url)
	cx:toast("success", "Copied link")
end

-- Merging --------------------------------------------------------------------------------------------------

local MERGE_BUSY = { comment = "Commenting…", label = "Adding label…", queue = "Queuing…" }

-- The repo's resolved method, squash until its record is known.
local function methodOf(b: Block, pr: Model.HubPR): Model.MergeMethod
	local resolved = b.s.merges[pr.repo]
	return if resolved then resolved.method else { kind = "squash" }
end

local function toastDone(cx: BlockCx, pr: Model.HubPR, method: Model.MergeMethod)
	if method.kind == "comment" then
		cx:toast("success", "Commented " .. method.command .. " on #" .. pr.number, pr.title)
	elseif method.kind == "label" then
		cx:toast("success", "Added the " .. method.label .. " label to #" .. pr.number, pr.title)
	elseif method.kind == "queue" then
		cx:toast("success", "Added #" .. pr.number .. " to the merge queue", pr.title)
	else
		cx:toast("success", "Merged #" .. pr.number, pr.title)
	end
end

-- Merges with the repo's method. GitHub's merge happens now and the PR leaves the board; a queue, comment or
-- label hands the merge to the repo's tool, so the card shows it pending until a refresh brings the result.
-- With `done`, the caller owns the toast and the refresh (a batch): it hears nil when the PR merged or was handed to
-- its repo's tool, or the reason it didn't.
local function runMerge(b: Block, cx: BlockCx, pr: Model.HubPR, done: ((err: string?) -> ())?)
	local s = b.s
	local method = methodOf(b, pr)
	State.setBusy(s, pr.key, MERGE_BUSY[method.kind] or "Merging…")
	b.github.run(Github.commands.merge(pr, method), function(_, err)
		if b.closed then return end
		if err then
			State.setBusy(s, pr.key, nil)
			if done then
				done(reasonOf(err.message))
			else
				cx:toast("error", "Couldn't merge #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
			end
		elseif method.kind == "squash" or method.kind == "merge" or method.kind == "rebase" then
			s.acted[pr.key] = true
			State.dropPr(s, pr.key)
			keepCache(b)
			if done then done(nil) else
				toastDone(cx, pr, method)
				refetchSoon(b, cx)
			end
		else
			State.setPending(s, pr.key, { method = method.kind, at = isoNow() })
			State.setBusy(s, pr.key, nil)
			keepCache(b)
			if done then done(nil) else
				toastDone(cx, pr, method)
				refetchSoon(b, cx)
			end
		end
		draw(b, cx)
	end)
end

-- Merge (M): a GitHub method asks first (⌘⏎ merges, Esc cancels); a comment, label or queue runs at once, since
-- it can be cancelled; a comment learned from the repo's history asks once.
ACTIONS["card-merge"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] then return end
	local pr = card.pr
	if not b.fixture and not s.merges[pr.repo] then
		-- Not known yet how this repo merges: GitHub's merge is never the guess.
		State.select(s, key)
		detectRepo(b, cx, pr.repo)
		return cx:toast("info", "Checking how " .. pr.repo .. " merges…", "Try again in a moment")
	end
	if State.mergeStep(s, pr) == "run" then
		State.select(s, key)
		if b.fixture then return cx:toast("info", "The sample board doesn't merge", pr.key) end
		return runMerge(b, cx, pr, nil)
	end
	State.askMerge(s, key)
end

-- Cancel merge (M on a card with a merge in flight): the method's own cancel.
ACTIONS["card-cancel"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	local pending = if card then card.pr.pending else nil
	if not card or not pending or s.busy[key] then return end
	local pr = card.pr
	if b.fixture then return cx:toast("info", "The sample board doesn't cancel merges", pr.key) end
	local method = methodOf(b, pr)
	if pending.method == "queue" then method = { kind = "queue" } end
	local ok, command = pcall(Github.commands.cancelMerge, pr, method)
	if not ok or method.kind ~= pending.method then
		return cx:toast("error", "Couldn't cancel the merge of #" .. pr.number .. ": " .. pr.repo .. " has no way to cancel it", pr.title)
	end
	State.setBusy(s, key, "Cancelling…")
	b.github.run(command :: Github.Command, function(_, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if err then
			cx:toast("error", "Couldn't cancel the merge of #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
		else
			State.setPending(s, key, nil)
			keepCache(b)
			if method.kind == "comment" then
				cx:toast("success", "Commented " .. (method.cancel or "") .. " on #" .. pr.number, pr.title)
			elseif method.kind == "label" then
				cx:toast("success", "Removed the " .. method.label .. " label from #" .. pr.number, pr.title)
			elseif card.column == "in_review" then
				cx:toast("success", "#" .. pr.number .. " won't merge when ready", pr.title)
			else
				cx:toast("success", "Removed #" .. pr.number .. " from the merge queue", pr.title)
			end
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- Merge when ready (M behind the ▾ on an In review card): GitHub's `--auto` with the repo's method flag, or the
-- repo's own command posted early. It can be cancelled, so it asks nothing. The card then reads "Merges when ready".
ACTIONS["card-auto"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] or card.pr.pending then return end
	local pr = card.pr
	State.select(s, key)
	if b.fixture then return cx:toast("info", "The sample board doesn't merge", pr.key) end
	if not Model.canMergeWhenReady(s.merges[pr.repo], s.autoMerge[pr.repo]) then
		return cx:toast("error", "Couldn't set #" .. pr.number .. " to merge when ready: " .. pr.repo .. " doesn't allow auto-merge", pr.title)
	end
	local method = methodOf(b, pr)
	State.setBusy(s, key, MERGE_BUSY[method.kind] or "Setting…")
	b.github.run(Github.commands.autoMerge(pr, method), function(_, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if err then
			cx:toast("error", "Couldn't set #" .. pr.number .. " to merge when ready: " .. reasonOf(err.message), pr.repo)
		else
			local kind = if method.kind == "comment" or method.kind == "label" then method.kind else "queue"
			State.setPending(s, key, { method = kind, at = isoNow() })
			keepCache(b)
			cx:toast("success", "#" .. pr.number .. " will merge when ready", pr.title)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- Re-request review (Q on a card that waits on a re-review): asks the reviewers whose changes the push answers.
ACTIONS["card-rerequest"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] then return end
	local pr = card.pr
	local again = Model.awaitingReReview(pr)
	if not again or #again.ask == 0 then return end
	State.select(s, key)
	if b.fixture then return cx:toast("info", "The sample board doesn't ask for reviews", pr.key) end
	local logins = again.ask
	State.setBusy(s, key, "Requesting…")
	b.github.run(Github.commands.requestReview(pr, table.concat(logins, ",")), function(_, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if err then
			cx:toast("error", "Couldn't re-request review on #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
		else
			State.reRequested(s, key, logins)
			keepCache(b)
			cx:toast("success", "Asked " .. Model.reviewerList(logins) .. " to review #" .. pr.number .. " again", pr.title)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- A comment, label or queue method chosen or saved in the merge menu becomes the repo's setting.
local function setUserMethod(b: Block, cx: BlockCx, repo: string, method: Model.MergeMethod)
	local record = recordOf(b, repo)
	record.user = method
	local why = saveRecord(b, repo, record)
	if why then cx:toast("error", "Couldn't save how " .. repo .. " merges: " .. why) end
end

chooseMergeRow = function(b, cx, index)
	local s = b.s
	local kind = s.menu == "merge" and State.MERGE_KINDS[index] or nil
	local repo = State.mergeRepo(s)
	if not kind or not repo then return end
	if kind.id == "comment" or kind.id == "label" then
		s.menuCursor = index
		return State.beginMethodEdit(s, kind.id)
	end
	setUserMethod(b, cx, repo, { kind = kind.id } :: any)
	State.closeMenu(s)
end

ACTIONS["hub-method-save"] = function(b, cx)
	local s = b.s
	local edit = s.methodEdit
	local method = State.methodOfEdit(s)
	if not edit or not method then return end
	setUserMethod(b, cx, edit.repo, method)
	State.closeMenu(s)
end
ACTIONS["hub-method-cancel"] = function(b)
	State.cancelMethodEdit(b.s)
end

-- Select several -------------------------------------------------------------------------------------------

-- Space on the selected card, or a ⌘/⇧-click on `value`: selects it for Merge selected or Close stale.
ACTIONS["hub-mark"] = function(b, cx, value)
	local s = b.s
	local key = if value ~= "" then value else s.selected
	if not key then return end
	local ok, why = State.toggleMark(s, key)
	if ok then return end
	local card = State.card(s, key)
	if card then cx:toast("info", "Can't select #" .. card.pr.number .. ": " .. (why or "it isn't selectable"), card.pr.title) end
end

-- ⇧X and the Inactive fold's Close stale: selects every stale pull request that isn't a draft.
ACTIONS["hub-mark-stale"] = function(b, cx)
	if State.markStale(b.s) == 0 then cx:toast("info", "No stale pull requests to close", "Drafts are selected one by one with Space") end
end

ACTIONS["hub-marks-clear"] = function(b)
	State.clearMarks(b.s)
end

-- A repo whose merge method isn't known yet is looked up first: GitHub's merge is never the guess.
ACTIONS["hub-batch-merge"] = function(b, cx)
	local s = b.s
	if s.mode ~= "board" or State.selection(s) == nil then return end
	if not b.fixture then
		local waiting = false
		for _, card in State.markedCards(s) do
			if not s.merges[card.pr.repo] then
				waiting = true
				detectRepo(b, cx, card.pr.repo)
			end
		end
		if waiting then return cx:toast("info", "Checking how these repositories merge…", "Try again in a moment") end
	end
	State.askBatch(s, "ready")
end
ACTIONS["hub-batch-close"] = function(b)
	local s = b.s
	if s.mode == "board" then State.askBatch(s, "inactive") end
end

local function refList(prs: { Model.HubPR }): string
	local out: { string } = {}
	for _, pr in prs do table.insert(out, "#" .. pr.number) end
	return table.concat(out, ", ")
end

-- Runs the confirmed selection one pull request at a time, in column order. A failure stops the rest, which stay
-- selected; one toast names what went through and what didn't.
local function runBatch(b: Block, cx: BlockCx, keys: { string }, merge: boolean)
	local s = b.s
	if b.fixture then return cx:toast("info", if merge then "The sample board doesn't merge" else "The sample board doesn't close pull requests") end
	local queue: { Model.HubPR } = {}
	for _, key in keys do
		local card = State.card(s, key)
		if card and not s.busy[key] then table.insert(queue, card.pr) end
	end
	if #queue == 0 then return end
	local finished: { Model.HubPR } = {}
	local handed = false -- some went to a repo's tool (comment, label, queue) rather than merging at once
	local step: (index: number) -> ()
	local function finish(failed: Model.HubPR?, reason: string?)
		keepCache(b)
		local rest: { Model.HubPR } = {}
		for i = #finished + 1, #queue do table.insert(rest, queue[i]) end
		local done = if merge then (if handed then "Asked to merge " else "Merged ") else "Closed "
		if failed and reason then
			local text = (if #finished > 0 then done .. refList(finished) .. ". " else "") .. "Couldn't " .. (if merge then "merge" else "close") .. " #" .. failed.number .. ": " .. reason
			cx:toast("error", text, "Not " .. (if merge then "merged" else "closed") .. ": " .. refList(rest) .. ". Still selected.")
		else
			local n = #finished
			local noun = if n == 1 then "pull request" else "pull requests"
			cx:toast("success", done .. n .. " " .. noun, nil)
		end
		refetchSoon(b, cx)
		draw(b, cx)
	end
	step = function(index: number)
		local pr = queue[index]
		if not pr then return finish(nil, nil) end
		local function after(err: string?)
			if err then return finish(pr, err) end
			table.insert(finished, pr)
			s.marked[pr.key] = nil
			step(index + 1)
		end
		if merge then
			local kind = methodOf(b, pr).kind
			if kind ~= "squash" and kind ~= "merge" and kind ~= "rebase" then handed = true end
			runMerge(b, cx, pr, after)
			return
		end
		State.setBusy(s, pr.key, "Closing…")
		b.github.run(Github.commands.close(pr), function(_, err)
			if b.closed then return end
			State.setBusy(s, pr.key, nil)
			if err then return after(reasonOf(err.message)) end
			s.acted[pr.key] = true
			State.dropPr(s, pr.key)
			after(nil)
		end)
	end
	step(1)
end

-- Esc on the learned-method question declines it for good: the repo is not asked again.
ACTIONS["hub-confirm-cancel"] = function(b, cx)
	local s = b.s
	local confirm = s.confirm
	local card = if confirm and confirm.kind == "learned" then State.card(s, confirm.keys[1]) else nil
	State.cancelConfirm(s)
	if not card then return end
	local record = recordOf(b, card.pr.repo)
	record.learnedAnswered = true
	saveRecord(b, card.pr.repo, record)
	cx:toast("info", "Won't suggest that again for " .. card.pr.repo)
end
ACTIONS["hub-confirm"] = function(b, cx)
	local s = b.s
	local confirm = s.confirm
	local card = if confirm and (confirm.kind == "merge" or confirm.kind == "learned") then State.card(s, confirm.keys[1]) else nil
	local learned = confirm ~= nil and confirm.kind == "learned"
	if confirm and (confirm.kind == "batch-merge" or confirm.kind == "batch-close") then
		local keys = confirm.keys
		State.cancelConfirm(s)
		return runBatch(b, cx, keys, confirm.kind == "batch-merge")
	end
	State.cancelConfirm(s)
	if not card then return end
	local resolved = s.merges[card.pr.repo]
	-- Saying yes to the suggestion makes it the viewer's own setting.
	if learned and resolved then setUserMethod(b, cx, card.pr.repo, resolved.method) end
	if b.fixture then return cx:toast("info", "The sample board doesn't merge", card.pr.key) end
	runMerge(b, cx, card.pr, nil)
end

-- Update branch (U): a Ready card that is behind main. Its checks run again, so the card waits on them.
ACTIONS["card-update"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] then return end
	local pr = card.pr
	if not pr.behind or pr.conflicts then return cx:toast("info", "#" .. pr.number .. " isn't behind " .. pr.baseBranch, pr.key) end
	if b.fixture then return cx:toast("info", "The sample board doesn't update branches", pr.key) end
	State.setBusy(s, key, "Updating…")
	b.github.run(Github.commands.updateBranch(pr), function(_, err)
		if b.closed then return end
		if err then
			State.setBusy(s, key, nil)
			cx:toast("error", "Couldn't update #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
		else
			s.acted[key] = true
			State.branchUpdated(s, key)
			keepCache(b)
			cx:toast("success", "Updated #" .. pr.number .. " with " .. pr.baseBranch)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- Re-run failed checks (⇧R, behind Fix checks ▾): `gh run rerun <id> --failed` for each failing workflow run of the
-- card, one at a time. Only a press runs it. The runs come from the evidence on hand, else from the details.
ACTIONS["card-rerun"] = function(b, cx, key)
	local s = b.s
	local pr = State.prOf(s, key)
	if pr == nil or s.busy[key] then return end
	if b.fixture then return cx:toast("info", "The sample board doesn't re-run checks", pr.key) end
	if pr.checks.failing == 0 then return cx:toast("info", "#" .. pr.number .. " has no failing checks", pr.key) end
	local function fail(reason: string)
		State.setBusy(s, key, nil)
		cx:toast("error", "Couldn't re-run checks on #" .. pr.number .. ": " .. reasonOf(reason), pr.repo)
		draw(b, cx)
	end
	local function go(ids: { number })
		if #ids == 0 then return fail("GitHub lists no workflow run for the failing checks") end
		State.setBusy(s, key, "Re-running…")
		draw(b, cx)
		local function step(i: number)
			if b.closed then return end
			if i > #ids then
				State.setBusy(s, key, nil)
				b.flakeTried[pr.key .. "@" .. pr.headOid] = nil
				State.setFlake(s, key, nil)
				cx:toast("success", "Re-running failed checks on #" .. pr.number, pr.repo)
				refetchSoon(b, cx)
				return draw(b, cx)
			end
			b.github.run(Github.commands.rerun(pr.repo, ids[i]), function(_, err)
				if b.closed then return end
				if err then return fail(err.message) end
				step(i + 1)
			end)
		end
		step(1)
	end
	local known = State.flakeOf(s, key)
	if known and #known.runs > 0 then return go(known.runs) end
	State.setBusy(s, key, "Reading checks…")
	draw(b, cx)
	b.github.details(pr, function(d, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if d == nil then return fail(if err then err.message else "no answer") end
		local ids: { number } = {}
		for _, check in d.checks do
			if check.runId and table.find(ids, check.runId) == nil then table.insert(ids, check.runId) end
		end
		go(ids)
	end)
end

-- Add by link (N) ---------------------------------------------------------------------------------------

ACTIONS["hub-link"] = function(b, cx)
	State.openLink(b.s)
	frameLater(cx, { { "focus", Paths.linkField } })
end
ACTIONS["hub-link-clear"] = function(b)
	State.closeLink(b.s, true)
end

-- ⏎: add a new pull request to Review requests, or show one the board already has.
ACTIONS["hub-link-add"] = function(b, cx)
	local s = b.s
	local target = State.linkTarget(s)
	if target.kind == "board" then
		State.closeLink(s, true)
		if State.show(s, target.pr.key) then revealSelected(b, cx) end
	elseif target.kind == "new" then
		local ref: Model.PRRef = { repo = target.repo, number = target.number }
		if b.fixture then return cx:toast("info", "The sample board doesn't add pull requests") end
		local added, why = State.withAdded(readLocal().added, ref)
		local problem = why or (if added then writeAdded(added) else nil)
		if problem then return cx:toast("error", "Couldn't add #" .. ref.number .. ": " .. problem, ref.repo) end
		State.closeLink(s, true)
		b.show = ref
		cx:toast("info", "Adding #" .. ref.number .. " to Review requests…", ref.repo)
		refetch(b, cx)
	end
end

-- ⇧⏎: open it without adding it.
ACTIONS["hub-link-open"] = function(b, cx)
	local target = State.linkTarget(b.s)
	if target.kind == "board" or target.kind == "new" then
		State.closeLink(b.s, true)
		openPr(b, cx, target.repo, target.number, b.generate)
	end
end

-- Remove from Review requests (X): only on a pull request added by link.
ACTIONS["card-remove"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or not card.pr.addedByMe then return end
	local pr = card.pr
	if not b.fixture then
		local added = readLocal().added
		for at, ref in added do
			if ref.number == pr.number and string.lower(ref.repo) == string.lower(pr.repo) then added[at] = nil end
		end
		local why = writeAdded(added)
		if why then return cx:toast("error", "Couldn't remove #" .. pr.number .. ": " .. why, pr.repo) end
	end
	State.unadd(s, key)
	keepCache(b)
	cx:toast("info", "Removed #" .. pr.number .. " from Review requests", pr.repo)
	refetch(b, cx)
end

-- Review fix: only P can push, only confirmed D can discard, and neither forgets a held lease.
openReviewFix = function(b: Block, cx: BlockCx, key: string)
	if not State.openReviewFix(b.s, key) then return end
	local agent = b.s.agents[key]
	if not agent or agent.kind ~= "ready" then return end
	if agent.review then return end
	local route, fix = b.s.route :: State.Route, agent.fix
	local function read(value: Fetch.AgentFixRead?, err: string?)
		if b.s.agents[key] ~= agent then return end
		if value then agent.review = ReviewFix.build(fix, value.files, b.s.details[key], value.originals) end
		if b.s.route == route then
			route.loading = false
			route.error = if value then nil else "Couldn't read the fix: " .. reasonOf(err or "no answer")
		end
		if not b.closed then draw(b, cx) end
	end
	if b.fixture then
		local data: any = FIXTURES["review-fix"]()
		local files = if data.fix.commit == fix.commit then data.files else nil
		-- Other lifecycle samples have captured resolutions but no commit files. Assemble a
		-- recorded preview without running git; the dedicated sample carries actual file text.
		if not files then
			files = {}
			for _, hunk in fix.hunks do
				local lines = table.clone(hunk.context.before)
				for _, line in (if hunk.resolved then hunk.resolved.lines else {}) do table.insert(lines, line.text) end
				for _, line in hunk.context.after do table.insert(lines, line) end
				files[hunk.path] = (files[hunk.path] or "") .. table.concat(lines, "\n") .. "\n"
			end
		end
		read({ files = files, diff = "" }, nil)
		return
	end
	local ok, err = pcall(Fetch.readAgentFix, fix, read)
	if not ok then read(nil, tostring(err)) end
end

ACTIONS["review-fix-close"] = function(b, cx)
	if not b.s.route or b.s.route.kind ~= "review-fix" then return end
	local page = State.reviewPage(b.s)
	if page and (page.busy or page.ask) then return end
	State.closeFixes(b.s)
	revealSelected(b, cx)
end
ACTIONS["review-fix-step"] = function(b, _, index) State.reviewSelect(b.s, tonumber(index) or 1) end
ACTIONS["review-fix-move"] = function(b, _, delta)
	local page = State.reviewPage(b.s)
	if page then State.reviewSelect(b.s, page.cur + (tonumber(delta) or 0)) end
end
ACTIONS["review-fix-reviewed"] = function(b, _, index) State.reviewToggle(b.s, tonumber(index)) end
ACTIONS["review-fix-original"] = function(b) State.reviewOriginal(b.s) end
ACTIONS["review-fix-discard"] = function(b, cx)
	local page = State.reviewPage(b.s)
	if page and page.completion == "push" then return cx:toast("error", "Couldn't discard the fix: return the worktree lease first") end
	State.reviewAsk(b.s, true)
end
ACTIONS["review-fix-discard-cancel"] = function(b) State.reviewAsk(b.s, false) end

local function reviewEffect(b: Block, cx: BlockCx, action: "push" | "discard")
	local page, request = State.reviewPage(b.s), State.reviewRequest(b.s)
	if not page or page.busy then return end
	local verb = if action == "push" then "push" else "discard"
	if not request then return cx:toast("error", "Couldn't " .. verb .. " the fix: wait for the fix to load") end
	if action == "push" and page.ask then return end
	local plan, problem = ReviewFix.plan(action, request, page.ask)
	if not plan then return cx:toast("error", "Couldn't " .. verb .. " the fix: " .. (problem or "no action is available")) end
	local agent = b.s.agents[request.key]
	if not agent or agent.kind ~= "ready" or agent.fix ~= request.fix then return end
	local flight = if b.agentFlight and b.agentFlight.key == request.key then b.agentFlight else nil
	if not b.fixture then
		local lease = if flight and flight.engine then flight.engine.held() else nil
		if not flight or flight.key ~= request.key or not flight.settled or flight.starting or flight.releasing or not lease or lease.path ~= request.fix.worktree then
			return cx:toast("error", "Couldn't " .. verb .. " the fix: the worktree lease is unavailable")
		end
	end
	local route = b.s.route :: State.Route
	route.ask, route.error = false, nil
	State.setBusy(b.s, request.key, if action == "push" and plan.command then "Pushing fix…" else "Returning worktree lease…")
	draw(b, cx)
	local pushed = action == "push" and agent.completion == "push"
	local function fail(reason: string)
		State.setBusy(b.s, request.key, nil)
		if b.s.route == route then route.error = "Couldn't " .. verb .. " the fix: " .. reasonOf(reason) end
		if not b.closed then
			cx:toast("error", "Couldn't " .. verb .. " the fix: " .. reasonOf(reason))
			draw(b, cx)
		end
	end
	local function release()
		-- Completion is retained on the ready fix. P then retries only this return,
		-- while a failed Discard asks again and retries the same engine's guarded reset.
		agent.completion = action
		State.setBusy(b.s, request.key, "Returning worktree lease…")
		if not b.closed then draw(b, cx) end
		local called = false
		if flight then flight.releasing = true end
		local function returned(ok: boolean?, err: string?)
			if called then return end
			called = true
			if flight then flight.releasing = false end
			local engine = if flight then flight.engine else nil
			if ok and not b.fixture and (not engine or engine.held() ~= nil or engine.busy()) then ok, err = nil, "The engine still holds the worktree lease" end
			local outcome = ReviewFix.result(plan :: ReviewFix.Plan, pushed, ok == true)
			if not outcome.clear then return fail(err or "The worktree lease could not be returned") end
			if b.s.agents[request.key] ~= agent then return end
			b.s.agents[request.key], b.s.busy[request.key] = nil, nil
			if b.agentFlight == flight then b.agentFlight = nil end
			if action == "push" then
				local pr = State.prOf(b.s, request.key)
				if pr then pr.headOid, pr.conflicts = request.fix.commit, false end
				b.s.acted[request.key] = true
				State.branchUpdated(b.s, request.key)
			else State.project(b.s) end
			if b.s.route == route then State.closeFixes(b.s) end
			if not b.closed then
				cx:toast("success", if action == "push" then "Pushed the fix to #" .. request.number else "Discarded the fix for #" .. request.number)
				draw(b, cx)
				revealSelected(b, cx)
				if action == "push" then refetch(b, cx) end
			end
		end
		if b.fixture then returned(true, nil); return end
		local ok, err = pcall(Fetch.returnAgentFix, request.fix.worktree, returned)
		if not ok then returned(nil, tostring(err)) end
	end
	if action == "discard" or not plan.command then release(); return end
	local called = false
	local function completed(ok: boolean?, err: string?)
		if called then return end
		called = true
		if not ok then return fail(err or "Git refused the push") end
		pushed = true
		release()
	end
	if b.fixture then completed(true, nil); return end
	local function canPush(): boolean
		local current = b.s.agents[request.key]
		local pr = State.prOf(b.s, request.key)
		return not b.closed and b.agentFlight == flight and current ~= nil and current == agent and current.kind == "ready"
			and current.fix == request.fix and b.s.selected == request.key and b.s.route == route
			and route.kind == "review-fix" and State.reviewed(current.fix, current.reviewed)
			and pr ~= nil and pr.repo == request.repo and pr.number == request.number
			and (pr.headOid == request.fix.headOid or pr.headOid == request.fix.commit)
	end
	local ok, err = pcall(Fetch.pushAgentFix, plan, canPush, completed)
	if not ok then completed(nil, tostring(err)) end
end
ACTIONS["review-fix-push"] = function(b, cx) reviewEffect(b, cx, "push") end
ACTIONS["review-fix-discard-confirm"] = function(b, cx) reviewEffect(b, cx, "discard") end

-- The fixes page ---------------------------------------------------------------------------------------------
-- ⏎ on a Needs fixes card. The details are read once when it opens (one GraphQL call); the conflicted files and
-- the annotated source come from local git when the repo has a checkout. Reply and Resolve are GraphQL writes.

-- The annotated source files of the details' failing checks, each once.
local function annotatedPaths(d: Fixes.FixDetails): { string }
	local paths: { string } = {}
	for _, check in d.checks do
		for _, annotation in Fixes.usable(check.annotations) do
			if table.find(paths, annotation.path) == nil then table.insert(paths, annotation.path) end
		end
	end
	return paths
end

-- Reads the conflicts and the annotated files from the repo's checkout (or PR Guide's saved copy). With none, the
-- conflict step says so, and its files are unknown.
local function readGit(b: Block, cx: BlockCx, pr: Model.HubPR, d: Fixes.FixDetails)
	local paths = annotatedPaths(d)
	if not pr.conflicts and #paths == 0 then return end
	local dir = cx.cwd or tern.getenv("HOME") or ""
	Fetch.checkoutFor(nil, dir, pr.repo, function(found)
		if b.closed then return end
		local repo = found or Fetch.readySavedCopy(pr.repo)
		if repo == nil then
			if pr.conflicts then d.conflictNote = "No local copy of " .. pr.repo end
			return draw(b, cx)
		end
		Fetch.readFixes(repo, pr, paths, function(read, err)
			if b.closed then return end
			if read == nil then
				if pr.conflicts then d.conflictNote = "Couldn't read the conflicts: " .. reasonOf(err or "no answer") end
				return draw(b, cx)
			end
			d.files = read.files
			if pr.conflicts then
				local tree = Fixes.parseMergeTree(read.mergeTree or "")
				if tree then
					d.conflicts, d.conflictNote = Fixes.conflicts(tree, read.shown, read.logs), nil
				else
					d.conflictNote = "Couldn't read the conflicts: git printed nothing usable"
				end
			end
			draw(b, cx)
		end)
	end)
end

-- The sample board's details: the fixture for the card's key, with the recorded git output for its conflicts.
local function sampleDetails(pr: Model.HubPR): Fixes.FixDetails
	local fixture: any = require("../../fixtures/hub/fixes")
	local kind = fixture.sample[pr.key]
	local source: Fixes.FixDetails = if kind then fixture.details[kind] else fixture.details.failure
	local d = table.clone(source)
	d.key, d.headOid, d.fetchedAt, d.conflicts, d.conflictNote = pr.key, pr.headOid, "", nil, nil
	if pr.conflicts then
		local read = fixture.gitRead.conflictMany
		d.conflicts = Fixes.conflicts(Fixes.parseMergeTree(read.mergeTree) :: Fixes.MergeTree, read.shown, read.logs)
	end
	return d
end

openFixes = function(b: Block, cx: BlockCx, key: string)
	local s = b.s
	if not State.openFixes(s, key) then return end
	local pr = State.prOf(s, key) :: Model.HubPR
	if b.fixture then
		State.setDetails(s, sampleDetails(pr))
		return
	end
	local route = s.route :: State.Route
	local known = s.details[key]
	b.github.details(pr, function(d, err)
		if b.closed then return end
		if d == nil then
			if s.route == route then route.loading, route.error = false, if err then err.message else "no answer" end
			return draw(b, cx)
		end
		d.fetchedAt = isoNow()
		-- The same commit keeps what git said last time while it is read again.
		if known and known.headOid == d.headOid then d.conflicts, d.conflictNote, d.files = known.conflicts, known.conflictNote, known.files end
		State.setDetails(s, d)
		draw(b, cx)
		readGit(b, cx, pr, d)
	end)
end

ACTIONS["fixes-close"] = function(b)
	State.closeFixes(b.s)
end
ACTIONS["fixes-step"] = function(b, cx, index)
	State.fixSelect(b.s, tonumber(index) or 1)
	State.fixFocus(b.s, "steps")
end
ACTIONS["fixes-move"] = function(b, cx, delta)
	State.fixMove(b.s, tonumber(delta) or 0)
end
ACTIONS["fixes-focus"] = function(b, cx, where)
	State.fixFocus(b.s, if where == "panel" then "panel" else "steps")
end
ACTIONS["fixes-bots"] = function(b)
	State.fixToggleBots(b.s)
end

-- The page's pull request and the thread of the step on show, when it has one.
local function fixTarget(b: Block): (State.Route?, Model.HubPR?, Fixes.Step?)
	local s = b.s
	local route = s.route
	if route == nil then return nil, nil, nil end
	return route, State.prOf(s, route.key), State.fixStep(s)
end

ACTIONS["fixes-reply"] = function(b, cx)
	local route, _, step = fixTarget(b)
	if route == nil or step == nil or step.thread == nil then return end
	if route.resolved[step.thread.id] then return cx:toast("info", "This thread is resolved", step.thread.path) end
	if State.beginReply(b.s) then frameLater(cx, { { "focus", Paths.replyField } }) end
end
ACTIONS["fixes-cancel"] = function(b)
	State.cancelReply(b.s)
end
ACTIONS["fixes-post"] = function(b, cx)
	local route, pr, step = fixTarget(b)
	if route == nil or pr == nil or step == nil or step.thread == nil or route.reply == nil or route.busy then return end
	local thread = step.thread
	local text = string.match(route.reply.text, "^%s*(.-)%s*$") :: string
	if text == "" then return cx:toast("error", "Couldn't post the reply: it's empty", pr.key) end
	local function posted()
		route.busy = false
		local list = route.replies[thread.id] or {}
		table.insert(list, text)
		route.replies[thread.id] = list
		route.reply = nil
		if b.s.mode == "reply" then b.s.mode = "fixes" end
		cx:toast("success", "Replied to @" .. thread.author, pr.key)
	end
	if b.fixture then return posted() end
	route.busy = true
	b.github.run(Github.commands.reply(pr, thread.id, text), function(_, err)
		if b.closed then return end
		if err then
			route.busy = false
			cx:toast("error", err.message, pr.key)
		else
			posted()
		end
		draw(b, cx)
	end)
end
ACTIONS["fixes-resolve"] = function(b, cx)
	local route, pr, step = fixTarget(b)
	if route == nil or pr == nil or step == nil or step.thread == nil or route.busy then return end
	local thread = step.thread
	if route.resolved[thread.id] then return cx:toast("info", "This thread is already resolved", thread.path) end
	local function resolved()
		route.busy = false
		route.resolved[thread.id] = true
		cx:toast("success", "Resolved the thread", thread.path)
	end
	if b.fixture then return resolved() end
	route.busy = true
	b.github.run(Github.commands.resolve(thread.id), function(_, err)
		if b.closed then return end
		if err then
			route.busy = false
			cx:toast("error", err.message, pr.key)
		else
			resolved()
		end
		draw(b, cx)
	end)
end
ACTIONS["fixes-rerun"] = function(b, cx)
	local route = b.s.route
	if route then ACTIONS["card-rerun"](b, cx, route.key) end
end
ACTIONS["fixes-log"] = function(b, cx)
	local _, pr, step = fixTarget(b)
	if pr == nil or step == nil or step.check == nil then return end
	local url = Fixes.logUrl(step.check, pr.repo)
	if url == "" then return cx:toast("error", "Couldn't open the log: GitHub gave no link for " .. step.check.name, pr.key) end
	cx:open(url)
end
-- G: the step on GitHub: the conflict editor, the thread, the check, the review, or the pull request.
ACTIONS["fixes-github"] = function(b, cx)
	local _, pr, step = fixTarget(b)
	if pr == nil then return end
	local url = pr.url
	if step then
		if step.group == "conflict" then url = pr.url .. "/conflicts"
		elseif step.thread then url = step.thread.url
		elseif step.review then url = step.review.url
		elseif step.check and step.check.url ~= "" then url = step.check.url end
	end
	cx:open(url)
end
-- ⏎ in the panel runs the highlighted action; the agent action is the card's own.
ACTIONS["fixes-press"] = function(b, cx)
	local act = State.fixPress(b.s)
	if act == nil then return end
	local route, pr = fixTarget(b)
	if act == "agent" then
		local main = State.fixMain(b.s)
		local handler = if main then ACTIONS[main.act] else nil
		if handler and pr then handler(b, cx, pr.key) end
		return
	end
	local handler = ACTIONS["fixes-" .. act]
	if handler and route then handler(b, cx, "") end
end

local function dispatch(b: Block, cx: BlockCx, action: Keys.Action)
	local handler = ACTIONS[action.act]
	if handler then handler(b, cx, action.value or "") end
end

-- The agent the reader's omp is set to, and the models it can run (a live board only).
local function loadAgent(b: Block, cx: BlockCx)
	tern.timer(0, function()
		Fetch.findAgent(function(agent)
			if b.closed or not agent then return end
			b.agent = agent
			b.s.agent = { models = {}, model = agent.model, effort = agent.effort }
			draw(b, cx)
			Fetch.listModels(agent, function(models)
				if b.closed then return end
				local choice = b.s.agent
				if choice then
					for _, model in models do table.insert(choice.models, { selector = model.selector, name = model.name, efforts = model.efforts }) end
				end
				draw(b, cx)
			end)
		end)
	end)
end

-- Whether a click held `name` (shift, ctrl, alt or meta): Tern lists the held modifiers in `ev.mods`.
local function held(ev: UiEvent, name: string): boolean
	local mods: any = ev.mods
	if type(mods) ~= "table" then return false end
	return table.find(mods, name) ~= nil or mods[name] == true
end

local function actionOf(ev: UiEvent): Keys.Action?
	-- ⌘-click and ⇧-click on a card select it for Merge selected or Close stale instead of moving the selection.
	if ev.ev == "action" and ev.act == "hub-select" and (held(ev, "meta") or held(ev, "shift")) then
		return { act = "hub-mark", value = ev.value }
	end
	if ev.ev == "action" then return { act = ev.act, value = ev.value } end
	return nil
end

local block: BlockDef<Block> = {
	init = function(cx: BlockCx, args: { string }, saved: any): Block
		local opts, problem = options(args)
		local prs: { Model.HubPR } = {}
		local now = os.time()
		local refreshedAt: string? = nil
		local fixture = if opts then opts.fixture else nil
		local live = opts ~= nil and fixture == nil
		local cache: Sync.Cache? = nil
		if fixture then
			local data = FIXTURES[fixture]()
			prs, now, refreshedAt = data.prs, data.asOf, data.asOfIso
		elseif live then
			-- Open from the cache with no network wait; the first tick refreshes in the background.
			cache = readCache()
			if cache then
				prs, refreshedAt = cache.prs, cache.refreshedAt
				writeStatus(cache)
			end
		end
		local s = State.new(prs, now, saved)
		if fixture then
			State.setRecent(s, SAMPLE_RECENT)
		else
			-- The picker's list moves to hub.recent the first time the hub loads.
			Fetch.migrateRecent()
			State.setRecent(s, Fetch.recentPrs())
		end
		s.refreshedAt = refreshedAt
		s.loading = live and cache == nil
		if problem then s.error = { operation = "hub", message = problem } end
		local b: Block = {
			s = s, cache = cache, fixture = fixture, generate = opts ~= nil and opts.generate, agent = nil, agentFlight = nil,
			github = Github.client(Fetch.runner, tern.json.decode), timers = {},
			flights = { refresh = false, checks = false, probe = false, flake = false },
			sched = {
				probedAt = now, probeChanged = false, focusedAt = if live then now else nil, checksAt = nil,
				refreshTried = nil, lastModified = if cache then cache.lastModified else nil,
			},
			closed = false, refetch = false, show = nil, step = 0, records = {}, detecting = {}, flakeTried = {},
			histories = nil :: any,
		}
		b.histories = Github.historyCache(b.github)
		if fixture then
			-- The sample board's failing checks come with recorded evidence: one flaky, one a real type error.
			local evidence: any = require("../../fixtures/hub/flake")
			for key, name in evidence.board do
				local pr = State.prOf(s, key)
				for _, case in evidence.cases do
					if pr and case.name == name then
						local verdict = Model.flake(evidence.evidence(case))
						s.flakes[key] = { flaky = verdict.flaky, reason = verdict.reason, runs = evidence.runIds[key], headOid = pr.headOid }
					end
				end
			end
			-- A sample may bring how its repos merge and whether they allow auto-merge.
			local data: any = FIXTURES[fixture]()
			for repo, resolution in (data.merges or {}) do s.merges[repo] = resolution end
			for repo, allowed in (data.autoMerge or {}) do s.autoMerge[repo] = allowed end
			for key, agent in (data.agents or {}) do s.agents[key] = agent end
			if data.runningKey then
				b.agentFlight = { key = data.runningKey, settled = false, stopping = false, releasing = false, fixtureStep = data.runningStep }
			end
			State.project(s)
			local sample = table.clone(SAMPLE_AGENT)
			sample.models = table.clone(SAMPLE_AGENT.models)
			s.agent = sample
		elseif live then
			-- How each repo merges is known from the first frame, before any refresh.
			loadMerges(b)
			loadAgent(b, cx)
			rearm(b, cx)
		end
		return b
	end,
	title = function(b: Block): string?
		return "Pull requests"
	end,
	view = function(b: Block): BlockView
		local s = b.s
		local motion = { born = s.born, next = {}, booted = s.booted, animate = not s.keyed }
		if s.route then
			local page = if s.route.kind == "review-fix" then ReviewFixPage.view(s, motion) else FixesPage.view(s, motion)
			s.born, s.booted = motion.next, true
			return { main = page, layer = nil }
		end
		local main = Board.view(s, motion)
		s.born, s.booted = motion.next, true
		return { main = main, layer = Board.layer(s) }
	end,
	event = function(b: Block, ev: UiEvent, cx: BlockCx)
		local action = actionOf(ev)
		if not action then return end
		b.s.keyed = false
		dispatch(b, cx, action)
	end,
	key = function(b: Block, key: Key, cx: BlockCx): boolean?
		local s = b.s
		local action = Keys.hubAction(s, key)
		if action then
			s.keyed = true
			dispatch(b, cx, action)
			return true
		end
		if s.mode == "reply" and s.route and s.route.reply then
			-- ⏎ is a new line in a reply; ⌘⏎ posts it (Keys.hubAction).
			local typed = if key.name == "enter" and not (key.meta or key.ctrl) then { name = "enter", shift = true } :: any else key
			Fields.key(s.route.reply, typed)
			return true
		end
		if s.mode == "search" then
			local next = Keys.hubAfterTyping(s.mode, Fields.key(s.search, key))
			if next then
				s.keyed = true
				dispatch(b, cx, next)
			end
			return true
		end
		if s.mode == "link" then
			Fields.key(s.link, key)
			return true
		end
		if s.mode == "menu" and s.methodEdit then
			Fields.key(s.methodEdit.field, key)
			return true
		end
		-- Menus and the key panel swallow the keys they don't use.
		return s.mode ~= "board"
	end,
	save = function(b: Block): any
		return State.saved(b.s)
	end,
}

return block
