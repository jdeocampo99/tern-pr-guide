--!strict
-- Re-request review and Merge when ready: one PR of the viewer's per case, with a frozen clock.
-- SYNTHETIC: hand-written in the shape of hub-f's normalized records. Also the sample board for
-- `fixture=rereview`, with the repos' merge methods and "Allow auto-merge" settings below.

local VIEWER = "jubbydev"
local ASOF_ISO = "2026-10-09T12:00:00Z"
local ASOF = 1791547200 -- ASOF_ISO in seconds since the epoch
local PASSING = { state = "passing", passing = 4, failing = 0, pending = 0 }

local function review(author: string, verdict: string, oid: string): any
	return { author = author, bot = false, verdict = verdict, at = "2026-10-08T09:00:00Z", oid = oid }
end

local function pr(repo: string, n: number, title: string, reviews: any, patch: any?): any
	local base = {
		key = repo .. "#" .. n, id = "PR_" .. repo .. "#" .. n, repo = repo, number = n,
		url = "https://github.com/" .. repo .. "/pull/" .. n, title = title,
		author = VIEWER, authorBot = false, role = "mine", draft = false,
		createdAt = "2026-10-05T09:00:00Z", lastActivityAt = "2026-10-09T08:00:00Z",
		headOid = "head" .. n, baseBranch = "main", additions = 40, deletions = 8, files = 3,
		checks = PASSING, conflicts = false, behind = false,
		reviews = {
			decision = "review_required", latest = {}, mine = nil, requestedMe = false, requested = {},
			unresolved = 0, threads = {}, threadsKnown = true, comments = 0,
		},
		mergeFailure = nil, pending = nil, tandem = false, addedByMe = false,
	}
	for k, v in reviews do base.reviews[k] = v end
	for k, v in (patch or {}) do base[k] = v end
	return base
end

local prs = {
	-- Changes requested on an older commit, then pushed: waiting on @maria-k.
	pr("acme/web", 201, "Checkout: keep the cart when the session expires",
		{ decision = "changes_requested", latest = { review("maria-k", "changes_requested", "old201") } }),
	-- Changes requested on the current head: nothing pushed yet, so the author's turn.
	pr("acme/web", 202, "Checkout: show tax before the payment step",
		{ decision = "changes_requested", latest = { review("maria-k", "changes_requested", "head202") } }),
	-- The reviewer approved after the push.
	pr("acme/web", 203, "Checkout: round totals the way the invoice does",
		{ decision = "approved", latest = { review("maria-k", "approved", "head203") } }),
	-- Two reviewers: only @maria-k still asks for changes.
	pr("acme/web", 204, "Checkout: retry a declined card once",
		{ decision = "changes_requested", latest = { review("maria-k", "changes_requested", "old204"), review("devon", "approved", "head204") } }),
	-- Merge when ready already set.
	pr("acme/web", 205, "Checkout: label the gift option", {}, { pending = { method = "queue", at = "2026-10-09T10:00:00Z" } }),
	-- The repo doesn't allow auto-merge.
	pr("acme/api", 206, "Billing: send the receipt after capture", {}),
	-- A comment-method repo: the command is posted early.
	pr("acme/aviator", 207, "Queue: drop the stale lock file", {}),
	-- Already asked again: still waiting, nothing left to ask.
	pr("acme/web", 208, "Checkout: format prices in the shopper's locale",
		{ decision = "changes_requested", latest = { review("maria-k", "changes_requested", "old208") }, requested = { "maria-k" } }),
	-- Three reviewers waiting: the card names the first and counts the rest.
	pr("acme/web", 209, "Checkout: split the order summary by seller",
		{ decision = "changes_requested", latest = { review("maria-k", "changes_requested", "old209"), review("devon", "changes_requested", "old209"), review("lee", "changes_requested", "old209") } }),
}

local squash = { method = { kind = "squash" }, source = "viewer", ask = false }

return {
	viewer = VIEWER,
	asOf = ASOF,
	asOfIso = ASOF_ISO,
	prs = prs,
	merges = {
		["acme/web"] = squash,
		["acme/api"] = squash,
		["acme/aviator"] = { method = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" }, source = "declared", ask = false },
	},
	autoMerge = { ["acme/web"] = true, ["acme/api"] = false, ["acme/aviator"] = false },
	-- Each case's card text, main action and the entries behind the ▾.
	expect = {
		["acme/web#201"] = { column = "in_review", chip = "Waiting on @maria-k to re-review", main = "card-rerequest", more = "card-copy,card-auto" },
		["acme/web#202"] = { column = "needs_fixes" },
		["acme/web#203"] = { column = "ready" },
		["acme/web#204"] = { column = "in_review", chip = "Waiting on @maria-k to re-review", main = "card-rerequest", more = "card-copy,card-auto" },
		["acme/web#205"] = { column = "in_review", chip = "Waiting on review", note = "Merges when ready", main = "card-copy", more = "card-cancel" },
		["acme/api#206"] = { column = "in_review", chip = "Waiting on review", main = "card-copy", more = "" },
		["acme/aviator#207"] = { column = "in_review", chip = "Waiting on review", main = "card-copy", more = "card-auto" },
		["acme/web#208"] = { column = "in_review", chip = "Waiting on @maria-k to re-review", main = "card-copy", more = "card-auto" },
		["acme/web#209"] = { column = "in_review", chip = "Waiting on @maria-k and 2 others to re-review", main = "card-rerequest", more = "card-copy,card-auto" },
	},
}
