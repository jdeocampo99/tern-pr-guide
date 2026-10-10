--!strict
-- The fixes page's inputs, one per kind of problem: the PR, its details (normalized from raw-details.json by
-- `github.parseDetails`) and the fake git output `fetch` would return. Read by tests/fixes_test.luau and,
-- through `sample`, by the fixture block (fixture=cases).
-- git output: `smokeTree`, `smokeShown` and `smokeLog` were recorded from jubbydev/tern-pr-guide-hub-smoke #6
-- (git 2.54, merge.conflictStyle=diff3). The `receipts` strings, the multi-file tree and the "(#415)" subject are synthetic.
local Fixes = require("../../src/hub/fixes")
local Github = require("../../src/github")
local Model = require("../../src/hub/model")
local Raw: any = require("./raw-details")

type HubPR = Model.HubPR
type FixDetails = Fixes.FixDetails

local function pr(repo: string, number: number, title: string, patch: { [string]: any }): HubPR
	local out: HubPR = {
		key = repo .. "#" .. number, id = "PR_" .. repo .. number, repo = repo, number = number,
		url = "https://github.com/" .. repo .. "/pull/" .. number, title = title,
		author = "jubbydev", authorBot = false, role = "mine", draft = false,
		createdAt = "2026-10-05T12:00:00Z", lastActivityAt = "2026-10-09T04:00:00Z",
		headOid = "head" .. number, baseBranch = "main", additions = 10, deletions = 2, files = 2,
		checks = { state = "none", passing = 0, failing = 0, pending = 0 },
		conflicts = false, behind = false,
		reviews = {
			decision = "none", latest = {}, mine = nil, requestedMe = false, requested = {},
			unresolved = 0, threads = {}, threadsKnown = true, comments = 0,
		},
		mergeFailure = nil, pending = nil, tandem = false, addedByMe = false,
	}
	for k, v in patch do (out :: any)[k] = v end
	return out
end

local FAILING = { state = "failing", passing = 3, failing = 1, pending = 0 }

local prs: { [string]: HubPR } = {
	requested = pr("acme/web", 404, "Checkout: keep the promo code when the cart re-prices", {}),
	comment = pr("acme/web", 405, "Checkout: name the repricing tests", {}),
	bot = pr("acme/web", 406, "Checkout: round the total once", {}),
	check = pr("jdeocampo99/tandem", 418, "fix(session): drop duplicate receipts when a coordinator restarts", { checks = FAILING, tandem = true }),
	noann = pr("acme/web", 407, "Build: pin the toolchain", { checks = FAILING }),
	noannReal = pr("jubbydev/tern-pr-guide-hub-smoke", 8, "Smoke: failing pull request", { checks = FAILING }),
	conflict = pr("jubbydev/tern-pr-guide-hub-smoke", 6, "Smoke: conflicted pull request", { conflicts = true }),
	conflictMany = pr("jdeocampo99/tandem", 419, "refactor(session): receipts by coordinator", { conflicts = true }),
	failure = pr("acme/web", 101, "Checkout: keep the promo code", {
		mergeFailure = { kind = "queue", reason = "Removed from the merge queue: a required check failed" },
	}),
}

local function parsed(raw: any, forPr: HubPR): FixDetails
	local d = Github.parseDetails(raw, forPr)
	assert(d, "fixture does not parse")
	return d
end

-- A copy of `d` keeping only the threads `keep` accepts, and the reviews when `reviews`.
local function only(d: FixDetails, keep: (Fixes.ThreadDetail) -> boolean, reviews: boolean): FixDetails
	local out: FixDetails = {
		key = d.key, headOid = d.headOid, fetchedAt = d.fetchedAt, reviews = if reviews then d.reviews else {}, threads = {},
		checks = d.checks, changedPaths = d.changedPaths, conflicts = d.conflicts, conflictNote = d.conflictNote, files = d.files,
	}
	for _, thread in d.threads do
		if keep(thread) then table.insert(out.threads, thread) end
	end
	return out
end

local all = parsed(Raw.requested, prs.requested)
local function retarget(d: FixDetails, key: string): FixDetails
	d.key = key
	return d
end

local details: { [string]: FixDetails } = {
	requested = retarget(only(all, function(t) return t.group == "requested" and not t.bot end, true), prs.requested.key),
	comment = retarget(only(all, function(t) return t.group == "comment" and not t.bot and not t.outdated end, false), prs.comment.key),
	bot = retarget(only(all, function(t) return t.bot end, false), prs.bot.key),
	check = retarget(parsed(Raw.annotated, prs.check), prs.check.key),
	noann = retarget(parsed(Raw.noann, prs.noann), prs.noann.key),
	noannReal = parsed(Raw.failing, prs.noannReal),
	conflict = parsed(Raw.conflict, prs.conflict),
	conflictMany = retarget(parsed(Raw.conflict, prs.conflictMany), prs.conflictMany.key),
	failure = parsed({ data = { node = { id = "PR_failure", headRefOid = "head101" } } }, prs.failure),
}
-- The outdated thread is a comment too: it stays in `all`, on a file that moved.
details.outdated = retarget(only(all, function(t) return t.outdated end, false), prs.comment.key)

