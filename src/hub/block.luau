--!strict
-- The PR hub block: reads its arguments, loads the board's pull requests (for now only the recorded
-- fixture), draws it, and turns clicks and keys into state changes plus the scrolling, focusing and toasts
-- only a live window can do. Clicks (`event`) and keys (`key`) both run one ACTIONS table.
local Agent = require("../agent")
local Board = require("../view/hub/board")
local Fetch = require("../fetch")
local Fields = require("../text-field")
local Github = require("../github")
local Keys = require("../keys")
local Links = require("../links")
local Model = require("./model")
local Paths = require("../view/hub/paths")
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

-- The hub block's own state.
export type Block = {
	s: State,
	cache: Sync.Cache?, -- what `hub.cache` last held (or this block last wrote)
	fixture: string?, -- `fixture=cases`: recorded data, no network, no timers
	generate: boolean, -- ⏎ opens the PR with the AI guide started
	agent: Agent.Agent?, -- the reader's own agent, once found (never with a fixture)
	github: Github.Client, timers: Timers,
	flights: { refresh: boolean, checks: boolean, probe: boolean }, -- one call of each kind at a time
	sched: Sched,
	closed: boolean, -- a render failed: the window is gone, so no timer starts anything
}

type Handler = (b: Block, cx: BlockCx, value: string) -> ()

local ARGS = "generate=true|false and fixture=<name> (cases)"

-- Fixtures by name, loaded only when asked for. `cases` is the rules' recorded pull requests.
local FIXTURES: { [string]: () -> any } = {
	cases = function() return require("../../fixtures/hub/cases") end,
}

-- The recently opened pull requests a fixture board shows, so the fold has rows without a kv store.
local SAMPLE_RECENT: { Sync.Opened } = {
	{ repo = "acme/api", number = 412, title = "Add retry budget to the billing client", author = "dana", at = "2026-10-08T09:12:33Z" },
	{ repo = "acme/web", number = 977, title = "Move the settings tabs into the sidebar", author = "ruben", at = "2026-10-06T16:40:02Z" },
	{ repo = "acme/api", number = 398, title = "Drop the unused webhook table", author = "mei", at = "2026-09-29T11:05:48Z" },
}

-- A pane narrower than this many columns is split beside a terminal: the board's columns stack.
local NARROW_COLS = 110

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
-- routes to the guide (`Links.openLink`). With no checkout and no copy to make, it says why and opens
-- nothing. A card's open action uses this too.
local function openPr(b: Block, cx: BlockCx, slug: string, number: number, generate: boolean)
	local dir = cx.cwd or tern.getenv("HOME") or ""
	Fetch.checkoutFor(nil, dir, slug, function(found)
		if b.closed then return end
		if found then
			cx:open(Links.openLink(slug, number, found.root, generate, false))
			return
		end
		local _, why = Fetch.savedCopy("github.com", slug)
		if why or dir == "" then
			cx:toast("error", "Couldn't open #" .. number .. " of " .. slug, why or "No folder to look for a checkout in.")
			return
		end
		cx:open(Links.openLink(slug, number, dir, generate, true))
	end)
end

-- ⏎ and a double-click open the selected row; ⇧⏎ (or a hub opened for AI guides) starts the AI guide too.
local function openRow(b: Block, cx: BlockCx, value: string, withGuide: boolean)
	local s = b.s
	if value ~= "" then State.select(s, value) end
	local generate = withGuide or b.generate
	local recent = State.selectedRecent(s)
	if recent then return openPr(b, cx, recent.repo, recent.number, generate) end
	local card = State.selectedCard(s)
	if card then cx:toast("info", "Opening a pull request isn't available yet", card.pr.key) end
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

-- The tiny record the window's status segment reads every 15 s, so it never decodes the whole cache.
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

-- Takes another window's newer cache, so windows share one refresh.
local function adoptShared(b: Block)
	local shared = readCache()
	if not shared then return end
	local theirs, mine = Model.epoch(shared.refreshedAt), cachedAt(b)
	if theirs and (mine == nil or theirs > mine) then
		b.cache = shared
		State.replace(b.s, shared.prs, os.time(), shared.refreshedAt)
	end
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

