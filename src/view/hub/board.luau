--!strict
-- The hub page: header (title, search, freshness, agent model), the tab row, the board's columns, the
-- Inactive fold and the hint bar. Everything it draws was decided by `State.project`.
local Card = require("./card")
local Fields = require("../../text-field")
local Help = require("./help")
local Hints = require("./hints")
local Link = require("./link")
local Menus = require("./menus")
local Model = require("../../hub/model")
local Paths = require("./paths")
local State = require("../../hub/state")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

local LABELS: { [Model.Column]: string } = {
	needs_fixes = "Needs fixes", in_review = "In review", ready = "Ready to merge", inactive = "Inactive",
	to_review = "To review", waiting_on_author = "Waiting on author", approved = "Approved",
}
local EMPTY: { [Model.Column]: string } = {
	needs_fixes = "No pull requests need fixes.", in_review = "No pull requests in review.",
	ready = "No pull requests ready to merge.", to_review = "No pull requests to review.",
	waiting_on_author = "No pull requests waiting on their authors.", approved = "No approved pull requests.",
}

local M = {}

local function rootClass(s: State.State): string
	return "gp-root gp-hub" .. (if s.narrow then " gp-hub-narrow" else "") .. (if s.keyed then "" else " gp-soft")
end

local function tabs(s: State.State): Node
	local items: { Node } = {}
	for _, tab in State.TABS do
		local count = if tab.id == "mine" then s.board.counts.mine else s.board.counts.review
		local kids: { Node } = { span("gp-hub-tab-label", tab.label) }
		if count > 0 then table.insert(kids, span("gp-hub-pill", tostring(count))) end
		table.insert(items, el("span", { class = "gp-hub-tab" .. (if tab.id == s.tab then " gp-hub-tab-on" else ""), key = tab.id, actions = { click = "hub-tab=" .. tab.id } }, kids))
	end
	return el("div", { class = "gp-hub-tabs", key = "strip" }, items)
end

local function control(key: string, open: boolean, active: boolean, label: Node, menu: string): Node
	return el("span", {
		class = "gp-hub-ctl" .. (if open then " gp-hub-ctl-open" else "") .. (if active then " gp-hub-ctl-act" else ""),
		key = key, actions = { click = "hub-menu=" .. menu },
	}, { label, Ui.icon("chev") })
end