-- The annotated file of the `check` case: line 42 is the one the typecheck annotation points at.
local receipts = {}
for n = 1, 70 do receipts[n] = "  // line " .. n end
receipts[1] = "import type { Receipt } from './types';"
receipts[40] = "export function dedupeReceipts(receipts: Receipt[]): Receipt[] {"
receipts[41] = "  const seen = new Set<string>();"
receipts[42] = "    const key = receipt.id;"
receipts[43] = "    if (seen.has(key)) continue;"
details.check.files = { ["src/session/receipts.ts"] = table.concat(receipts, "\n") .. "\n" }

local TREE = "7784ba3f5f2f1938ff54bf80fa4ea308ee329c6c"

local M = {}

M.prs = prs
M.details = details
-- git merge-tree --write-tree --name-only: one file (recorded), none (clean), three files (synthetic).
M.smokeTree = TREE .. "\nsmoke/conflict.txt\n\nAuto-merging smoke/conflict.txt\nCONFLICT (content): Merge conflict in smoke/conflict.txt\n"
M.cleanTree = TREE .. "\n"
M.manyTree = TREE .. "\nsrc/session/receipts.ts\nsrc/session/store.ts\nsrc/session/receipts.ts\n\nAuto-merging src/session/receipts.ts\nCONFLICT (content): Merge conflict in src/session/receipts.ts\nAuto-merging src/session/store.ts\nCONFLICT (content): Merge conflict in src/session/store.ts\n"
-- git show <tree>:<path>
M.smokeShown = "<<<<<<< pr6\nbranch side 1791575605\n||||||| 2f7e2f2\nmain side 1791575513\n=======\nmain side 1791575605\n>>>>>>> origin/main\n"
M.receiptsShown = table.concat({
	"import type { Receipt } from './types';",
	"",
	"<<<<<<< head",
	"export function addReceipt(store: Store, receipt: Receipt): void {",
	"  if (store.receipts.has(receipt.id)) return;",
	"=======",
	"export function addReceipt(store: Store, receipt: Receipt): void {",
	"  const bucket = store.receipts.get(receipt.coordinatorId);",
	">>>>>>> main",
	"}",
	"",
	"<<<<<<< head",
	"  return [...store.receipts.values()];",
	"=======",
	"  return [...store.receipts.values()].flatMap(bucket => [...bucket.values()]);",
	">>>>>>> main",
}, "\n") .. "\n"
M.storeShown = "export function createStore(): Store {\n<<<<<<< head\n  return { receipts: new Map<string, Receipt>() };\n=======\n  return { receipts: new Map<string, Map<string, Receipt>>() };\n>>>>>>> main\n}\n"
-- git log -1 --format=%H%x09%an%x09%s <merge base>..<base> -- <path>
M.smokeLog = "a134a7642f6f604fe0b0846bf3a542c09833141e\thub-smoke\tChange a file the conflicted branch changes\n"
M.receiptsLog = "0123456789abcdef0123456789abcdef01234567\tdevon\trefactor(session): receipts keyed by coordinator (#415)\n"
M.mergeCommitLog = "89abcdef0123456789abcdef0123456789abcdef\tdevon\tMerge pull request #416 from acme/receipts\n"

-- What `Fetch.readFixes` returns for the conflicted cases.
M.gitRead = {
	conflict = { mergeTree = M.smokeTree, shown = { ["smoke/conflict.txt"] = M.smokeShown }, logs = { ["smoke/conflict.txt"] = M.smokeLog }, files = {} },
	conflictMany = {
		mergeTree = M.manyTree,
		shown = { ["src/session/receipts.ts"] = M.receiptsShown, ["src/session/store.ts"] = M.storeShown },
		logs = { ["src/session/receipts.ts"] = M.receiptsLog, ["src/session/store.ts"] = M.mergeCommitLog },
		files = {},
	},
}

-- What the fixture block shows for these cases.json keys: which problem each Needs fixes card opens.
M.sample = {
	["acme/web#103"] = "requested", ["acme/web#104"] = "check", ["acme/web#111"] = "noann", ["acme/api#112"] = "conflictMany",
	["acme/web#101"] = "failure", ["acme/api#116"] = "requested",
} :: { [string]: string }

return M
