--!strict
-- The `?` panel: every key the hub answers to, in the order a session goes: move, act on a card, run the board.
local Paths = require("./paths")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

type Group = { title: string, keys: { { string } } } -- a key row is { keys, label, more keys? }

local GROUPS: { Group } = {
	{ title = "Move", keys = {
		{ "h j k l", "Move between cards", "← ↑ ↓ →" },
		{ "⏎", "Open the card" },
		{ "T", "Switch tab" },
		{ "I", "Show or hide Inactive" },
	} },
	{ title = "The selected card", keys = {
		{ "A", "Fix with agent, or Summarize" },
		{ "⇧A", "Summarize feedback" },
		{ "C", "Copy link" },
		{ "M", "Merge" },
		{ "U", "Update branch" },
		{ ",", "Merge method" },
		{ "X", "Remove from Review requests" },
	} },
	{ title = "The board", keys = {
		{ "/", "Search" },
		{ "F", "Filter by repository" },
		{ "S", "Sort" },
		{ "⇧M", "Agent model" },
		{ "j k", "Move in a menu" },
		{ "Space", "Choose in a menu" },
		{ "Esc", "Clear or close" },
		{ "?", "All shortcuts" },
	} },
}

local M = {}

function M.view(): Node
	local cols: { Node } = {}
	for _, group in GROUPS do
		local rows: { Node } = { span("gp-panel-h", group.title) }
		for _, key in group.keys do
			local row: { Node } = { el("span", { class = "gp-hh-keys" }, { Ui.keys(key[1]) }), span("gp-keylabel", key[2]) }
			if key[3] then table.insert(row, Ui.keys(key[3])) end
			table.insert(rows, el("div", { class = "gp-keyrow" }, row))
		end
		table.insert(cols, el("div", { class = "gp-keycol" }, rows))
	end
	local body = el("div", { class = "gp-hh", key = "body" }, cols)
	return { k = "overlay", p = { key = "help", role = "gp.hubhelp", aria = "All shortcuts", anchor = { node = Paths.titleLabel, side = "below" }, size = "lg" }, c = { body } } :: any
end

return M
