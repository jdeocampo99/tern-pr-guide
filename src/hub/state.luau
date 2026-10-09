--!strict
-- The hub's interaction state (tab, selection, filter, sort, search, open menus) and the board
-- built from it. Views read `State.board` and never filter, sort or classify: every rule is `model`'s.
-- Pure: no clock, no network, no Tern. `now` is passed in.
local Fields = require("../text-field")
local Model = require("./model")

type HubPR = Model.HubPR
type Tab = Model.Tab
type Column = Model.Column
type Sort = Model.Sort

-- The modules this one will require once they exist (sync, fixes, agent-fix, summary) are
-- not written yet. Their types the state needs are declared here with the same shapes as the spec's
-- contract, and the issue that adds each module replaces its placeholder with the module's own type.
export type Opened = { repo: string, number: number, title: string, author: string, at: string } -- sync.Opened
export type Summary = { verdict: string, comments: { { author: string, text: string } } } -- summary.Summary
export type FixDetails = { key: string } -- fixes.FixDetails
type Run = { key: string, stage: string, since: number } -- agent-fix.Run
type Fix = { worktree: string, branch: string, base: string, headOid: string, commit: string, summary: string, usedAgent: boolean } -- agent-fix.Fix

export type Mode = "board" | "search" | "link" | "menu" | "confirm" | "help"
export type MenuId = "repositories" | "sort" | "agent" | "merge" | "actions"
export type CardAction = { act: string, value: string?, label: string, key: string?, confirm: boolean }

export type AgentFixState =
	{ kind: "no_clone", slug: string }
	| { kind: "running", run: Run }
	| { kind: "ready", fix: Fix, reviewed: { [string]: boolean } }
	| { kind: "pushing", fix: Fix }
	| { kind: "failed", reason: string, worktree: string? }

export type Card = {
	pr: HubPR,
	column: Column,
	reasons: { Model.Reason },
	main: CardAction?, -- the split button's action
	more: { CardAction }, -- behind the attached ▾
	agent: AgentFixState?,
	summary: Summary?,
	merge: Model.MergeResolution?,
	ring: ("bad" | "good")?, -- the arrival ring, until it fades
	selected: boolean,
	marked: boolean,
}
export type RepoOption = { repo: string, count: number, on: boolean }

-- Everything a view reads, built by `project`.
export type BoardData = {
	tab: Tab,
	columns: { { column: Column, cards: { Card } } }, -- the tab's columns, left to right, filtered and ordered
	inactive: { Card }, -- the fold under "Your pull requests"
	recent: { Opened }, -- the fold under "Review requests"
	open: { inactive: boolean, recent: boolean }, -- which folds show their rows
	grid: { { string } }, -- keys per column, for h j k l
	counts: { mine: number, review: number }, -- your-turn cards per tab: the blue counts
	repositories: { RepoOption },
	nextUp: Model.NextUp?,
	empty: boolean,
}

-- The agent's model and effort for fixes, summaries and guides; the models it can pick from.
export type AgentModel = { selector: string, name: string, efforts: { string } }
export type AgentChoice = { models: { AgentModel }, model: string, effort: string? }

export type State = {
	prs: { HubPR },
	now: number,
	board: BoardData, -- rebuilt by `project` after any input below changes
	tab: Tab,
	selected: string?,
	marked: { [string]: boolean },
	repositories: { [string]: boolean }?,
	sort: Sort,
	search: Fields.Field,
	link: Fields.Field,
	mode: Mode,
	menu: MenuId?,
	menuCursor: number,
	confirm: { kind: string, keys: { string } }?,
	folded: { [string]: boolean }, -- true: the fold is closed. Inactive and Recently opened start closed
	walking: boolean, -- Next up is being walked: the banner shows "2 of 11"
	ringed: { [string]: "bad" | "good" },
	agents: { [string]: AgentFixState },
	details: { [string]: FixDetails },
	summaries: { [string]: Summary },
	merges: { [string]: Model.MergeResolution }, -- by repo
	refreshedAt: string?,
	loading: boolean,
	error: Model.Error?,
	agent: AgentChoice?, -- nil until the block has found the agent
	narrow: boolean, -- the pane is split beside a terminal: the columns stack
	keyed: boolean, -- the change being drawn came from a key: it never animates
	born: { [string]: string },
	booted: boolean, -- arrival motion, as src/state.luau
}

