--!strict
-- Frozen feedback cases and bot edit transcript for the summary tests and fixture=summary board.
local AgentFix = require("../../src/hub/agent-fix")
local Fixes = require("../../src/hub/fixes")
local Model = require("../../src/hub/model")
local Three: any = require("./agent/summary-three")
local Comments: any = require("./agent/summary-comments")
local Requested: any = require("./agent/summary-requested")
local Bot: any = require("./agent/bot-omp")

local M = { asOf = 1791590400, asOfIso = "2026-10-10T00:00:00Z" }
local HEAD, COMMIT = string.rep("a", 40), string.rep("b", 40)

local function thread(id: string, author: string, body: string, bot: boolean, group: "comment" | "requested"): Fixes.ThreadDetail
	return {
		id = id, author = author, body = body, bot = bot, group = group,
		path = "SOURCE_PATH_SENTINEL", line = 5, outdated = false, replies = 0, url = "URL_SENTINEL",
		hunk = "DIFF_HUNK_SENTINEL",
	}
end

local function details(number: number, threads: { Fixes.ThreadDetail }): Fixes.FixDetails
	return {
		key = "acme/web#" .. number, headOid = HEAD, fetchedAt = M.asOfIso,
		reviews = {}, threads = threads, checks = {}, changedPaths = { "CHANGED_PATH_SENTINEL" },
		files = { SOURCE_PATH_SENTINEL = "FILE_CONTENT_SENTINEL" },
	}
end

local three = details(1901, {
	thread("m", "maria-k", "Explain the retry limit.", false, "comment"),
	thread("d", "devon", "Use a clearer name.", false, "comment"),
	thread("b", "review-bot[bot]", "Guard the empty value.", true, "comment"),
})
three.checks = { {
	name = "CHECK_NAME_SENTINEL", url = "CHECK_URL_SENTINEL", summary = "CHECK_CONTENT_SENTINEL",
	annotations = { { path = "ANNOTATION_PATH_SENTINEL", line = 5, level = "failure", message = "ANNOTATION_CONTENT_SENTINEL" } },
} }
three.conflicts = { { path = "CONFLICT_PATH_SENTINEL", hunks = { { start = 1, branch = { "CONFLICT_OURS_SENTINEL" }, main = { "CONFLICT_THEIRS_SENTINEL" } } } } }
three.conflictNote = "CONFLICT_NOTE_SENTINEL"
local comments = details(1902, { thread("c", "maria-k", "Why do retries stop at three?", false, "comment") })
local requested = details(1903, { thread("r", "devon", "Guard before retrying.", false, "requested") })
requested.reviews = { { author = "devon", body = "Add the guard before retrying.", at = M.asOfIso, url = "REVIEW_URL_SENTINEL" } }
local bot = details(1904, { thread("b", "review-bot[bot]", "Guard the empty value.", true, "comment") })
bot.threads[1].path = "src/retry.luau"
M.details = { three = three, comments = comments, requested = requested, bot = bot }

-- A bot's body-only COMMENTED review, as github.parseDetails reads it: a review-level thread with no path.
local reviewBot = details(1905, { thread("review:https://github.com/acme/web/pull/1905#pullrequestreview-1", "review-bot[bot]", "Guard the empty value.", true, "comment") })
reviewBot.threads[1].path, reviewBot.threads[1].line, reviewBot.threads[1].hunk = "", nil, nil
M.reviewBot = reviewBot

-- fixture=cases: the one thread each comments-only PR records (threads in cases.luau), so A stays Summarize.
local function caseDetails(number: number, author: string, body: string): Fixes.FixDetails
	local d = details(number, { thread("case-" .. number, author, body, false, "comment") })
	d.key = "acme/api#" .. number
	return d
end
M.cases = {
	["acme/api#118"] = caseDetails(118, "dave", "Should opted-out learners still count toward the weekly totals?"),
	["acme/api#119"] = caseDetails(119, "erin", "Does restore purchases also cover a fresh install on a second device?"),
} :: { [string]: Fixes.FixDetails }
M.transcripts = { three = Three, comments = Comments, requested = Requested, bot = Bot }
M.botDiff = "diff --git a/src/retry.luau b/src/retry.luau\nindex 1111111..2222222 100644\n--- a/src/retry.luau\n+++ b/src/retry.luau\n@@ -1,3 +1,3 @@\n local function valueOrZero(value)\n-return value\n+return value or 0\n end\n"
M.botFile = "local function valueOrZero(value)\nreturn value or 0\nend\n"

