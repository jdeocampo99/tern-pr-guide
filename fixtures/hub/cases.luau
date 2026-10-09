--!strict
-- Normalized HubPR records for the rules, with the answers the rules must give.
-- Synthetic but shaped like docs/hub/queries/sample.json. Everything is relative to `asOf`:
-- active means activity within 7 days of it. Read by tests/model_test.luau and, later, by the fixture block (fixture=cases).

local VIEWER = "jubbydev"
local ASOF_ISO = "2026-10-09T12:00:00Z"
local ASOF = 1791547200 -- ASOF_ISO in seconds since the epoch

local function at(monthDay: string, hour: number?): string
	return string.format("2026-%sT%02d:00:00Z", monthDay, hour or 0)
end

local function review(author: string, verdict: string, oid: string?, bot: boolean?): any
	return { author = author, bot = bot or false, verdict = verdict, at = at("10-08"), oid = oid or "head" }
end

local FAILING = { state = "failing", passing = 3, failing = 1, pending = 0 }
local PASSING = { state = "passing", passing = 4, failing = 0, pending = 0 }
local PENDING = { state = "pending", passing = 2, failing = 0, pending = 1 }
local QUEUE_FAIL = { kind = "queue", reason = "Removed from the merge queue: a required check failed" }

-- Realistic titles, the long ones long enough to need truncation on a card.
local TITLES: { [number]: string } = {
	[101] = "Checkout: keep the promo code when the cart re-prices after a shipping change",
	[102] = "Search: highlight the matched part of each suggestion",
	[103] = "Settings: move notification preferences into their own page",
	[104] = "Quiz: accept both \"po\" and \"ho\" in polite answers",
	[105] = "Lessons API: paginate the unit list and return a cursor with every page of results",
	[106] = "Dark mode: fix the low-contrast hint text on cards",
	[107] = "Docs: the coordinator lifecycle, with a diagram",
	[108] = "Onboarding: pick a dialect before the placement quiz",
	[109] = "Analytics: drop the duplicate lesson_complete event",
	[110] = "Flashcards: keep the flipped state when the deck reshuffles",
	[111] = "Sync: retry progress uploads with exponential backoff when the device is offline for a long time",
	[112] = "Streaks: grace day for travelers crossing time zones",
	[113] = "Stories: audio-synced highlighting for read-along",
	[114] = "Spaced repetition: schedule reviews by the learner's local midnight",
	[115] = "Accessibility: larger tap targets on the answer chips",
	[116] = "Pronunciation: show the stress mark on the syllable it falls on, including borrowed Spanish words",
	[118] = "Leaderboard: hide learners who opted out of rankings",
	[119] = "Paywall: restore purchases on a fresh install",
	[120] = "Offline packs: download a unit in the background",
	[121] = "Settings: daily reminder time picker respects 24h locale",
	[122] = "Tests: snapshot the lesson summary screen",
	[201] = "zsh: lazy-load nvm",
	[202] = "Status line: plugins can contribute a clickable segment",
	[203] = "Toasts: plugin API with action buttons",
	[204] = "Router: one table owns route confidence thresholds across every coordinator and worker",
	[205] = "Worktree: prune stale locks on startup",
	[206] = "CLI: tandem logs follows a task across restarts",
	[207] = "Chore: bump Expo SDK and fix the deprecated imports",
	[208] = "Vocab: group words by root",
	[209] = "Grammar notes: render baybayin glyphs with the bundled font",
	[210] = "Files: counts in fixed right-aligned columns",
	[211] = "Code scrolls sideways per run of lines",
	[212] = "Guided view: steps point at removed lines too",
	[213] = "Picker: recently opened PRs from any repo",
	[214] = "Scheduler: retry a stalled worker from its last checkpoint",
	[215] = "Session: drop duplicate receipts when a coordinator restarts",
	[216] = "Refactor: split the receipts module",
	[301] = "Settings: move notification prefs into their own page",
	[302] = "Search: debounce the typeahead and cancel stale requests",
	[303] = "Images: serve AVIF with a WebP fallback and keep the original for crawlers that cannot decode it",
	[304] = "Cart: show the delivery estimate under each item",
	[305] = "Docs: fix the onboarding command for fish shell",
	[306] = "Profile: show the learner's streak on their avatar",
	[307] = "Lessons API: add an etag to the unit list response",
	[308] = "Auth: refresh the session before a long lesson ends",
}

