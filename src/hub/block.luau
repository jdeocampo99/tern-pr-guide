--!strict
-- The PR hub block: reads its arguments, loads the board's pull requests (for now only the recorded
-- fixture), draws it, and turns clicks and keys into state changes plus the scrolling, focusing and toasts
-- only a live window can do. Clicks (`event`) and keys (`key`) both run one ACTIONS table.
local Agent = require("../agent")
local Board = require("../view/hub/board")
local Fetch = require("../fetch")
local Fields = require("../text-field")
local FixesPage = require("../view/hub/fixes")
local Fixes = require("./fixes")
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
	records: { [string]: Sync.MergeRecord }, -- each repo's hub.merge.* record, read once
	detecting: { [string]: boolean }, -- repos whose merge method was asked for this session (once each, success or not)
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

-- ⏎ and a double-click open the selected row; ⇧⏎ (or a hub opened for AI guides) starts the AI guide too.
local function openRow(b: Block, cx: BlockCx, value: string, withGuide: boolean)
	local s = b.s
	if value ~= "" then State.select(s, value) end
	local generate = withGuide or b.generate
	local recent = State.selectedRecent(s)
	if recent then return openPr(b, cx, recent.repo, recent.number, generate) end
	local card = State.selectedCard(s)
	if card == nil then return end
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
local function detectRepo(b: Block, cx: BlockCx, repo: string)
	if b.fixture or b.closed or b.detecting[repo] or readRecord(b, repo) then return end
	b.detecting[repo] = true
	b.github.detect(repo, function(found, err)
		if b.closed then return end
		if found then
			local record = recordOf(b, repo)
			record.declared, record.learned, record.viewerDefault, record.checkedAt = found.declared, found.learned, found.viewerDefault, isoNow()
			local why = saveRecord(b, repo, record)
			if why then cx:toast("error", "Couldn't save how " .. repo .. " merges: " .. why) end
		else
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
		end
	end
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
ACTIONS["card-agent"] = notYet("Fix with agent")
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
			else
				cx:toast("success", "Removed #" .. pr.number .. " from the merge queue", pr.title)
			end
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
			s = s, cache = cache, fixture = fixture, generate = opts ~= nil and opts.generate, agent = nil,
			github = Github.client(Fetch.runner, tern.json.decode), timers = {},
			flights = { refresh = false, checks = false, probe = false },
			sched = {
				probedAt = now, probeChanged = false, focusedAt = if live then now else nil, checksAt = nil,
				refreshTried = nil, lastModified = if cache then cache.lastModified else nil,
			},
			closed = false, refetch = false, show = nil, step = 0, records = {}, detecting = {},
		}
		if fixture then
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
			local page = FixesPage.view(s, motion)
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
