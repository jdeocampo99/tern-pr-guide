--!strict
local Model = require("../src/hub/model")
local Cases: any = require("../fixtures/hub/cases")

local NOW: number = Cases.asOf
local COLUMNS = { "needs_fixes", "in_review", "ready", "inactive", "to_review", "waiting_on_author", "approved" }
local SORTS = { "repository", "priority", "newest", "oldest", "smallest" }

local byKey: { [string]: any } = {}
for _, pr in Cases.prs do byKey[pr.key] = pr end

local function join(list: { any }): string
	return table.concat(list :: { string }, ",")
end

local function keysOf(prs: { any }): { string }
	local out = {}
	for _, pr in prs do table.insert(out, pr.key) end
	return out
end

local function columnOf(key: string): string
	return Model.classify(byKey[key], NOW)
end

return function()
	-- The clock is frozen in the fixture, not read.
	assert(Cases.asOf == Model.epoch(Cases.asOfIso), "asOf matches asOfIso")
	assert(Cases.asOf == 1791547200)

	-- Time helpers.
	assert(Model.epoch("1970-01-01T00:00:00Z") == 0)
	assert(Model.epoch("2026-10-09T12:00:00Z") == 1791547200)
	assert(Model.epoch("not a time") == nil)
	assert(Model.ago("2026-10-09T10:00:00Z", NOW) == "2h ago")
	assert(Model.ago("2026-10-09T11:59:30Z", NOW) == "just now")
	assert(Model.ago("2026-10-02T12:00:00Z", NOW) == "1w ago")
	assert(Model.ago("garbage", NOW) == "")

	-- Every fixture key lands in its expected column, with its expected reasons.
	local count = 0
	for _, pr in Cases.prs do
		count += 1
		local expected = Cases.columns[pr.key]
		assert(expected ~= nil, "no expected column for " .. pr.key)
		local placement = Model.placement(pr, NOW)
		assert(placement.column == expected, pr.key .. " is in " .. placement.column .. ", expected " .. expected)
		assert(Model.classify(pr, NOW) == expected)
		local tab = if pr.role == "mine" then "mine" else "review"
		assert(placement.tab == tab, pr.key .. " is on the wrong tab")
		local wantReasons = Cases.reasons[pr.key] or {}
		assert(join(placement.reasons) == join(wantReasons), pr.key .. " reasons: " .. join(placement.reasons))
		assert(join(Model.reasons(pr, NOW)) == join(wantReasons))
	end
	for key in Cases.columns do assert(byKey[key] ~= nil, "expected column for unknown key " .. key) end
	assert(count == 45, "fixture has 45 cases, got " .. count)

	-- Every column's order, for each sort, and nothing missing or duplicated.
	for _, sort in SORTS do
		local seen: { [string]: boolean } = {}
		for _, column in COLUMNS do
			local want = Cases.orders[sort][column]
			assert(want ~= nil, "no expected order for " .. sort .. "/" .. column)
			local got = keysOf(Model.order(Cases.prs, column, sort, NOW))
			assert(join(got) == join(want), sort .. "/" .. column .. ": got " .. join(got) .. " expected " .. join(want))
			for _, key in got do
				assert(not seen[key], key .. " appears twice under " .. sort)
				seen[key] = true
			end
		end
		for _, pr in Cases.prs do assert(seen[pr.key], pr.key .. " is in no column under " .. sort) end
	end

	-- Input order doesn't change the result.
	local reversed = {}
	for i = #Cases.prs, 1, -1 do table.insert(reversed, Cases.prs[i]) end
	for _, sort in SORTS do
		for _, column in COLUMNS do
			assert(join(keysOf(Model.order(reversed, column, sort, NOW))) == join(Cases.orders[sort][column]))
		end
	end

	-- Next up.
	local queue = Model.queue(Cases.prs, NOW)
	assert(join(keysOf(queue)) == join(Cases.nextUp), "next up: " .. join(keysOf(queue)))
	assert(#queue == 20)
	assert(queue[1].column == "needs_fixes" and queue[1].reason == "merge_failed" and queue[1].tab == "mine")
	assert(queue[4].key == "acme/web#302" and queue[4].column == "to_review" and queue[4].reason == nil and queue[4].tab == "review")

	-- The 16-conflict case: of 16 conflicted PRs, only the 6 active, non-draft ones reach Needs fixes.
	local conflicted, needFixes, inactive = 0, 0, 0
	for _, pr in Cases.prs do
		if pr.repo == "acme/mono" then
			conflicted += 1
			assert(pr.conflicts)
			if columnOf(pr.key) == "needs_fixes" then needFixes += 1 end
			if columnOf(pr.key) == "inactive" then inactive += 1 end
		end
	end
	assert(conflicted == 16 and needFixes == 6 and inactive == 10)
	assert(columnOf("acme/mono#206") == "needs_fixes") -- active 5 days ago
	assert(columnOf("acme/mono#212") == "inactive") -- stale
	assert(columnOf("acme/mono#214") == "inactive") -- draft, active today
	-- The edge of the window: exactly 7 days is still active, a second more is not.
	local edge = table.clone(byKey["acme/mono#201"])
	edge.lastActivityAt = "2026-10-02T12:00:00Z"
	assert(Model.classify(edge, NOW) == "needs_fixes")
	edge.lastActivityAt = "2026-10-02T11:59:59Z"
	assert(Model.classify(edge, NOW) == "inactive")
	assert(Model.ACTIVE_DAYS == 7)

	-- A bot review, an LGTM comment and an approval with leftover threads each stay out of Needs fixes.
	assert(columnOf("acme/api#106") == "in_review") -- bot review and bot thread
	assert(columnOf("acme/api#107") == "in_review") -- "LGTM"
	assert(columnOf("acme/api#108") == "ready") -- approved by the thread's author
	assert(columnOf("acme/api#120") == "in_review") -- threads not fetched
	assert(columnOf("acme/api#121") == "in_review") -- the viewer's own thread
	assert(#Model.reasons(byKey["acme/api#106"], NOW) == 0)
	-- Feedback does count from a person: changes requested, or a thread by someone who didn't approve.
	assert(columnOf("acme/web#103") == "needs_fixes")
	assert(columnOf("acme/api#118") == "needs_fixes")
	assert(columnOf("acme/api#119") == "needs_fixes")
	-- An approval doesn't clear a failing check or a conflict.
	assert(columnOf("acme/web#111") == "needs_fixes")
	assert(join(Model.reasons(byKey["acme/api#112"], NOW)) == "checks,conflict")
	-- A bot's changes_requested isn't feedback either.
	local botBlock = table.clone(byKey["acme/api#106"])
	botBlock.reviews = table.clone(botBlock.reviews)
	botBlock.reviews.latest = { { author = "copilot-bot", bot = true, verdict = "changes_requested", at = "2026-10-08T00:00:00Z", oid = "x" } }
	assert(Model.classify(botBlock, NOW) == "in_review")
	assert(Model.botFeedback(botBlock))
	assert(Model.botFeedback(byKey["acme/api#106"]))
	assert(not Model.botFeedback(byKey["acme/web#103"]))

	-- mergeFailure with activity in the last 7 days reaches Needs fixes; the same PR older than 7 days is Inactive.
	assert(byKey["acme/web#101"].mergeFailure ~= nil and columnOf("acme/web#101") == "needs_fixes")
	assert(byKey["acme/web#102"].mergeFailure ~= nil and columnOf("acme/web#102") == "inactive")
	assert(join(Model.reasons(byKey["acme/web#101"], NOW)) == "merge_failed")
	assert(join(Model.reasons(byKey["acme/web#102"], NOW)) == "")
	-- Drafts are Inactive however broken.
	assert(columnOf("acme/web#113") == "inactive")

	-- Review tab.
	assert(columnOf("acme/web#301") == "to_review") -- requested
	assert(columnOf("acme/web#302") == "to_review") -- re-review: the viewer approved an older commit
	assert(columnOf("acme/web#303") == "to_review") -- added by link
	assert(columnOf("acme/web#304") == "waiting_on_author") -- the viewer requested changes
	assert(columnOf("acme/web#305") == "waiting_on_author") -- the viewer commented
	assert(columnOf("acme/web#306") == "approved") -- approved the current head
	assert(columnOf("acme/api#307") == "to_review") -- requested again after a comment

	-- Mergeable: ready, not behind, nothing pending.
	assert(Model.mergeable(byKey["acme/api#109"]))
	assert(not Model.mergeable(byKey["acme/api#115"]))
	assert(not Model.mergeable(byKey["acme/web#111"]))
	local behind = table.clone(byKey["acme/api#109"])
	behind.behind = true
	assert(not Model.mergeable(behind))
	local pending = table.clone(byKey["acme/api#109"])
	pending.pending = { method = "queue", at = "2026-10-09T11:00:00Z" }
	assert(not Model.mergeable(pending))

	-- Size and search.
	assert(Model.size(byKey["acme/web#101"]) == 50)
	assert(Model.size(byKey["acme/api#110"]) == 400)
	assert(Model.visible(byKey["acme/web#101"], { search = "" }))
	assert(Model.visible(byKey["acme/web#101"], { search = "#101" }))
	assert(Model.visible(byKey["acme/web#101"], { search = "  PROMO CODE " }))
	assert(Model.visible(byKey["acme/web#101"], { search = "main" }))
	assert(Model.visible(byKey["acme/web#101"], { search = "jubby" }))
	assert(not Model.visible(byKey["acme/web#101"], { search = "#102" }))
	assert(Model.visible(byKey["acme/web#101"], { search = "", repositories = { ["acme/web"] = true } }))
	assert(not Model.visible(byKey["acme/web#101"], { search = "", repositories = { ["acme/api"] = true } }))

	-- Refreshes: the fixture's expected arrivals follow from the rules.
	assert(#Cases.refreshes == 8)
	for _, refresh in Cases.refreshes do
		local before: { [string]: string } = {}
		if refresh.previous then
			for _, pr in refresh.previous do before[pr.key] = Model.classify(pr, NOW) end
		end
		local rings, good, toasting = {}, {}, {}
		for _, pr in refresh.prs do
			local now = Model.classify(pr, NOW)
			local was = before[pr.key]
			if refresh.previous and was ~= now and not refresh.suppressed[pr.key] then
				if now == "needs_fixes" then
					table.insert(rings, pr.key)
					for _, reason in Model.reasons(pr, NOW) do
						if reason ~= "conflict" then
							table.insert(toasting, pr.key)
							break
						end
					end
				elseif now == "ready" or now == "approved" then
					table.insert(good, pr.key)
				end
			end
		end
		assert(join(rings) == join(refresh.rings), refresh.name .. ": rings " .. join(rings))
		assert(join(good) == join(refresh.good), refresh.name .. ": good " .. join(good))
		local toast: string? = nil
		if #toasting == 1 then
			toast = nil -- the single-PR text names the reason; checked below
		elseif #toasting > 1 then
			toast = #toasting .. " pull requests need fixes"
		end
		if #toasting == 0 then
			assert(refresh.toast == nil, refresh.name .. ": no toast expected")
		elseif #toasting == 1 then
			assert(refresh.toast ~= nil and string.sub(refresh.toast, 1, 1) == "#", refresh.name .. ": one toast")
		else
			assert(refresh.toast == toast, refresh.name .. ": toast " .. tostring(toast))
		end
	end
	assert(Cases.refreshes[1].previous == nil and #Cases.refreshes[1].rings == 0 and Cases.refreshes[1].toast == nil)
	assert(Cases.refreshes[4].toast == "3 pull requests need fixes")
end
