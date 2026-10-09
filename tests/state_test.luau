--!strict
local State = require("../src/hub/state")
local Cases: any = require("../fixtures/hub/cases")

local NOW: number = Cases.asOf
local SORTS = { "repository", "priority", "newest", "oldest", "smallest" }

local function join(list: { string }): string
	return table.concat(list, ",")
end

local function keysOf(cards: { State.Card }): { string }
	local out = {}
	for _, card in cards do table.insert(out, card.pr.key) end
	return out
end

local function column(s: State.State, id: string): { string }
	for _, entry in s.board.columns do
		if entry.column == id then return keysOf(entry.cards) end
	end
	error("no column " .. id)
end

local function fresh(saved: any?): State.State
	return State.new(Cases.prs, NOW, saved)
end

return function()
	-- Every fixture key lands in its expected column and order, for each sort and both tabs.
	for _, sort in SORTS do
		local expected = Cases.orders[sort]
		for _, tab in { "mine", "review" } do
			local s = fresh({ tab = tab, sort = sort })
			assert(s.board.tab == tab and s.sort == sort)
			for _, entry in s.board.columns do
				local want = join(expected[entry.column])
				assert(join(keysOf(entry.cards)) == want, sort .. "/" .. entry.column .. ": " .. join(keysOf(entry.cards)))
				for _, card in entry.cards do
					assert(card.column == entry.column and Cases.columns[card.pr.key] == entry.column)
				end
			end
			if tab == "mine" then
				assert(join(keysOf(s.board.inactive)) == join(expected.inactive), sort .. "/inactive")
			else
				assert(#s.board.inactive == 0)
			end
		end
	end

	-- Smallest first orders by additions + deletions (literal expectations).
	local smallest = fresh({ tab = "mine", sort = "smallest" })
	assert(join(column(smallest, "in_review")) == "acme/api#107,acme/api#106,acme/api#120,acme/api#121,acme/api#114,acme/api#115")
	assert(column(smallest, "needs_fixes")[1] == "acme/mono#201")

	-- Defaults, and the grid that h j k l walk.
	local s = fresh()
	assert(s.tab == "mine" and s.sort == "repository" and s.repositories == nil and s.mode == "board" and s.selected == nil)
	assert(#s.board.grid == 3 and join(s.board.grid[3]) == "acme/api#110,acme/api#108,acme/api#109")
	assert(#s.board.grid[1] == 15 and #s.board.columns[1].cards == 15)
	assert(s.board.empty == false)
	assert(s.board.open.inactive == false, "Inactive starts folded")
	assert(s.board.counts.mine == 15 and s.board.counts.review == 5, "blue counts are the your-turn columns")
	assert(State.mode(s) == "board")
	for _, card in s.board.columns[1].cards do assert(card.selected == false and card.main ~= nil) end

	-- Tab transitions: counts stay, columns and selection follow the tab.
	State.select(s, "acme/api#116")
	State.switchTab(s)
	assert(s.tab == "review" and s.board.tab == "review" and s.selected == nil)
	assert(join(column(s, "to_review")) == join(Cases.orders.repository.to_review))
	assert(s.board.counts.mine == 15 and s.board.counts.review == 5)
	assert(#s.board.inactive == 0)
	State.switchTab(s)
	assert(s.tab == "mine")
	State.setTab(s, "mine")
	assert(s.tab == "mine")

	-- Sort transitions.
	State.setSort(s, "smallest")
	assert(s.sort == "smallest" and column(s, "ready")[1] == "acme/api#109")
	State.setSort(s, "repository")
	assert(column(s, "ready")[1] == "acme/api#110")

	-- Repository filter: toggling narrows both the board and the counts; clearing restores.
	State.toggleRepository(s, "acme/api")
	assert(join(column(s, "needs_fixes")) == "acme/api#116,acme/api#118,acme/api#119,acme/api#105,acme/api#112")
	assert(s.board.counts.mine == 5 and s.board.counts.review == 2)
	assert(join(keysOf(s.board.inactive)) == "acme/api#122")
	assert(s.repositories ~= nil and (s.repositories :: any)["acme/api"] == true)
	State.toggleRepository(s, "acme/web")
	assert(s.board.counts.mine == 9)
	State.toggleRepository(s, "acme/web")
	State.toggleRepository(s, "acme/api")
	assert(s.repositories == nil and s.board.counts.mine == 15)
	State.toggleRepository(s, "acme/web")
	State.clearRepositories(s)
	assert(s.repositories == nil and #s.board.columns[1].cards == 15)
	-- The repository options: most pull requests first, ties by name.
	assert(s.board.repositories[1].repo == "acme/mono" and s.board.repositories[1].count == 16)
	assert(s.board.repositories[2].repo == "acme/api" and s.board.repositories[2].count == 15)
	assert(s.board.repositories[3].repo == "acme/web" and s.board.repositories[3].count == 6)

	-- Search: live, over "#n", title and repo; it opens Inactive for its matches and drops a selection it hides.
	State.select(s, "acme/api#116")
	State.setSearch(s, "#101")
	assert(join(column(s, "needs_fixes")) == "acme/web#101" and #column(s, "in_review") == 0)
	assert(s.selected == nil, "selection follows its card off the board")
	assert(s.board.counts.mine == 1 and s.board.counts.review == 0)
	State.setSearch(s, "acme/mono")
	assert(#column(s, "needs_fixes") == 6 and s.board.open.inactive == true and #s.board.inactive == 10)
	State.setSearch(s, "nothing matches this")
	assert(s.board.empty == true)
	State.setSearch(s, "")
	assert(s.board.empty == false and s.board.open.inactive == false)

	-- Search mode: typing is the search field's; Esc clears, Enter keeps the text.
	State.openSearch(s)
	assert(s.mode == "search")
	State.setSearch(s, "case 3")
	State.closeSearch(s, false)
	assert(s.mode == "board" and s.search.text == "case 3")
	State.openSearch(s)
	State.closeSearch(s, true)
	assert(s.mode == "board" and s.search.text == "" and #s.board.columns[1].cards == 15)

	-- Moving: nothing selected starts at the first card; columns keep their row; Inactive is entered from below.
	assert(State.move(s, "left") and s.selected == "acme/api#116")
	assert(State.move(s, "left") == false)
	assert(State.move(s, "up") == false)
	assert(State.move(s, "down") and s.selected == "acme/api#118")
	assert(State.selectedCard(s) ~= nil and (State.selectedCard(s) :: State.Card).selected)
	assert(State.move(s, "up") and s.selected == "acme/api#116")
	assert(State.move(s, "right") and s.selected == "acme/api#114")
	assert(State.move(s, "right") and s.selected == "acme/api#110")
	assert(State.move(s, "right") == false)
	assert(State.move(s, "down") and State.move(s, "down") and s.selected == "acme/api#109")
	assert(State.move(s, "down") == false, "Inactive is folded")
	State.toggleFold(s, "inactive")
	assert(s.board.open.inactive == true and s.folded.inactive == false)
	assert(State.move(s, "down") and s.selected == "acme/api#122")
	assert(State.move(s, "down") and s.selected == "acme/mono#216")
	assert(State.move(s, "up") and State.move(s, "up") and s.selected == "acme/web#104", "up from Inactive returns to the board")
	-- Right from a short row clamps to the last card of the next column.
	State.select(s, "acme/web#104")
	assert(State.move(s, "right") and s.selected == "acme/api#107")

	-- Menus.
	State.openMenu(s, "sort")
	assert(s.mode == "menu" and s.menu == "sort" and s.menuCursor == 1)
	local rows = State.menuRows(s)
	assert(#rows == 5 and rows[5].label == "Smallest first" and rows[1].on and not rows[5].on)
	State.menuMove(s, 1)
	State.menuMove(s, 10)
	assert(s.menuCursor == 5)
	State.menuMove(s, -10)
	assert(s.menuCursor == 1)
	assert(State.menuPick(s, 5) == true)
	assert(s.sort == "smallest" and s.menu == nil and s.mode == "board")
	State.openMenu(s, "sort")
	assert(s.menuCursor == 5, "the menu opens on the current choice")
	State.closeMenu(s)
	State.openMenu(s, "repositories")
	rows = State.menuRows(s)
	assert(#rows == 3 and rows[1].label == "mono" and rows[1].count == 16 and rows[1].kind == "check")
	assert(State.menuPick(s, 2) == false and s.menu == "repositories", "a repository toggles and the menu stays")
	assert(s.repositories ~= nil and (s.repositories :: any)["acme/api"] == true)
	rows = State.menuRows(s)
	assert(#rows == 4 and rows[4].kind == "clear")
	assert(State.menuPick(s, 4) == true and s.repositories == nil and s.menu == nil)
	State.openMenu(s, "agent")
	assert(#State.menuRows(s) == 0, "no agent found: no rows")
	State.closeMenu(s)

	-- The agent menu: model rows, efforts of the highlighted model, and picking.
	s.agent = {
		models = {
			{ selector = "anthropic/claude-opus", name = "claude-opus", efforts = { "low", "high" } },
			{ selector = "openai/gpt", name = "gpt", efforts = {} },
		},
		model = "anthropic/claude-opus", effort = "high",
	}
	assert(State.agentLabel(s) == "claude-opus · high")
	State.openMenu(s, "agent")
	assert(s.menuCursor == 1 and #State.menuRows(s) == 2 and State.menuRows(s)[1].sub == "anthropic")
	State.stepEffort(s, -1)
	assert((s.agent :: State.AgentChoice).effort == "low")
	State.stepEffort(s, -5)
	assert((s.agent :: State.AgentChoice).effort == "low")
	State.menuMove(s, 1)
	assert(select("#", State.agentEfforts(s)) == 2 and #(State.agentEfforts(s)) == 0)
	assert(State.menuPick(s, 2) and (s.agent :: State.AgentChoice).model == "openai/gpt" and (s.agent :: State.AgentChoice).effort == nil)
	assert(State.agentLabel(s) == "gpt")

	-- Help.
	State.openHelp(s)
	assert(s.mode == "help" and s.menu == nil)
	State.closeHelp(s)
	assert(s.mode == "board")

	-- What is saved comes back, and a bad save is ignored.
	State.setSort(s, "oldest")
	State.toggleRepository(s, "acme/web")
	State.setTab(s, "review")
	local saved = State.saved(s)
	assert(saved.tab == "review" and saved.sort == "oldest" and join(saved.repositories :: { string }) == "acme/web")
	local back = fresh(saved)
	assert(back.tab == "review" and back.sort == "oldest" and (back.repositories :: any)["acme/web"] == true)
	assert(join(column(back, "to_review")) == "acme/web#302,acme/web#303,acme/web#301")
	local bad = fresh({ tab = "x", sort = 3, repositories = "no", folded = { inactive = "no" } })
	assert(bad.tab == "mine" and bad.sort == "repository" and bad.repositories == nil and bad.folded.inactive == true)
	assert(fresh(nil).tab == "mine" and #State.new({}, NOW, nil).board.columns[1].cards == 0 and State.new({}, NOW, nil).board.empty)

	-- Card actions follow the spec's table.
	local cards = fresh().board
	local function mainOf(key: string, tab: string?): string
		local card = State.card(fresh({ tab = tab or "mine" }), key)
		assert(card ~= nil, key)
		return ((card :: State.Card).main or { label = "none" }).label
	end
	assert(cards.columns[1].cards[1].main and (cards.columns[1].cards[1].main :: State.CardAction).label == "Fix with agent")
	assert(mainOf("acme/api#114") == "Copy link" and mainOf("acme/api#110") == "Merge" and mainOf("acme/web#301", "review") == "Review")
	assert(mainOf("acme/api#122") == "none" and mainOf("acme/web#306", "review") == "none")
	assert(State.card(fresh(), "acme/api#103") == nil)
	local fixes = State.card(fresh(), "acme/web#103") :: State.Card
	assert(fixes.main and fixes.main.label == "Summarize" and fixes.main.key == "A", "feedback alone: A summarizes")
	local both = State.card(fresh(), "acme/api#116") :: State.Card
	assert(both.main and both.main.label == "Fix with agent" and #both.more == 1 and both.more[1].key == "⇧A")
	local added = State.card(fresh({ tab = "review" }), "acme/web#303") :: State.Card
	assert(added.main and added.main.label == "Review" and #added.more == 1 and added.more[1].label == "Remove from Review requests")

	-- Chip lines: one chip per job, then the first job's detail.
	local function chipsOf(key: string, tab: string?): (string, string?)
		local card = State.card(fresh({ tab = tab or "mine" }), key) :: State.Card
		local names = {}
		for _, chip in card.chips do table.insert(names, chip.text) end
		return join(names), card.detail
	end
	local names, detail = chipsOf("acme/api#116")
	assert(names == "Merge failed,Address changes,Fix checks,Resolve conflicts" and detail == "Removed from the merge queue: a required check failed")
	names, detail = chipsOf("acme/api#119")
	assert(names == "Reply" and detail == "1 unresolved comment")
	names, detail = chipsOf("acme/web#103")
	assert(names == "Address changes" and detail == "Changes requested by @bob")
	names, detail = chipsOf("acme/api#105")
	assert(names == "Resolve conflicts" and detail == "Conflicts with main")
	names, detail = chipsOf("acme/web#104")
	assert(names == "Fix checks" and detail == "1/4 checks failing")
	names, detail = chipsOf("acme/web#301", "review")
	assert(names == "Review" and detail == "@maria-k asked 2h ago")
	names, detail = chipsOf("acme/web#302", "review")
	assert(names == "Re-review" and detail == "New commits since you approved")
	names, detail = chipsOf("acme/web#303", "review")
	assert(names == "Review" and detail == "Added by you")
	names, detail = chipsOf("acme/web#304", "review")
	assert(names == "You requested changes" and detail == nil)
	names = chipsOf("acme/web#305", "review")
	assert(names == "You commented")
	names = chipsOf("acme/api#114")
	assert(names == "Waiting on checks")
	names = chipsOf("acme/api#106")
	assert(names == "Waiting on review")
	names = chipsOf("acme/api#110")
	assert(names == "", "done cards have no chip line")
end
