--!strict
-- Pull requests for selecting several: a Ready column of six long titles (three repos on three merge methods,
-- one title that would wrap at split width, one behind main, one queued) and Inactive rows in every mixture
-- (stale draft, fresh draft, stale non-draft, stale with conflicts). Everything is relative to `asOf`.

local ASOF_ISO = "2026-10-09T12:00:00Z"
local ASOF = 1791547200 -- ASOF_ISO in seconds since the epoch

local function pr(repo: string, n: number, title: string, created: string, active: string, patch: { [string]: any }?): any
	local out: any = {
		key = repo .. "#" .. n, id = "PR_" .. repo .. "#" .. n, repo = repo, number = n,
		url = "https://github.com/" .. repo .. "/pull/" .. n, title = title, author = "jubbydev", authorBot = false,
		role = "mine", draft = false, createdAt = created, lastActivityAt = active, headOid = "head" .. n, baseBranch = "main",
		additions = 10, deletions = 2, files = 3,
		checks = { state = "passing", passing = 4, failing = 0, pending = 0 },
		conflicts = false, behind = false,
		reviews = {
			decision = "approved", latest = {}, mine = nil, requestedMe = false, requested = {}, unresolved = 0,
			threads = {}, threadsKnown = true, comments = 0,
		},
		mergeFailure = nil, pending = nil, tandem = false, addedByMe = false,
	}
	if patch then
		for k, v in patch do out[k] = v end
	end
	return out
end

local WRAPS = "Checkout: keep the promo code, the gift note and the saved delivery window when the cart re-prices after a shipping change in another tab"

local prs: { any } = {
	-- Ready to merge, oldest first. acme/web squashes, acme/api asks for a /merge comment, acme/mono uses a queue.
	pr("acme/web", 401, "Checkout: keep the promo code when the cart re-prices after a shipping change", "2026-09-20T09:00:00Z", "2026-10-08T10:00:00Z"),
	pr("acme/api", 402, "Lessons API: paginate the unit list and return a cursor with every page of results", "2026-09-21T09:00:00Z", "2026-10-08T11:00:00Z"),
	pr("acme/mono", 403, "Router: one table owns route confidence thresholds across every coordinator and worker", "2026-09-22T09:00:00Z", "2026-10-08T12:00:00Z"),
	pr("acme/web", 404, WRAPS, "2026-09-23T09:00:00Z", "2026-10-08T13:00:00Z"),
	pr("acme/api", 405, "Sync: retry progress uploads with exponential backoff when the device is offline for a long time", "2026-09-24T09:00:00Z", "2026-10-08T14:00:00Z"),
	pr("acme/mono", 406, "Pronunciation: show the stress mark on the syllable it falls on, including borrowed Spanish words", "2026-09-25T09:00:00Z", "2026-10-08T15:00:00Z"),
	-- Ready, but not selectable: behind main, and a merge already queued.
	pr("acme/web", 407, "Docs: the coordinator lifecycle, with a diagram", "2026-09-26T09:00:00Z", "2026-10-08T16:00:00Z", { behind = true }),
	pr("acme/api", 408, "Analytics: drop the duplicate lesson_complete event", "2026-09-27T09:00:00Z", "2026-10-08T17:00:00Z",
		{ pending = { method = "comment", at = "2026-10-09T09:00:00Z" } }),
	-- Inactive: a stale draft, a fresh draft, stale non-drafts (one with conflicts).
	pr("acme/web", 411, "Spike: a stale draft nobody touched for a month", "2026-09-01T09:00:00Z", "2026-09-05T09:00:00Z", { draft = true }),
	pr("acme/web", 412, "Spike: a fresh draft still being written", "2026-10-08T09:00:00Z", "2026-10-09T09:00:00Z", { draft = true }),
	pr("acme/api", 413, "Refactor: split the receipts module so each receipt kind has its own file and test", "2026-09-02T09:00:00Z", "2026-09-10T09:00:00Z"),
	pr("acme/mono", 414, "Chore: bump Expo SDK and fix the deprecated imports", "2026-09-03T09:00:00Z", "2026-09-20T09:00:00Z", { conflicts = true }),
	-- #415 has exactly 7 days of silence, which is still active (In review); #416 is an hour past it, so stale.
	pr("acme/api", 415, "Vocab: group words by root", "2026-09-30T09:00:00Z", "2026-10-02T12:00:00Z",
		{ reviews = { decision = "review_required", latest = {}, mine = nil, requestedMe = false, requested = {}, unresolved = 0, threads = {}, threadsKnown = true, comments = 0 } }),
	pr("acme/api", 416, "Grammar notes: render baybayin glyphs with the bundled font", "2026-09-30T09:00:00Z", "2026-10-02T11:00:00Z"),
}

return {
	asOf = ASOF,
	asOfIso = ASOF_ISO,
	prs = prs,
	-- Selectable Ready cards in column order (oldest first).
	selectable = { "acme/web#401", "acme/api#402", "acme/mono#403", "acme/web#404", "acme/api#405", "acme/mono#406" },
	-- Close stale: the non-draft Inactive rows older than 7 days.
	stale = { "acme/api#416", "acme/mono#414", "acme/api#413" },
}