local function stop(b: Block)
	b.closed = true
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

-- Arms the probe, refresh (as the debounce while a change or focus waits) and checks timers from the schedule.
local function rearm(b: Block, cx: BlockCx)
	if b.fixture or b.closed then return end
	adoptShared(b)
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

local function startRefresh(b: Block, cx: BlockCx)
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
			local cache = Sync.merge(fresh, b.cache, readLocal(), now)
			cache.lastModified = b.sched.lastModified
			b.cache = cache
			b.sched.probeChanged, b.sched.focusedAt = false, nil
			State.replace(b.s, cache.prs, now, cache.refreshedAt)
			local why = persist(b)
			if why then b.s.error = { operation = KV_CACHE, message = "the cache couldn't be saved: " .. why } end
		end
		rearm(b, cx)
		draw(b, cx)
	end)
	draw(b, cx)
end

onRefresh = function(b, cx)
	if b.flights.refresh then return end
	adoptShared(b)
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
ACTIONS["hub-fold"] = function(b, cx, name)
	State.toggleFold(b.s, name)
end
ACTIONS["hub-escape"] = function(b, cx)
	local s = b.s
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
	if s.menu == "actions" then return closeMenu(b) end
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
ACTIONS["card-agent"] = notYet("Fix with agent")
ACTIONS["card-handoff"] = notYet("Hand off to Tandem")
ACTIONS["card-summarize"] = notYet("Summarize")
ACTIONS["card-copy"] = notYet("Copy link")
ACTIONS["card-merge"] = notYet("Merge")
ACTIONS["card-update"] = notYet("Update branch")
ACTIONS["card-method"] = notYet("Merge method")
ACTIONS["card-remove"] = notYet("Remove from Review requests")

local function dispatch(b: Block, cx: BlockCx, action: Keys.Action)
	local handler = ACTIONS[action.act]
	if handler then handler(b, cx, action.value or "") end
end

-- The agent the reader's omp is set to, and the models it can run (a live board only).
local function loadAgent(b: Block, cx: BlockCx)
	tern.timer(0, function()
		Fetch.findAgent(function(agent)
			if not agent then return end
			b.agent = agent
			b.s.agent = { models = {}, model = agent.model, effort = agent.effort }
			cx:render()
			Fetch.listModels(agent, function(models)
				local choice = b.s.agent
				if choice then
					for _, model in models do table.insert(choice.models, { selector = model.selector, name = model.name, efforts = model.efforts }) end
				end
				cx:render()
			end)
		end)
	end)
end

local function actionOf(ev: UiEvent): Keys.Action?
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
		s.narrow = cx.cols > 0 and cx.cols < NARROW_COLS
		if problem then s.error = { operation = "hub", message = problem } end
		local b: Block = {
			s = s, cache = cache, fixture = fixture, generate = opts ~= nil and opts.generate, agent = nil,
			github = Github.client(Fetch.runner, tern.json.decode), timers = {},
			flights = { refresh = false, checks = false, probe = false },
			sched = {
				probedAt = now, probeChanged = false, focusedAt = if live then now else nil, checksAt = nil,
				refreshTried = nil, lastModified = if cache then cache.lastModified else nil,
			},
			closed = false,
		}
		if fixture then
			local sample = table.clone(SAMPLE_AGENT)
			sample.models = table.clone(SAMPLE_AGENT.models)
			s.agent = sample
		elseif live then
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
		if s.mode == "search" then
			local next = Keys.hubAfterTyping(s.mode, Fields.key(s.search, key))
			if next then
				s.keyed = true
				dispatch(b, cx, next)
			end
			return true
		end
		-- Menus and the key panel swallow the keys they don't use.
		return s.mode ~= "board"
	end,
	resize = function(b: Block, cols: number, rows: number, cx: BlockCx)
		b.s.narrow = cols < NARROW_COLS
	end,
	save = function(b: Block): any
		return State.saved(b.s)
	end,
}

return block