export type MenuRow = { label: string, sub: string?, count: number?, on: boolean, kind: "choice" | "check" | "clear" }

local M = {}

M.TABS = {
	{ id = "mine" :: Tab, label = "Your pull requests" },
	{ id = "review" :: Tab, label = "Review requests" },
}

M.COLUMNS = {
	mine = { "needs_fixes", "in_review", "ready" },
	review = { "to_review", "waiting_on_author", "approved" },
} :: { [Tab]: { Column } }

M.SORTS = {
	{ id = "repository" :: Sort, label = "Repository", sub = "Priority within each" },
	{ id = "priority" :: Sort, label = "Priority", sub = "What to do first" },
	{ id = "newest" :: Sort, label = "Newest first", sub = "Most recently opened" },
	{ id = "oldest" :: Sort, label = "Oldest first", sub = "Waiting longest" },
	{ id = "smallest" :: Sort, label = "Smallest first", sub = "Fewest lines changed" },
}

local function emptyBoard(tab: Tab): BoardData
	return {
		tab = tab, columns = {}, inactive = {}, recent = {}, open = { inactive = false, recent = false },
		grid = {}, counts = { mine = 0, review = 0 }, repositories = {}, nextUp = nil, empty = true,
	}
end

local function validTab(value: any): Tab?
	if value == "mine" or value == "review" then return value end
	return nil
end

local function validSort(value: any): Sort?
	for _, sort in M.SORTS do
		if sort.id == value then return sort.id end
	end
	return nil
end

-- `saved` is what the block's `save` returned last time (tab, sort, repositories, folded), or anything at all.
function M.new(prs: { HubPR }, now: number, saved: any): State
	local tab: Tab = "mine"
	local sort: Sort = "repository"
	local repositories: { [string]: boolean }? = nil
	local folded: { [string]: boolean } = { inactive = true, recent = true }
	if type(saved) == "table" then
		tab = validTab(saved.tab) or tab
		sort = validSort(saved.sort) or sort
		if type(saved.repositories) == "table" and #saved.repositories > 0 then
			local set: { [string]: boolean } = {}
			for _, repo in saved.repositories do
				if type(repo) == "string" then set[repo] = true end
			end
			repositories = set
		end
		if type(saved.folded) == "table" then
			for name, value in saved.folded do
				if type(name) == "string" and type(value) == "boolean" then folded[name] = value end
			end
		end
	end
	local s: State = {
		prs = prs, now = now, board = emptyBoard(tab), tab = tab, selected = nil, marked = {},
		repositories = repositories, sort = sort, search = Fields.create(""), link = Fields.create(""),
		mode = "board", menu = nil, menuCursor = 1, confirm = nil, folded = folded, walking = false,
		ringed = {}, agents = {}, details = {}, summaries = {}, merges = {},
		refreshedAt = nil, loading = false, error = nil, agent = nil, narrow = false,
		keyed = false, born = {}, booted = false,
	}
	M.project(s)
	return s
end

-- What a saved state holds, for the block's `save`.
function M.saved(s: State): { tab: Tab, sort: Sort, repositories: { string }?, folded: { [string]: boolean } }
	local repositories: { string }? = nil
	if s.repositories then
		local list: { string } = {}
		for repo in s.repositories do table.insert(list, repo) end
		table.sort(list)
		repositories = list
	end
	return { tab = s.tab, sort = s.sort, repositories = repositories, folded = s.folded }
end

-- The actions a card offers, from the spec's "Cards and actions" table. Keys are the shortcuts the
-- selected card answers to. Only the pieces that exist at this stage of the hub are listed.
local function action(act: string, label: string, key: string?): CardAction
	return { act = act, value = nil, label = label, key = key, confirm = false }
end

local function actionsFor(pr: HubPR, column: Column, reasons: { Model.Reason }): (CardAction?, { CardAction })
	if column == "needs_fixes" then
		local feedback = false
		for _, reason in reasons do
			if reason == "feedback" then feedback = true end
		end
		if feedback and #reasons == 1 then return action("card-summarize", "Summarize", "A"), {} end
		local main = if pr.tandem then action("card-handoff", "Hand off to Tandem", "A") else action("card-agent", "Fix with agent", "A")
		return main, if feedback then { action("card-summarize", "Summarize", "⇧A") } else {}
	elseif column == "in_review" then
		return action("card-copy", "Copy link", "C"), {}
	elseif column == "ready" then
		if pr.behind then return action("card-update", "Update branch", "U"), { action("card-method", "Merge method", ",") } end
		return action("card-merge", "Merge", "M"), { action("card-method", "Merge method", ",") }
	elseif column == "to_review" then
		return action("open", "Review", "⏎"), if pr.addedByMe then { action("card-remove", "Remove from Review requests", "X") } else {}
	end
	return nil, {}
