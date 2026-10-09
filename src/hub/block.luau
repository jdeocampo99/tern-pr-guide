--!strict
-- The PR hub block: reads its arguments, loads the board's pull requests (for now only the recorded
-- fixture), draws it, and turns clicks and keys into state changes plus the scrolling, focusing and toasts
-- only a live window can do. Clicks (`event`) and keys (`key`) both run one ACTIONS table.
local Agent = require("../agent")
local Board = require("../view/hub/board")
local Fetch = require("../fetch")
local Fields = require("../text-field")
local Keys = require("../keys")
local Model = require("./model")
local Paths = require("../view/hub/paths")
local State = require("./state")

type State = State.State

-- The hub block's own state. Later changes add the GitHub client, the cache and the timers here.
export type Block = {
	s: State,
	fixture: string?, -- `fixture=cases`: recorded data, no network, no timers
	generate: boolean, -- ⏎ opens the PR with the AI guide started
	agent: Agent.Agent?, -- the reader's own agent, once found (never with a fixture)
}

type Handler = (b: Block, cx: BlockCx, value: string) -> ()

local ARGS = "generate=true|false and fixture=<name> (cases)"

-- Fixtures by name, loaded only when asked for. `cases` is the rules' recorded pull requests.
local FIXTURES: { [string]: () -> any } = {
	cases = function() return require("../../fixtures/hub/cases") end,
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
	if card then frameLater(cx, { { "reveal", Paths.card(card), "nearest" } }) end
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

local function openCard(b: Block, cx: BlockCx, value: string)
	local s = b.s
	if value ~= "" then State.select(s, value) end
	local card = State.selectedCard(s)
	if card then cx:toast("info", "Opening a pull request isn't available yet", card.pr.key) end
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

local ACTIONS: { [string]: Handler } = {}

ACTIONS["hub-select"] = function(b, cx, key)
	State.select(b.s, key)
end
ACTIONS["hub-open"] = openCard
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
		if fixture then
			local data = FIXTURES[fixture]()
			prs, now, refreshedAt = data.prs, data.asOf, data.asOfIso
		end
		local s = State.new(prs, now, saved)
		s.refreshedAt = refreshedAt
		s.narrow = cx.cols > 0 and cx.cols < NARROW_COLS
		if problem then s.error = { operation = "hub", message = problem } end
		local b: Block = { s = s, fixture = fixture, generate = opts ~= nil and opts.generate, agent = nil }
		if fixture then
			local sample = table.clone(SAMPLE_AGENT)
			sample.models = table.clone(SAMPLE_AGENT.models)
			s.agent = sample
		elseif opts then
			loadAgent(b, cx)
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