-- One case: the fields that differ from a quiet PR. `size` splits into additions and deletions.
type Spec = { [string]: any }

local specs: { Spec } = {
	-- Your pull requests
	{ repo = "acme/web", n = 101, created = at("09-30"), active = at("10-08", 10), add = 40, del = 10, mergeFailure = QUEUE_FAIL },
	{ repo = "acme/web", n = 102, created = at("09-10"), active = at("09-25"), add = 15, del = 5, mergeFailure = QUEUE_FAIL },
	{ repo = "acme/web", n = 103, created = at("10-01"), active = at("10-07"), add = 100, del = 20,
		reviews = { decision = "changes_requested", latest = { review("bob", "changes_requested") } } },
	{ repo = "acme/web", n = 104, created = at("10-05"), active = at("10-09", 8), add = 20, del = 10, checks = FAILING },
	{ repo = "acme/api", n = 105, created = at("10-04"), active = at("10-06"), add = 250, del = 50, conflicts = true },
	-- A bot's review and thread: neither is feedback from a person.
	{ repo = "acme/api", n = 106, created = at("10-07"), active = at("10-08"), add = 10, del = 5,
		reviews = { decision = "review_required", latest = { review("copilot-bot", "commented", nil, true) },
			unresolved = 1, threads = { { author = "copilot-bot", bot = true } } } },
	-- Only a comment, "LGTM": no review, no thread.
	{ repo = "acme/api", n = 107, created = at("10-02"), active = at("10-05"), add = 3, del = 2,
		reviews = { decision = "review_required", comments = 1 } },
	-- Approved, with a leftover thread by the reviewer who approved.
	{ repo = "acme/api", n = 108, created = at("09-28"), active = at("10-08"), add = 60, del = 10, checks = PASSING,
		reviews = { decision = "approved", latest = { review("alice", "approved") }, unresolved = 1,
			threads = { { author = "alice", bot = false } } } },
	{ repo = "acme/api", n = 109, created = at("10-01"), active = at("10-09"), add = 8, del = 0,
		reviews = { decision = "approved", latest = { review("alice", "approved") } } },
	{ repo = "acme/api", n = 110, created = at("09-20"), active = at("10-07"), add = 350, del = 50, checks = PASSING,
		reviews = { decision = "approved", latest = { review("alice", "approved") } } },
	-- An approval doesn't clear a failing check or a conflict.
	{ repo = "acme/web", n = 111, created = at("10-03"), active = at("10-08"), add = 50, del = 10, checks = FAILING,
		reviews = { decision = "approved", latest = { review("alice", "approved") } } },
	{ repo = "acme/api", n = 112, created = at("10-05", 12), active = at("10-09", 4), add = 40, del = 5, checks = FAILING, conflicts = true,
		reviews = { decision = "approved", latest = { review("alice", "approved") } } },
	{ repo = "acme/web", n = 113, created = at("10-06"), active = at("10-09"), add = 5, del = 5, draft = true, checks = FAILING },
	{ repo = "acme/api", n = 114, created = at("10-08"), active = at("10-09"), add = 20, del = 5, checks = PENDING,
		reviews = { decision = "review_required" } },
	{ repo = "acme/api", n = 115, created = at("10-03"), active = at("10-04"), add = 80, del = 10, checks = PASSING,
		reviews = { decision = "review_required" } },
	{ repo = "acme/api", n = 116, created = at("09-29"), active = at("10-09"), add = 180, del = 20, checks = FAILING, conflicts = true,
		mergeFailure = QUEUE_FAIL,
		reviews = { decision = "changes_requested", latest = { review("bob", "changes_requested") } } },
	-- An approved PR with a thread by someone who never reviewed: that is feedback.
	{ repo = "acme/api", n = 118, created = at("10-02"), active = at("10-08", 6), add = 30, del = 3, checks = PASSING,
		reviews = { decision = "approved", latest = { review("alice", "approved") }, unresolved = 1,
			threads = { { author = "dave", bot = false } } } },
	-- A thread by a reviewer whose latest review is only a comment: feedback.
	{ repo = "acme/api", n = 119, created = at("10-06"), active = at("10-08", 12), add = 10, del = 2,
		reviews = { decision = "review_required", latest = { review("erin", "commented") }, unresolved = 1,
			threads = { { author = "erin", bot = false } } } },
	-- Threads not fetched yet: unknown threads never count.
	{ repo = "acme/api", n = 120, created = at("10-07", 12), active = at("10-09"), add = 15, del = 3,
		reviews = { decision = "review_required", unresolved = 2, threadsKnown = false } },
	-- The viewer's own thread never counts.
	{ repo = "acme/api", n = 121, created = at("10-05"), active = at("10-06"), add = 20, del = 2,
		reviews = { decision = "review_required", unresolved = 1, threads = { { author = VIEWER, bot = false } } } },
	-- Quiet for more than 7 days.
	{ repo = "acme/api", n = 122, created = at("09-01"), active = at("09-15"), add = 3, del = 0,
		reviews = { decision = "review_required" } },

	-- 16 conflicted PRs. Active: 201-206 reach Needs fixes. Stale: 207-212. Drafts: 213-216 (active or not).
	{ repo = "acme/mono", n = 201, created = at("09-20"), active = at("10-09", 6), add = 11, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 202, created = at("09-22"), active = at("10-08", 12), add = 22, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 203, created = at("09-24"), active = at("10-07"), add = 35, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 204, created = at("09-26"), active = at("10-06", 12), add = 41, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 205, created = at("09-28"), active = at("10-05", 6), add = 55, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 206, created = at("09-30", 12), active = at("10-04"), add = 66, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 207, created = at("09-02"), active = at("09-10"), add = 70, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 208, created = at("09-03"), active = at("09-11"), add = 80, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 209, created = at("09-04"), active = at("09-12"), add = 90, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 210, created = at("09-05"), active = at("09-13"), add = 100, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 211, created = at("09-06"), active = at("09-14"), add = 110, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 212, created = at("09-07"), active = at("09-15"), add = 120, del = 0, conflicts = true },
	{ repo = "acme/mono", n = 213, created = at("09-08"), active = at("10-08"), add = 130, del = 0, conflicts = true, draft = true },
	{ repo = "acme/mono", n = 214, created = at("09-09"), active = at("10-09"), add = 140, del = 0, conflicts = true, draft = true },
	{ repo = "acme/mono", n = 215, created = at("09-11"), active = at("09-12"), add = 150, del = 0, conflicts = true, draft = true },
	{ repo = "acme/mono", n = 216, created = at("09-12"), active = at("09-14"), add = 160, del = 0, conflicts = true, draft = true },

	-- Review requests
	{ repo = "acme/web", n = 301, role = "review", created = at("10-07"), active = at("10-09", 10), add = 30, del = 0,
		reviews = { decision = "review_required", requestedMe = true, requested = { VIEWER } } },
	-- New commits since the viewer approved.
	{ repo = "acme/web", n = 302, role = "review", created = at("10-01"), active = at("10-08"), add = 50, del = 0,
		reviews = { decision = "approved", mine = review(VIEWER, "approved", "old302") } },
	{ repo = "acme/web", n = 303, role = "review", created = at("10-05"), active = at("10-05"), add = 20, del = 0, addedByMe = true },
	{ repo = "acme/web", n = 304, role = "review", created = at("10-02"), active = at("10-03"), add = 80, del = 0,
		reviews = { decision = "changes_requested", mine = review(VIEWER, "changes_requested", "head304") } },
	{ repo = "acme/web", n = 305, role = "review", created = at("10-06"), active = at("10-07"), add = 10, del = 0,
		reviews = { decision = "review_required", mine = review(VIEWER, "commented", "head305") } },
	{ repo = "acme/web", n = 306, role = "review", created = at("10-04"), active = at("10-08"), add = 5, del = 0,
		reviews = { decision = "approved", mine = review(VIEWER, "approved", "head306") } },
	-- Requested again after the viewer commented.
	{ repo = "acme/api", n = 307, role = "review", created = at("09-30"), active = at("10-09", 1), add = 60, del = 0,
		reviews = { decision = "review_required", requestedMe = true, requested = { VIEWER }, mine = review(VIEWER, "commented", "head307") } },
	{ repo = "acme/api", n = 308, role = "review", created = at("10-08"), active = at("10-09", 11), add = 25, del = 0,
		reviews = { decision = "review_required", requestedMe = true, requested = { VIEWER } } },
}

