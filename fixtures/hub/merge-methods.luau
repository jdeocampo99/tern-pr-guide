--!strict
-- Per-repo merge methods and Merge failed, as the responses of docs/hub/queries/merge-detect.graphql,
-- merge-failure.graphql and hub-f's queue-removal timeline.
-- SYNTHETIC: hand-written in the shape of real responses. A live run against jubbydev/tern-pr-guide-hub-smoke
-- (2026-10-10) confirmed both queries' shape and 1 point each; that repo has no Aviator, queue or merge bot, so
-- these cases cannot be recorded there. Times are ISO strings and compare as text.

local VIEWER = "jubbydev"
local ASOF_ISO = "2026-10-09T12:00:00Z"
local ASOF = 1791547200 -- ASOF_ISO in seconds since the epoch

local function person(login: string): any return { __typename = "User", login = login } end
local function bot(login: string): any return { __typename = "Bot", login = login } end

-- A merged PR: who merged it, and the comments before it.
local function merged(day: number, by: any, comments: { any }): any
	return {
		mergedAt = string.format("2026-10-%02dT10:00:00Z", day), mergedBy = by,
		comments = { nodes = comments },
	}
end
local function said(day: number, author: any, body: string): any
	return { createdAt = string.format("2026-10-%02dT09:59:00Z", day), body = body, author = author }
end

local function detect(repository: any): any
	return { data = {
		rateLimit = { cost = 1, remaining = 4999, limit = 5000, resetAt = "2026-10-09T13:00:00Z" },
		repository = repository,
	} }
end

local learnedNodes: { any } = {}
for day = 1, 8 do
	table.insert(learnedNodes, merged(day, bot("merge-bot[bot]"), {
		said(day, person("dana"), "/merge"),
	}))
end

-- A PR whose comment or label merge was asked for at PENDING_AT, with the head the answer was read for.
local PENDING_AT = "2026-10-09T10:00:00Z"
local function lookup(comments: { any }, contexts: { any }): any
	return {
		id = "PR_acme/api#109", headRefOid = "head109",
		comments = { nodes = comments },
		commits = { nodes = { { commit = { statusCheckRollup = { contexts = { nodes = contexts } } } } } },
	}
end

return {
	asOf = ASOF,
	asOfIso = ASOF_ISO,
	viewer = VIEWER,
	pendingAt = PENDING_AT,

	-- merge-detect responses, by repo.
	detect = {
		-- .aviator/config.yml exists.
		["acme/aviator"] = detect({ viewerDefaultMergeMethod = "SQUASH", aviator = { __typename = "Blob" }, pullRequests = { nodes = {} } }),
		-- A GitHub merge queue.
		["acme/queued"] = detect({ viewerDefaultMergeMethod = "MERGE", mergeQueue = { id = "MQ_1" }, pullRequests = { nodes = {} } }),
		-- All of the last 8 merges were done by a bot right after a person commented /merge.
		["acme/botmerge"] = detect({ viewerDefaultMergeMethod = "REBASE", pullRequests = { nodes = learnedNodes } }),
		-- Two of 8 only: not a habit.
		["acme/mixed"] = detect({ viewerDefaultMergeMethod = "SQUASH", pullRequests = { nodes = {
			learnedNodes[1], learnedNodes[2],
			merged(3, person("dana"), { said(3, person("dana"), "/merge") }), -- merged by a person
			merged(4, bot("merge-bot[bot]"), { said(4, bot("ci[bot]"), "/merge") }), -- the command came from a bot
			merged(5, bot("merge-bot[bot]"), {}),
			merged(6, bot("merge-bot[bot]"), { said(6, person("dana"), "Looks good to me") }),
		} } }),
		-- Nothing special: GitHub's own merge.
		["acme/plain"] = detect({ viewerDefaultMergeMethod = "SQUASH", pullRequests = { nodes = { merged(1, person("dana"), {}) } } }),
	},

	-- hub-f's data for a PR removed from GitHub's merge queue: the queue's own reason.
	queueRemoval = { data = {
		viewer = { login = VIEWER },
		mine = { nodes = { {
			id = "PR_acme/queued#301", number = 301, repository = { nameWithOwner = "acme/queued" },
			author = person(VIEWER), headRefOid = "head301", updatedAt = "2026-10-09T09:00:00Z",
			timelineItems = { nodes = { { createdAt = "2026-10-09T09:30:00Z", reason = "Merge conflict with the base branch" } } },
		} } },
	} },

	-- merge-failure responses for one PR (acme/api#109) with a merge asked for at PENDING_AT.
	failures = {
		-- Aviator's status comment.
		aviator = lookup({
			{ createdAt = "2026-10-09T10:05:00Z", author = bot("aviator-app[bot]"),
				body = "## Aviator\n\n:x: This pull request failed to merge: e2e failed on the merge group.\n\nSee the run." },
		}, {}),
		-- Aviator's failing check run, with no reply.
		aviatorCheck = lookup({}, {
			{ __typename = "CheckRun", name = "Aviator MergeQueue", conclusion = "FAILURE", completedAt = "2026-10-09T10:06:00Z" },
		}),
		-- A `/merge` comment, then a required check failed.
		comment = lookup({
			{ createdAt = "2026-10-09T10:00:00Z", author = person("dana"), body = "/merge" },
		}, {
			{ __typename = "CheckRun", name = "ci", conclusion = "FAILURE", completedAt = "2026-10-09T10:08:00Z" },
			{ __typename = "CheckRun", name = "lint", conclusion = "SUCCESS", completedAt = "2026-10-09T10:07:00Z" },
		}),
		-- A label was added (accepted), then a check failed.
		check = lookup({}, {
			{ __typename = "StatusContext", context = "buildkite/api", state = "FAILURE", createdAt = "2026-10-09T10:09:00Z" },
		}),
		-- A `/merge`-style bot's failure reply, newest of two.
		bot = lookup({
			{ createdAt = "2026-10-09T10:02:00Z", author = bot("merge-bot[bot]"), body = "Queued." },
			{ createdAt = "2026-10-09T10:04:00Z", author = bot("merge-bot[bot]"), body = "> Couldn't merge: 2 approvals are required.\nTry again later." },
		}, {}),
		-- The same failing check as `comment`, but it finished before the merge was asked for again.
		superseded = lookup({}, {
			{ __typename = "CheckRun", name = "ci", conclusion = "FAILURE", completedAt = "2026-10-09T09:30:00Z" },
		}),
		-- A bot reply that is not a failure, and a passing check.
		fine = lookup({
			{ createdAt = "2026-10-09T10:02:00Z", author = bot("codex[bot]"), body = "<!-- summary -->\n\n## Review\nCompleted." },
		}, {
			{ __typename = "CheckRun", name = "ci", conclusion = "SUCCESS", completedAt = "2026-10-09T10:08:00Z" },
		}),
	},
}