end

local function toCard(pr: HubPR, placement: Model.Placement, s: State): Card
	local main, more = actionsFor(pr, placement.column, placement.reasons)
	return {
		pr = pr, column = placement.column, reasons = placement.reasons, main = main, more = more,
		agent = s.agents[pr.key], summary = s.summaries[pr.key], merge = s.merges[pr.repo],
		ring = s.ringed[pr.key], selected = s.selected == pr.key, marked = s.marked[pr.key] == true,
	}
end

local function shortRepo(repo: string): string
	return string.match(repo, "[^/]+$") or repo
end

-- Recomputes `s.board` from `s.prs` and the inputs. Keeps the selection only while its card is on the board.
function M.project(s: State)
	local filter: Model.Filter = { repositories = s.repositories, search = s.search.text }
	local placements: { [string]: Model.Placement } = {}
	local counts = { mine = 0, review = 0 }
	local inTab: { HubPR } = {}
	for _, pr in s.prs do
		local placement = Model.placement(pr, s.now)
		placements[pr.key] = placement
		if Model.visible(pr, filter) then
			if placement.column == "needs_fixes" then counts.mine += 1 end
			if placement.column == "to_review" then counts.review += 1 end
			if placement.tab == s.tab then table.insert(inTab, pr) end
		end
	end

	local columns: { { column: Column, cards: { Card } } } = {}
	local grid: { { string } } = {}
	local present: { [string]: boolean } = {}
	local total = 0
	for _, column in M.COLUMNS[s.tab] do
		local cards: { Card } = {}
		local keys: { string } = {}
		for _, pr in Model.order(inTab, column, s.sort, s.now) do
			table.insert(cards, toCard(pr, placements[pr.key], s))
			table.insert(keys, pr.key)
			present[pr.key] = true
		end
		total += #cards
		table.insert(columns, { column = column, cards = cards })
		table.insert(grid, keys)
	end
	local inactive: { Card } = {}
	if s.tab == "mine" then
		for _, pr in Model.order(inTab, "inactive", s.sort, s.now) do
			table.insert(inactive, toCard(pr, placements[pr.key], s))
		end
	end
	-- The fold opens on its own while a search is typed, so its matches show.
	local searching = s.search.text ~= ""
	local foldOpen = #inactive > 0 and (not s.folded.inactive or searching)
	if foldOpen then
		for _, card in inactive do present[card.pr.key] = true end
	end

	-- Every repository in this tab that the search matches, most pull requests first. A chosen repository
	-- with nothing left to show stays listed, so it can be unchosen.
	local counted: { [string]: number } = {}
	for _, pr in s.prs do
		if placements[pr.key].tab == s.tab and Model.visible(pr, { repositories = nil, search = s.search.text }) then
			counted[pr.repo] = (counted[pr.repo] or 0) + 1
		end
	end
	if s.repositories then
		for repo in s.repositories do counted[repo] = counted[repo] or 0 end
	end
	local repositories: { RepoOption } = {}
	for repo, count in counted do
		table.insert(repositories, { repo = repo, count = count, on = s.repositories ~= nil and s.repositories[repo] == true })
	end
	table.sort(repositories, function(a: RepoOption, b: RepoOption): boolean
		if a.count ~= b.count then return a.count > b.count end
		return string.lower(shortRepo(a.repo)) < string.lower(shortRepo(b.repo))
	end)

	s.board = {
		tab = s.tab, columns = columns, inactive = inactive, recent = {},
		open = { inactive = foldOpen, recent = false },
		grid = grid, counts = counts, repositories = repositories, nextUp = nil,
		empty = total == 0 and #inactive == 0,
	}
	if s.selected and not present[s.selected] then s.selected = nil end
end

function M.mode(s: State): Mode
	return s.mode
end