local function controls(s: State.State): Node
	local chosen: { string } = {}
	for _, option in s.board.repositories do
		if option.on then table.insert(chosen, string.match(option.repo, "[^/]+$") :: string) end
	end
	local repos = if #chosen == 0 then span("gp-hub-ctl-label", "All repositories")
		elseif #chosen == 1 then span("gp-hub-ctl-label gp-hub-ctl-strong", chosen[1])
		else span("gp-hub-ctl-label gp-hub-ctl-strong", #chosen .. " repositories")
	local sortName = ""
	for _, sort in State.SORTS do
		if sort.id == s.sort then sortName = sort.label end
	end
	local sort = el("span", { class = "gp-hub-ctl-label" }, { span("gp-hub-ctl-dim", "Sort:"), span("gp-hub-ctl-strong", sortName) })
	return el("div", { class = "gp-hub-ctls", key = "ctls" }, {
		control("repos", s.menu == "repositories", #chosen > 0, repos, "repositories"),
		control("sort", s.menu == "sort", false, sort, "sort"),
	})
end

-- Next up: one quiet line above the board. Position while walking, count at rest; split view drops the repo and count.
local function nextUp(s: State.State): Node?
	local next, card = s.board.nextUp, State.nextCard(s)
	if not next or not card then return nil end
	local pr = card.pr
	local kids: { Node } = { span("gp-hub-up-l", "Next up") }
	if card.chips[1] then table.insert(kids, Card.chip(card.chips[1])) end
	table.insert(kids, span("gp-hub-up-t", pr.title))
	if not s.narrow then
		local count = if s.walking then next.index .. " of " .. next.total else next.total .. " left"
		table.insert(kids, span("gp-hub-up-m", (string.match(pr.repo, "[^/]+$") :: string) .. " #" .. pr.number .. " · " .. count))
	end
	table.insert(kids, el("span", { class = "gp-btn gp-btn-sm gp-hub-up-go", key = "go", actions = { click = "hub-next" } }, { span("gp-hub-up-gol", "Go"), Ui.keys(".") }))
	return el("div", { class = "gp-hub-up", key = "up", actions = { click = "hub-next" } }, kids)
end

local function header(s: State.State): Node
	local searching = s.mode == "search"
	local search = el("div", { class = "gp-sr-box gp-hub-search" .. (if searching then " gp-hub-search-on" else ""), key = "search", actions = { click = "hub-search" } }, {
		Ui.icon("search"),
		Fields.node(s.search, "field", "Search pull requests"),
		Ui.keys("/"),
	})
	local fresh: { Node } = {}
	if s.refreshedAt then
		table.insert(fresh, span("gp-hub-fresh", "Updated " .. Model.ago(s.refreshedAt, s.now)))
	elseif s.loading then
		table.insert(fresh, span("gp-hub-fresh", "Loading…"))
	end
	table.insert(fresh, el("span", { class = "gp-hub-ctl" .. (if s.menu == "agent" then " gp-hub-ctl-open" else ""), key = "agent", actions = { click = "hub-menu=agent" } }, {
		el("span", { class = "gp-hub-ctl-label" }, if s.agent then { span("gp-hub-ctl-dim", "Agent:"), span("gp-hub-ctl-strong", State.agentLabel(s)) } else { span("gp-hub-ctl-strong", State.agentLabel(s)) }),
		Ui.icon("chev"),
	}))
	local up = nextUp(s)
	local rows: { Node } = {
		el("div", { class = "gp-hub-top", key = "top" }, {
			el("span", { class = "gp-hub-title", key = "title", text = "Pull requests" }),
			search,
			Ui.spacer(),
			el("span", { class = "gp-hub-fresh-row", key = "fresh" }, fresh),
		}),
		el("div", { class = "gp-hub-tabrow", key = "tabs" }, { tabs(s), Ui.spacer(), controls(s) }),
	}
	-- Inside the sticky header, so the position stays in view while walking.
	if up then table.insert(rows, up) end
	return el("div", { class = "gp-header gp-hub-head", key = "header" }, rows)
end

-- Cards under the small repository heading each run of one repository gets when the board is sorted by repository.
local function cards(s: State.State, list: { State.Card }): { Node }
	local out: { Node } = {}
	local last = ""
	for _, card in list do
		if s.sort == "repository" and card.pr.repo ~= last then
			last = card.pr.repo
			local count = 0
			for _, other in list do
				if other.pr.repo == last then count += 1 end
			end
			table.insert(out, el("div", { class = "gp-hub-repo", key = "h_" .. Paths.cardKey(last) }, {
				span("gp-hub-repo-name", string.match(last, "[^/]+$") :: string),
				span("gp-hub-repo-n", tostring(count)),
			}))
		end
		table.insert(out, Card.view(card, s.now))
	end
	return out
end

local function columnClass(column: Model.Column, tab: Model.Tab): string
	if column == "needs_fixes" then return "gp-hub-col-act gp-hub-col-bad" end
	if column == "to_review" then return "gp-hub-col-act gp-hub-col-info" end
	if column == "ready" or column == "approved" then return "gp-hub-col-done" end
	return "gp-hub-col-wait"
end

local function emptyText(column: Model.Column): string
	return EMPTY[column]
end

local function columns(s: State.State): Node
	local out: { Node } = {}
	for _, entry in s.board.columns do
		local kids: { Node } = {
			el("div", { class = "gp-hub-colhead", key = "head" }, {
				span("gp-hub-colname", LABELS[entry.column]),
				span("gp-hub-colcount" .. (if #entry.cards == 0 then " gp-hub-colcount-zero" else ""), tostring(#entry.cards)),
			}),
		}
		if entry.column == "to_review" then table.insert(kids, Link.view(s)) end
		if #entry.cards == 0 then
			table.insert(kids, span("gp-hub-empty", emptyText(entry.column)))
		else
			for _, node in cards(s, entry.cards) do table.insert(kids, node) end
		end
		table.insert(out, el("div", { class = "gp-hub-col " .. columnClass(entry.column, s.tab), key = Paths.columnKey(entry.column) }, kids))
	end
	return el("div", { class = "gp-hub-board", key = "board" }, out)
end

local function fold(s: State.State, motion: Ui.Motion): Node?
	local list = s.board.inactive
	if #list == 0 then return nil end
	local open = s.board.open.inactive
	local kids: { Node } = {
		el("div", { class = "gp-hub-foldhead", key = "head", actions = { click = "hub-fold=inactive" } }, {
			Ui.caret(open),
			span("gp-panel-h", "Inactive"),
			span("gp-hub-colcount", tostring(#list)),
			span("gp-hub-foldnote", "Drafts and pull requests with no activity for 7 days"),
			Ui.spacer(),
			Ui.keys("I"),
		}),
	}
	if open then
		local enter = Ui.entering(motion, "fold:inactive", "gp-enter-panel")
		table.insert(kids, el("div", { class = "gp-hub-foldrows " .. enter, key = "rows" }, cards(s, list)))
	end
	return el("div", { class = "gp-hub-fold", key = "fold" }, kids)
end

-- One Recently opened row: repository and number, the title with its author under it, and when it was opened.
local function recentRow(s: State.State, opened: State.Opened): Node
	local key = State.recentKey(opened)
	local name = (string.match(opened.repo, "[^/]+$") :: string) .. " #" .. opened.number
	local main: { Node } = { span("gp-sr-text gp-hub-rc-title", if opened.title ~= "" then opened.title else name) }
	if opened.author ~= "" then table.insert(main, span("gp-sr-sub", "@" .. opened.author)) end
	return el("div", {
		class = "gp-sr-row gp-hub-rc" .. (if s.selected == key then " gp-sr-row-on" else ""), key = Paths.recentKey(key),
		actions = { click = "hub-select=" .. key, dblclick = "hub-open=" .. key },
	}, {
		span("gp-hub-rc-ref", name),
		el("span", { class = "gp-hub-rc-main" }, main),
		Ui.spacer(),
		span("gp-hub-rc-when", Model.ago(opened.at, s.now)),
	})
end

-- The fold under Review requests: pull requests opened from any repo, newest first.
local function recentFold(s: State.State, motion: Ui.Motion): Node?
	local list = s.board.recent
	if #list == 0 then return nil end
	local open = s.board.open.recent
	local kids: { Node } = {
		el("div", { class = "gp-hub-foldhead", key = "head", actions = { click = "hub-fold=recent" } }, {
			Ui.caret(open),
			span("gp-panel-h", "Recently opened"),
			span("gp-hub-colcount", tostring(#list)),
			span("gp-hub-foldnote", "Pull requests you opened, from any repository"),
			Ui.spacer(),
			Ui.keys("R"),
		}),
	}
	if open then
		local rows: { Node } = {}
		for _, opened in list do table.insert(rows, recentRow(s, opened)) end
		local enter = Ui.entering(motion, "fold:recent", "gp-enter-panel")
		table.insert(kids, el("div", { class = "gp-hub-rcrows " .. enter, key = "rows" }, rows))
	end
	return el("div", { class = "gp-hub-fold", key = "recent" }, kids)
end

local function body(s: State.State, motion: Ui.Motion): Node
	local kids: { Node } = {}
	if s.error then
		table.insert(kids, span("gp-hub-error", "Couldn't load pull requests: " .. s.error.message))
	end
	-- With no columns to hold it, the add field still shows on Review requests, above the message, at the same path.
	local function message(text: string)
		local note = span("gp-hub-empty", text)
		if s.tab ~= "review" then return table.insert(kids, note) end
		local column = el("div", { class = "gp-hub-col gp-hub-col-act gp-hub-col-info", key = Paths.columnKey("to_review") }, { Link.view(s), note })
		table.insert(kids, el("div", { class = "gp-hub-board", key = "board" }, { column }))
	end
	if s.board.empty and s.loading then
		message("Loading pull requests…")
	else
		if s.board.empty and (s.search.text ~= "" or s.repositories ~= nil) then
			message("No pull requests match the search or filter.")
		else
			table.insert(kids, columns(s))
			local inactive = fold(s, motion)
			if inactive then table.insert(kids, inactive) end
			local recent = recentFold(s, motion)
			if recent then table.insert(kids, recent) end
		end
	end
	return el("div", { class = "gp-hub-body", key = "body" }, kids)
end

function M.view(s: State.State, motion: Ui.Motion): Node
	return el("div", {}, { el("div", { class = rootClass(s), key = "hub" }, { header(s), body(s, motion), Hints.view(s) }) })
end

-- The layer: while a menu or the key panel is open, a scrim that closes it on a click outside, and the overlay.
function M.layer(s: State.State): Node?
	if s.mode == "menu" and s.menu then
		return el("div", {}, { el("div", { class = "gp-md-scrim", key = "scrim", actions = { click = "hub-menu-close" } }), Menus.view(s) })
	elseif s.mode == "help" then
		return el("div", {}, { el("div", { class = "gp-md-scrim", key = "scrim", actions = { click = "hub-help-close" } }), Help.view(s.narrow) })
	end
	return nil
end

return M