-- `patch` changes a case: a field set to false is removed, and `reviews` merges into the case's own.
local function build(spec: Spec, patch: Spec?): any
	local merged: Spec = {}
	for k, v in spec do merged[k] = v end
	if patch then
		for k, v in patch do
			if k == "reviews" then
				local reviews: Spec = {}
				for rk, rv in (spec.reviews or {}) do reviews[rk] = rv end
				for rk, rv in v do reviews[rk] = rv end
				merged.reviews = reviews
			else
				merged[k] = v
			end
		end
	end
	for k, v in merged do
		if v == false and k ~= "draft" and k ~= "conflicts" and k ~= "addedByMe" then merged[k] = nil end
	end
	local reviews: Spec = {
		decision = "none", latest = {}, mine = nil, requestedMe = false, requested = {},
		unresolved = 0, threads = {}, threadsKnown = true, comments = 0,
	}
	for k, v in (merged.reviews or {}) do
		reviews[k] = if v == false and k ~= "threadsKnown" then nil else v
	end
	local role = merged.role or "mine"
	local key = merged.repo .. "#" .. merged.n
	return {
		key = key, id = "PR_" .. key, repo = merged.repo, number = merged.n,
		url = "https://github.com/" .. merged.repo .. "/pull/" .. merged.n, title = TITLES[merged.n] or ("Case " .. merged.n),
		author = if role == "mine" then VIEWER else "maria-k", authorBot = false,
		role = role, draft = merged.draft or false,
		createdAt = merged.created, lastActivityAt = merged.active,
		headOid = "head" .. merged.n, baseBranch = "main",
		additions = merged.add, deletions = merged.del, files = 1,
		checks = merged.checks or { state = "none", passing = 0, failing = 0, pending = 0 },
		conflicts = merged.conflicts or false, behind = false,
		reviews = reviews, mergeFailure = merged.mergeFailure, pending = nil,
		tandem = false, addedByMe = merged.addedByMe or false,
	}