-- The card with `key` on the board.
function M.card(s: State, key: string): Card?
	for _, column in s.board.columns do
		for _, card in column.cards do
			if card.pr.key == key then return card end
		end
	end
	for _, card in s.board.inactive do
		if card.pr.key == key then return card end
	end
	return nil
end

function M.selectedCard(s: State): Card?
	if s.selected then return M.card(s, s.selected) end
	return nil
end

local function refreshSelection(s: State)
	for _, column in s.board.columns do
		for _, card in column.cards do card.selected = card.pr.key == s.selected end
	end
	for _, card in s.board.inactive do card.selected = card.pr.key == s.selected end
end

function M.select(s: State, key: string?)
	s.selected = key
	refreshSelection(s)
end

-- Moves the selection one step: "down" and "up" within a column (down from the last card enters the open
-- Inactive fold; up from its first card returns), "left" and "right" to the card at the same height in the
-- next column that has any. Nothing selected: any direction selects the first card of the first column.
function M.move(s: State, direction: "up" | "down" | "left" | "right"): boolean
	local grid = s.board.grid
	local fold: { string } = {}
	if s.board.open.inactive then
		for _, card in s.board.inactive do table.insert(fold, card.pr.key) end
	end
	local selected = s.selected
	local function go(key: string): boolean
		if key == selected then return false end
		M.select(s, key)
		return true
	end
	if selected == nil then
		for _, keys in grid do
			if #keys > 0 then return go(keys[1]) end
		end
		if #fold > 0 then return go(fold[1]) end
		return false
	end
	local inFold = table.find(fold, selected)
	if inFold then
		if direction == "down" then return go(fold[math.min(#fold, inFold + 1)]) end
		if direction == "up" then
			if inFold > 1 then return go(fold[inFold - 1]) end
			for index = 1, #grid do
				local keys = grid[index]
				if #keys > 0 then return go(keys[#keys]) end
			end
		end
		return false
	end
	local column, row = 0, 0
	for index, keys in grid do
		local at = table.find(keys, selected)
		if at then column, row = index, at end
	end
	if column == 0 then return false end
	local keys = grid[column]
	if direction == "down" then
		if row == #keys and #fold > 0 then return go(fold[1]) end
		return go(keys[math.min(#keys, row + 1)])
	elseif direction == "up" then
		return go(keys[math.max(1, row - 1)])
	end
	local step = if direction == "right" then 1 else -1
	local index = column + step
	while index >= 1 and index <= #grid do
		local next = grid[index]
		if #next > 0 then return go(next[math.min(#next, row)]) end
		index += step
	end
	return false
end

function M.setTab(s: State, tab: Tab)
	if s.tab == tab then return end
	s.tab = tab
	M.project(s)
	refreshSelection(s)
end

function M.switchTab(s: State)
	M.setTab(s, if s.tab == "mine" then "review" else "mine")
end

function M.setSort(s: State, sort: Sort)
	s.sort = sort
	M.project(s)
end

-- Chooses or unchooses `repo`; with none chosen every repository shows.
function M.toggleRepository(s: State, repo: string)
	local set: { [string]: boolean } = {}
	if s.repositories then
		for name in s.repositories do set[name] = true end
	end
	if set[repo] then set[repo] = nil else set[repo] = true end
	s.repositories = if next(set) == nil then nil else set
	M.project(s)
end

function M.clearRepositories(s: State)
	s.repositories = nil
	M.project(s)
end

-- Replaces the search text (tests, and a cleared field).
function M.setSearch(s: State, text: string)
	s.search = Fields.create(text)
	M.project(s)
end

-- A key typed into the search field changed its text.
function M.searched(s: State)
	M.project(s)
end

function M.openSearch(s: State)
	s.mode = "search"
	s.menu = nil
end

-- Leaves the search field; `clear` also empties it (Esc).
function M.closeSearch(s: State, clear: boolean)
	s.mode = "board"
	if clear and s.search.text ~= "" then M.setSearch(s, "") end
end

function M.toggleFold(s: State, name: string)
	s.folded[name] = not s.folded[name]
	M.project(s)
end

function M.openHelp(s: State)
	s.mode = "help"
	s.menu = nil
end

function M.closeHelp(s: State)
	if s.mode == "help" then s.mode = "board" end
end

-- The rows of the open menu.
local function row(label: string, sub: string?, count: number?, on: boolean, kind: "choice" | "check" | "clear"): MenuRow
	return { label = label, sub = sub, count = count, on = on, kind = kind }
end

function M.menuRows(s: State): { MenuRow }
	local rows: { MenuRow } = {}
	if s.menu == "sort" then
		for _, sort in M.SORTS do
			table.insert(rows, row(sort.label, sort.sub, nil, s.sort == sort.id, "choice"))
		end
	elseif s.menu == "repositories" then
		for _, option in s.board.repositories do
			table.insert(rows, row(shortRepo(option.repo), nil, option.count, option.on, "check"))
		end
		if s.repositories then table.insert(rows, row("Clear filter", nil, nil, false, "clear")) end
	elseif s.menu == "actions" then
		local card = M.selectedCard(s)
		if card then
			for _, more in card.more do table.insert(rows, row(more.label, more.key, nil, false, "choice")) end
		end
	elseif s.menu == "agent" and s.agent then
		for _, model in s.agent.models do
			table.insert(rows, row(model.name, string.match(model.selector, "^([^/]+)/"), nil, model.selector == (s.agent :: AgentChoice).model, "choice"))
		end
	end
	return rows
end

function M.openMenu(s: State, menu: MenuId)
	s.menu = menu
	s.mode = "menu"
	s.menuCursor = 1
	if menu == "sort" then
		for index, sort in M.SORTS do
			if sort.id == s.sort then s.menuCursor = index end
		end
	elseif menu == "agent" and s.agent then
		for index, model in s.agent.models do
			if model.selector == s.agent.model then s.menuCursor = index end
		end
	end
end

function M.closeMenu(s: State)
	s.menu = nil
	if s.mode == "menu" then s.mode = "board" end
end

function M.menuMove(s: State, delta: number)
	s.menuCursor = math.clamp(s.menuCursor + delta, 1, math.max(1, #M.menuRows(s)))
end

-- The efforts the highlighted model takes in the agent menu, and the one now chosen.
function M.agentEfforts(s: State): ({ string }, string?)
	local agent = s.agent
	if s.menu ~= "agent" or not agent then return {}, nil end
	local model = agent.models[s.menuCursor]
	if not model then return {}, nil end
	return model.efforts, agent.effort
end

-- Steps the effort of the highlighted model along its levels.
function M.stepEffort(s: State, delta: number)
	local agent = s.agent
	if not agent then return end
	local efforts, current = M.agentEfforts(s)
	if #efforts == 0 then return end
	local at = (current and table.find(efforts, current)) or table.find(efforts, "high") or 1
	agent.effort = efforts[math.clamp(at + delta, 1, #efforts)]
end

function M.setEffort(s: State, level: string)
	local efforts = M.agentEfforts(s)
	if s.agent and table.find(efforts, level) then s.agent.effort = level end
end

-- Applies row `index` of the open menu: a sort or model is chosen and the menu closes; a repository is
-- toggled and the menu stays; Clear filter clears and closes. Returns whether the menu closed.
function M.menuPick(s: State, index: number): boolean
	local rows = M.menuRows(s)
	local row = rows[index]
	if not row then return false end
	s.menuCursor = index
	if s.menu == "sort" then
		M.setSort(s, M.SORTS[index].id)
		M.closeMenu(s)
		return true
	elseif s.menu == "repositories" then
		if row.kind == "clear" then
			M.clearRepositories(s)
			M.closeMenu(s)
			return true
		end
		M.toggleRepository(s, s.board.repositories[index].repo)
		return false
	elseif s.menu == "agent" and s.agent then
		local model = s.agent.models[index]
		s.agent.model = model.selector
		if #model.efforts == 0 then
			s.agent.effort = nil
		elseif not s.agent.effort or not table.find(model.efforts, s.agent.effort) then
			s.agent.effort = if table.find(model.efforts, "high") then "high" else model.efforts[1]
		end
		M.closeMenu(s)
		return true
	end
	return false
end

-- The alternative the open "actions" menu has highlighted at `index`.
function M.actionAt(s: State, index: number): CardAction?
	local card = M.selectedCard(s)
	if s.menu == "actions" and card then return card.more[index] end
	return nil
end

-- The model button's text: the model and effort, or what the button is for before the agent is found.
function M.agentLabel(s: State): string
	local agent = s.agent
	if not agent then return "Agent model" end
	local name = string.match(agent.model, "[^/]+$") or agent.model
	return if agent.effort then name .. " · " .. agent.effort else name
end

return M
