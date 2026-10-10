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
	refetch: boolean, -- a refresh was asked for while one was running: run another when it ends
	show: Model.PRRef?, -- a pull request just added by link: select it when the refresh brings it
	step: number, -- fixture only: how many `refreshes` entries ⌘R has applied
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

-- ⏎ and a double-click open the selected row; ⇧⏎ (or a hub opened for AI guides) starts the AI guide too.
local function openRow(b: Block, cx: BlockCx, value: string, withGuide: boolean)
	local s = b.s
	if value ~= "" then State.select(s, value) end
	local generate = withGuide or b.generate
	local recent = State.selectedRecent(s)
	if recent then return openPr(b, cx, recent.repo, recent.number, generate) end
	local card = State.selectedCard(s)
	if card then openPr(b, cx, card.pr.repo, card.pr.number, generate) end
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
ACTIONS["card-method"] = notYet("Merge method")

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

-- Merge (M) asks first; ⌘⏎ merges with the repo's method, Esc cancels.
ACTIONS["card-merge"] = function(b, cx, key)
	State.askMerge(b.s, key)
end
ACTIONS["hub-confirm-cancel"] = function(b)
	State.cancelConfirm(b.s)
end
ACTIONS["hub-confirm"] = function(b, cx)
	local s = b.s
	local confirm = s.confirm
	local card = if confirm and confirm.kind == "merge" then State.card(s, confirm.keys[1]) else nil
	State.cancelConfirm(s)
	if not card then return end
	local pr = card.pr
	if b.fixture then return cx:toast("info", "The sample board doesn't merge", pr.key) end
	local method = { kind = State.mergeMethodFor(s, pr) } :: any
	State.setBusy(s, pr.key, "Merging…")
	b.github.run(Github.commands.merge(pr, method), function(_, err)
		if b.closed then return end
		if err then
			State.setBusy(s, pr.key, nil)
			cx:toast("error", "Couldn't merge #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
		else
			s.acted[pr.key] = true
			State.dropPr(s, pr.key)
			keepCache(b)
			cx:toast("success", "Merged #" .. pr.number, pr.title)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
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
			closed = false, refetch = false, show = nil, step = 0,
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
		if s.mode == "link" then
			Fields.key(s.link, key)
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