end

local function cases(patches: { [string]: Spec }?): { any }
	local out = {}
	for _, spec in specs do
		local key = spec.repo .. "#" .. spec.n
		table.insert(out, build(spec, if patches then patches[key] else nil))
	end
	return out
end

-- Successive caches for the arrival rules. `previous` is the cache before, `prs` the refresh after.
-- `rings` are the keys that arrive in Needs fixes, `good` the keys that get the green wash,
-- `toast` is the one toast for the refresh (nil for none).
local refreshes = {
	{
		name = "first load: no ring, no toast",
		previous = nil, prs = cases(), suppressed = {},
		rings = {}, good = {}, toast = nil,
	},
	{
		name = "one failing check on an active PR: one ring, one toast",
		previous = cases({ ["acme/web#104"] = { checks = PASSING } }), prs = cases(), suppressed = {},
		rings = { "acme/web#104" }, good = {}, toast = "#104 needs fixes: failing check",
	},
	{
		name = "five new conflicts: rings, no toast",
		previous = cases({
			["acme/mono#201"] = { conflicts = false }, ["acme/mono#202"] = { conflicts = false },
			["acme/mono#203"] = { conflicts = false }, ["acme/mono#204"] = { conflicts = false },
			["acme/mono#205"] = { conflicts = false },
		}),
		prs = cases(), suppressed = {},
		rings = { "acme/mono#201", "acme/mono#202", "acme/mono#203", "acme/mono#204", "acme/mono#205" },
		good = {}, toast = nil,
	},
	{
		name = "three arrivals: one toast",
		previous = cases({
			["acme/web#101"] = { mergeFailure = false },
			["acme/web#103"] = { reviews = { decision = "review_required", latest = {} } },
			["acme/web#104"] = { checks = PASSING },
		}),
		prs = cases(), suppressed = {},
		rings = { "acme/web#101", "acme/web#103", "acme/web#104" }, good = {}, toast = "3 pull requests need fixes",
	},
	{
		name = "an inactive PR: nothing",
		previous = cases({ ["acme/web#113"] = { checks = PASSING }, ["acme/web#102"] = { mergeFailure = false } }),
		prs = cases(), suppressed = {},
		rings = {}, good = {}, toast = nil,
	},
	{
		name = "a PR the viewer just acted on, suppressed: nothing",
		previous = cases({ ["acme/web#104"] = { checks = PASSING } }), prs = cases(),
		suppressed = { ["acme/web#104"] = true },
		rings = {}, good = {}, toast = nil,
	},
	{
		name = "a PR that became ready: green wash, no toast",
		previous = cases({ ["acme/api#109"] = { reviews = { decision = "review_required", latest = {} } } }), prs = cases(),
		suppressed = {},
		rings = {}, good = { "acme/api#109" }, toast = nil,
	},
	{
		name = "a review the viewer approved: green wash, no toast",
		previous = cases({ ["acme/web#306"] = { reviews = { mine = false, requestedMe = true } } }), prs = cases(),
		suppressed = {},
		rings = {}, good = { "acme/web#306" }, toast = nil,
	},
}


