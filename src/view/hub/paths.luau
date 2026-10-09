--!strict
-- Node ids of the hub page that the block scrolls to and menus anchor to. They follow the keys in board.luau.
local State = require("../../hub/state")
local Text = require("../../text")

local M = {}

M.ROOT = "main.hub"
M.searchField = M.ROOT .. ".header.top.search.field"
M.titleLabel = M.ROOT .. ".header.top.title"
M.agentButton = M.ROOT .. ".header.top.fresh.agent"
M.repositoriesButton = M.ROOT .. ".header.tabs.ctls.repos"
M.sortButton = M.ROOT .. ".header.tabs.ctls.sort"

-- The key of a card's node, unique on the board.
function M.cardKey(prKey: string): string
	return "c_" .. Text.keyOf(prKey)
end

function M.columnKey(column: string): string
	return "col_" .. column
end

-- The card's node: in its column, or in the Inactive fold.
function M.card(card: State.Card): string
	if card.column == "inactive" then return M.ROOT .. ".body.fold.rows." .. M.cardKey(card.pr.key) end
	return M.ROOT .. ".body.board." .. M.columnKey(card.column) .. "." .. M.cardKey(card.pr.key)
end

-- The key of a Recently opened row's node (`key` is State.recentKey).
function M.recentKey(key: string): string
	return "rc_" .. Text.keyOf(key)
end

-- A Recently opened row's node.
function M.recentRow(key: string): string
	return M.ROOT .. ".body.recent.rows." .. M.recentKey(key)
end

-- The ▾ beside a selected card's split button, which the card's menu anchors to.
function M.moreButton(card: State.Card): string
	return M.card(card) .. ".body.meta.acts.sb.more"
end

return M
