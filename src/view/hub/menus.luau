--!strict
-- The hub's menus (repositories, sort, agent model, a card's other actions) as Tern overlays under their
-- buttons. A menu opened by a key draws without animation: Tern's overlay pops only for the mouse.
local Fields = require("../../text-field")
local Paths = require("./paths")
local State = require("../../hub/state")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

local M = {}

local TITLES: { [string]: string } = {
	repositories = "Filter by repository",
	sort = "Sort by",
	agent = "Agent model",
	actions = "More actions",
	merge = "Merge method",
}

local function anchorOf(s: State.State): string
	if s.menu == "repositories" then return Paths.repositoriesButton end
	if s.menu == "sort" then return Paths.sortButton end
	if s.menu == "agent" then return Paths.agentButton end
	local card = State.selectedCard(s)
	return if card then Paths.moreButton(card) else Paths.titleLabel
end

local function rowNode(s: State.State, row: State.MenuRow, index: number): Node
	local kids: { Node } = {}
	if row.kind == "check" then
		table.insert(kids, el("span", { class = "gp-hm-box" .. (if row.on then " gp-hm-box-on" else "") }, if row.on then { Ui.icon("check") } else nil))
	elseif row.kind == "choice" then
		table.insert(kids, el("span", { class = "gp-hm-tick" }, if row.on then { Ui.icon("check") } else nil))
	end
	table.insert(kids, span("gp-hm-label", row.label))
	table.insert(kids, Ui.spacer())
	if row.count then table.insert(kids, span("gp-hm-count", tostring(row.count))) end
	if row.sub then table.insert(kids, span("gp-hm-sub", row.sub)) end
	return el("div", {
		class = "gp-md-row gp-hm-row" .. (if index == s.menuCursor then " gp-md-row-on" else "") .. (if row.kind == "clear" then " gp-hm-clear" else ""),
		key = "r" .. index, actions = { click = "hub-menu-pick=" .. index },
	}, kids)
end

-- Effort levels of the highlighted model, as one segmented control.
local function efforts(s: State.State): Node?
	local levels, current = State.agentEfforts(s)
	if s.menu ~= "agent" then return nil end
	if #levels == 0 then return el("div", { class = "gp-md-foot", key = "efforts" }, { span("gp-md-none", "This model has no effort setting") }) end
	local segments: { Node } = {}
	for _, level in levels do
		table.insert(segments, el("span", {
			class = "gp-md-seg" .. (if level == current then " gp-md-seg-on" else ""),
			key = "e_" .. level, text = level, actions = { click = "hub-menu-effort-set=" .. level },
		}))
	end
	return el("div", { class = "gp-md-foot", key = "efforts" }, {
		span("gp-md-label", "Effort"),
		el("div", { class = "gp-md-segs" }, segments),
		Ui.spacer(),
		Ui.keys("← →"),
	})
end

-- The merge menu's foot: where the setting came from, or the field a comment or label method asks for.
local function mergeFoot(s: State.State): Node?
	if s.menu ~= "merge" then return nil end
	local edit = s.methodEdit
	if edit then
		local what = if edit.kind == "comment" then "Command" else "Label"
		local placeholder = if edit.kind == "comment" then "/merge | /cancel" else "ready-to-merge"
		return el("div", { class = "gp-md-foot gp-hm-edit", key = "edit" }, {
			span("gp-md-label", what),
			el("div", { class = "gp-sr-box gp-hm-field", key = "box" }, { Fields.node(edit.field, "field", placeholder) }),
			Ui.keys("⏎"),
		})
	end
	local source = State.mergeSource(s)
	if source == nil then return nil end
	return el("div", { class = "gp-md-foot", key = "source" }, { span("gp-md-label", source) })
end

function M.view(s: State.State): Node
	local rows: { Node } = {}
	for index, row in State.menuRows(s) do table.insert(rows, rowNode(s, row, index)) end
	if #rows == 0 then
		local empty = if s.menu == "agent" then "Couldn't find the agent: no models to choose from." else "No options."
		table.insert(rows, span("gp-md-empty", empty))
	end
	local kids: { Node } = {
		span("gp-hm-head", TITLES[s.menu :: string]),
		el("div", { class = "gp-md-list gp-hm-list", key = "list" }, rows),
	}
	local foot = efforts(s) or mergeFoot(s)
	if foot then table.insert(kids, foot) end
	local body = el("div", { class = "gp-md gp-hm" .. (if s.keyed then "" else " gp-soft"), key = "body" }, kids)
	return { k = "overlay", p = { key = "menu", role = "gp.hubmenu", aria = TITLES[s.menu :: string], anchor = { node = anchorOf(s), side = "below" }, size = "md" }, c = { body } } :: any
end

return M
