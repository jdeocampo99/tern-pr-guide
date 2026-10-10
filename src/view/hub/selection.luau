--!strict
-- The selection bar at the top of Ready to merge or the Inactive rows: "2 selected", its one action and Clear.
-- After M or X it becomes the confirm: the question, at most five titles, how they merge, then Confirm and Cancel.
local State = require("../../hub/state")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

local M = {}

local function button(label: string, key: string, action: string, filled: boolean, id: string): Node
	return el("span", { class = "gp-sb", key = id }, {
		el("span", { class = "gp-sb-main" .. (if filled then " gp-sb-confirm" else ""), key = "main", actions = { click = action } }, { span("gp-sb-label", label), Ui.keys(key) }),
	})
end

local function confirm(sel: State.Selection, ask: State.BatchConfirm): Node
	local list: { Node } = {}
	for i, row in ask.rows do
		table.insert(list, el("div", { class = "gp-sel-row", key = "r" .. i }, { span("gp-sel-ref", row.ref), span("gp-sel-title", row.title) }))
	end
	if ask.more > 0 then table.insert(list, span("gp-sel-more", "and " .. ask.more .. " more")) end
	local lines: { Node } = {}
	for i, line in ask.lines do table.insert(lines, el("span", { class = "gp-sel-how", key = "l" .. i, text = line })) end
	return el("div", { class = "gp-sel gp-sel-ask", key = "selection" }, {
		span("gp-sel-q", ask.question),
		el("div", { class = "gp-sel-list", key = "list" }, list),
		el("div", { class = "gp-sel-hows", key = "hows" }, lines),
		el("span", { class = "gp-sel-acts", key = "acts" }, {
			button(ask.go, "⌘⏎", ask.act, true, "go"),
			button("Cancel", "esc", "hub-confirm-cancel", false, "cancel"),
		}),
	})
end

function M.view(sel: State.Selection): Node
	if sel.confirm then return confirm(sel, sel.confirm) end
	return el("div", { class = "gp-sel", key = "selection" }, {
		span("gp-sel-n", sel.count .. " selected"),
		el("span", { class = "gp-sel-acts", key = "acts" }, {
			button(sel.verb .. " " .. sel.count, sel.key, sel.act, true, "go"),
			button("Clear", "esc", "hub-marks-clear", false, "clear"),
		}),
	})
end

return M