-- Expected order of the keys in each column, for each sort. Written by hand, not computed.
local api = "acme/api#"
local web = "acme/web#"
local mono = "acme/mono#"
local function m(numbers: { number }): { string }
	local out = {}
	for _, n in numbers do table.insert(out, mono .. n) end
	return out
end
local function a(numbers: { number }): { string }
	local out = {}
	for _, n in numbers do table.insert(out, api .. n) end
	return out
end
local function w(numbers: { number }): { string }
	local out = {}
	for _, n in numbers do table.insert(out, web .. n) end
	return out
end
local function cat(...: { string }): { string }
	local out = {}
	for _, list in { ... } do
		for _, key in list do table.insert(out, key) end
	end
	return out
end

local orders = {
	repository = {
		needs_fixes = cat(a({ 116, 118, 119, 105, 112 }), m({ 206, 205, 204, 203, 202, 201 }), w({ 101, 103, 111, 104 })),
		in_review = a({ 114, 120, 106, 121, 115, 107 }),
		ready = a({ 110, 108, 109 }),
		inactive = cat(a({ 122 }), m({ 216, 215, 214, 213, 212, 211, 210, 209, 208, 207 }), w({ 113, 102 })),
		to_review = cat(a({ 307, 308 }), w({ 302, 301, 303 })),
		waiting_on_author = w({ 305, 304 }),
		approved = w({ 306 }),
	},
	priority = {
		needs_fixes = cat(
			w({ 101 }), a({ 116 }), w({ 103 }), a({ 118, 119 }),
			m({ 206, 205 }), a({ 105 }), m({ 204, 203 }), w({ 111 }), m({ 202 }), a({ 112 }), m({ 201 }), w({ 104 })
		),
		in_review = a({ 114, 120, 106, 121, 115, 107 }),
		ready = a({ 110, 108, 109 }),
		inactive = cat(w({ 113 }), m({ 216, 215 }), w({ 102 }), m({ 214, 213, 212, 211, 210, 209, 208, 207 }), a({ 122 })),
		to_review = cat(w({ 302 }), a({ 307 }), w({ 301 }), a({ 308 }), w({ 303 })),
		waiting_on_author = w({ 305, 304 }),
		approved = w({ 306 }),
	},
	newest = {
		needs_fixes = cat(
			a({ 119, 112 }), w({ 104 }), a({ 105 }), w({ 111 }), a({ 118 }), w({ 103 }), m({ 206 }), w({ 101 }),
			a({ 116 }), m({ 205, 204, 203, 202, 201 })
		),
		in_review = a({ 114, 120, 106, 121, 115, 107 }),
		ready = a({ 109, 108, 110 }),
		inactive = cat(w({ 113 }), m({ 216, 215 }), w({ 102 }), m({ 214, 213, 212, 211, 210, 209, 208, 207 }), a({ 122 })),
		to_review = cat(a({ 308 }), w({ 301, 303, 302 }), a({ 307 })),
		waiting_on_author = w({ 305, 304 }),
		approved = w({ 306 }),
	},
	oldest = {
		needs_fixes = cat(
			m({ 201, 202, 203, 204, 205 }), a({ 116 }), w({ 101 }), m({ 206 }), w({ 103 }), a({ 118 }), w({ 111 }),
			a({ 105 }), w({ 104 }), a({ 112, 119 })
		),
		in_review = a({ 107, 115, 121, 106, 120, 114 }),
		ready = a({ 110, 108, 109 }),
		inactive = cat(a({ 122 }), m({ 207, 208, 209, 210, 211, 212, 213, 214 }), w({ 102 }), m({ 215, 216 }), w({ 113 })),
		to_review = cat(a({ 307 }), w({ 302, 303, 301 }), a({ 308 })),
		waiting_on_author = w({ 304, 305 }),
		approved = w({ 306 }),
	},
	smallest = {
		needs_fixes = cat(
			m({ 201 }), a({ 119 }), m({ 202 }), w({ 104 }), a({ 118 }), m({ 203, 204 }), a({ 112 }), w({ 101 }),
			m({ 205 }), w({ 111 }), m({ 206 }), w({ 103 }), a({ 116, 105 })
		),
		in_review = a({ 107, 106, 120, 121, 114, 115 }),
		ready = a({ 109, 108, 110 }),
		inactive = cat(a({ 122 }), w({ 113, 102 }), m({ 207, 208, 209, 210, 211, 212, 213, 214, 215, 216 })),
		to_review = cat(w({ 303 }), a({ 308 }), w({ 301, 302 }), a({ 307 })),
		waiting_on_author = w({ 305, 304 }),
		approved = w({ 306 }),
	},
}