local function pr(d: Fixes.FixDetails, title: string): Model.HubPR
	local threads: { Model.OpenThread } = {}
	for _, t in d.threads do table.insert(threads, { author = t.author, bot = t.bot }) end
	local latest: { Model.Review } = {}
	if d == requested then table.insert(latest, { author = "devon", bot = false, verdict = "changes_requested", at = M.asOfIso, oid = HEAD }) end
	if d == bot then table.insert(latest, { author = "review-bot[bot]", bot = true, verdict = "commented", at = M.asOfIso, oid = HEAD }) end
	return {
		key = d.key, id = "PR_" .. d.key, repo = "acme/web", number = tonumber(string.match(d.key, "#(%d+)$")) :: number,
		url = "https://github.com/acme/web/pull/" .. (string.match(d.key, "#(%d+)$") :: string), title = title,
		author = "jubbydev", authorBot = false, role = "mine", draft = false, createdAt = "2026-10-09T00:00:00Z", lastActivityAt = M.asOfIso,
		headOid = HEAD, baseBranch = "main", additions = 3, deletions = 1, files = 1,
		checks = if d == three then { state = "failing", passing = 0, failing = 1, pending = 0 } else { state = "none", passing = 0, failing = 0, pending = 0 },
		conflicts = d == three, behind = false,
		reviews = { decision = "none", latest = latest, requested = {}, requestedMe = false, unresolved = #threads, threads = threads, threadsKnown = true, comments = #threads },
		tandem = false, addedByMe = false,
	}
end
M.prs = {
	pr(three, "Keep the retry budget when the checkout is recalculated and feedback arrives from three commenters"),
	pr(comments, "Explain why the checkout retry budget stops after three attempts"),
	pr(requested, "Guard the empty checkout value before retrying the request"),
	pr(bot, "Address the bot review while the checkout pull request waits for a human review"),
}

function M.answer(d: Fixes.FixDetails): string
	for name, source in M.details do
		if name ~= "bot" and source.key == d.key then return M.transcripts[name].stdout end
	end
	-- Other sample boards reuse their own identities without starting a model.
	local authors: { string } = {}
	local human: string? = nil
	local requested = #d.reviews > 0
	for _, review in d.reviews do if not table.find(authors, review.author) then table.insert(authors, review.author) end end
	for _, t in d.threads do
		if not table.find(authors, t.author) then table.insert(authors, t.author) end
		if not t.bot and not human then human = t.author end
		if not t.bot and t.group == "requested" then requested = true end
	end
	local verdict = if requested then "Address requested changes" elseif human then "Reply to @" .. human else "Review feedback"
	local out = { "PRGUIDE_SUMMARY_V1", "Verdict: " .. verdict }
	for _, author in authors do table.insert(out, "Comment: @" .. author .. "\tReview the feedback from this commenter.") end
	table.insert(out, "End")
	return table.concat(out, "\n")
end

function M.spec(key: string): AgentFix.Spec
	local d = table.clone(bot)
	d.key = key
	return {
		key = key, clone = "/clone", checkout = "/reader", pool = "/pool", branch = "topic", base = "main", headOid = HEAD,
		number = tonumber(string.match(key, "#(%d+)$")) :: number, tool = "/plugin/tools/conflicts", omp = "/omp", model = "provider/model", effort = "high",
		input = { kind = "bot", details = d },
		sandbox = { exec = "/usr/bin/sandbox-exec", home = "/home/prguide" },
	}
end

function M.events(): { AgentFix.Event }
	return {
		{ kind = "worktree", path = "/pool/acme/web/wt-1" },
		{ kind = "stage", stage = "agent" },
		{ kind = "hunks", hunks = AgentFix.botHunks(M.botDiff) :: { AgentFix.ConflictHunk } },
		{ kind = "stage", stage = "commit" },
		{ kind = "committed", commit = COMMIT, summary = Bot.stdout },
	}
end

return M