return {
	viewer = VIEWER,
	asOf = ASOF,
	asOfIso = ASOF_ISO,
	prs = cases(),
	columns = {
		-- Your pull requests
		["acme/web#101"] = "needs_fixes", ["acme/web#102"] = "inactive", ["acme/web#103"] = "needs_fixes",
		["acme/web#104"] = "needs_fixes", ["acme/api#105"] = "needs_fixes", ["acme/api#106"] = "in_review",
		["acme/api#107"] = "in_review", ["acme/api#108"] = "ready", ["acme/api#109"] = "ready",
		["acme/api#110"] = "ready", ["acme/web#111"] = "needs_fixes", ["acme/api#112"] = "needs_fixes",
		["acme/web#113"] = "inactive", ["acme/api#114"] = "in_review", ["acme/api#115"] = "in_review",
		["acme/api#116"] = "needs_fixes", ["acme/api#118"] = "needs_fixes", ["acme/api#119"] = "needs_fixes",
		["acme/api#120"] = "in_review", ["acme/api#121"] = "in_review", ["acme/api#122"] = "inactive",
		["acme/mono#201"] = "needs_fixes", ["acme/mono#202"] = "needs_fixes", ["acme/mono#203"] = "needs_fixes",
		["acme/mono#204"] = "needs_fixes", ["acme/mono#205"] = "needs_fixes", ["acme/mono#206"] = "needs_fixes",
		["acme/mono#207"] = "inactive", ["acme/mono#208"] = "inactive", ["acme/mono#209"] = "inactive",
		["acme/mono#210"] = "inactive", ["acme/mono#211"] = "inactive", ["acme/mono#212"] = "inactive",
		["acme/mono#213"] = "inactive", ["acme/mono#214"] = "inactive", ["acme/mono#215"] = "inactive",
		["acme/mono#216"] = "inactive",
		-- Review requests
		["acme/web#301"] = "to_review", ["acme/web#302"] = "to_review", ["acme/web#303"] = "to_review",
		["acme/web#304"] = "waiting_on_author", ["acme/web#305"] = "waiting_on_author", ["acme/web#306"] = "approved",
		["acme/api#307"] = "to_review", ["acme/api#308"] = "to_review",
	},
	reasons = {
		["acme/web#101"] = { "merge_failed" }, ["acme/web#103"] = { "feedback" }, ["acme/web#104"] = { "checks" },
		["acme/api#105"] = { "conflict" }, ["acme/web#111"] = { "checks" }, ["acme/api#112"] = { "checks", "conflict" },
		["acme/api#116"] = { "merge_failed", "feedback", "checks", "conflict" },
		["acme/api#118"] = { "feedback" }, ["acme/api#119"] = { "feedback" },
		["acme/mono#201"] = { "conflict" }, ["acme/mono#202"] = { "conflict" }, ["acme/mono#203"] = { "conflict" },
		["acme/mono#204"] = { "conflict" }, ["acme/mono#205"] = { "conflict" }, ["acme/mono#206"] = { "conflict" },
	},
	orders = orders,
	-- Next up: merge failures, then a person waiting on the viewer, then machines and added PRs; longest waiting first in each.
	nextUp = cat(
		w({ 101 }), a({ 116 }), w({ 103, 302 }), a({ 118, 119, 307 }), w({ 301 }), a({ 308 }),
		m({ 206 }), w({ 303 }), m({ 205 }), a({ 105 }), m({ 204, 203 }), w({ 111 }), m({ 202 }), a({ 112 }), m({ 201 }), w({ 104 })
	),
	refreshes = refreshes,
}
