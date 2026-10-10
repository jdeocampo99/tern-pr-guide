--!strict
-- The flake acceptance matrix (issue #13): one failing check per case, built from recorded and synthetic
-- GitHub JSON by the same parsers the hub uses, with the verdict `model.flake` must give and its reason.
-- Read by tests/flake_test.luau and, through `board`, by the fixture hub (fixture=cases).
-- raw-runs-main.json and raw-runs-sha.json were recorded from jubbydev/tern-pr-guide-hub-smoke; the busy-repo history,
-- the same-commit runs and the details nodes are SYNTHETIC (see their _note), because the smoke repo's main has no failures.
local Fixes = require("../../src/hub/fixes")
local Github = require("../../src/github")
local Model = require("../../src/hub/model")
local Details: any = require("./raw-flake-details")
local Busy: any = require("./raw-runs-busy")
local Rerun: any = require("./raw-runs-rerun")

export type Case = {
	name: string, -- the key in raw-flake-details
	row: string, -- the acceptance matrix row it covers
	history: string?, -- "busy" (the repo's main) or nil (not read)
	runs: string?, -- "rerun" (the runs of the PR's head) or nil (not read)
	flaky: boolean, basis: string?, reason: string?,
}

local M = {}

M.cases = {
	{ name = "timeout", row = "Infrastructure text: timeout", history = nil, runs = nil, flaky = true, basis = "text", reason = "the log shows the job timed out" },
	{ name = "reset", row = "Infrastructure text: ECONNRESET", history = nil, runs = nil, flaky = true, basis = "text", reason = "the log shows a network reset (ECONNRESET)" },
	{ name = "ratelimit", row = "Infrastructure text: rate limit", history = nil, runs = nil, flaky = true, basis = "text", reason = "the log shows a rate limit" },
	{ name = "lostrunner", row = "Infrastructure text: lost runner", history = nil, runs = nil, flaky = true, basis = "text", reason = "the log shows a lost runner" },
	{ name = "oom", row = "Infrastructure text: exit 137", history = nil, runs = nil, flaky = true, basis = "text", reason = "the log shows out of memory (exit 137)" },
	{ name = "history", row = "Failed 3 of the last 20 runs on main", history = "busy", runs = nil, flaky = true, basis = "history", reason = "failed 3 of the last 20 runs on main" },
	{ name = "history1", row = "Failed 1 of the last 20 runs on main, nothing else", history = "busy", runs = nil, flaky = false, basis = nil, reason = nil },
	{ name = "history2", row = "Failed 2 runs on main is not enough alone", history = "busy", runs = nil, flaky = false, basis = nil, reason = nil },
	{ name = "rerun", row = "Passed earlier on this same commit", history = nil, runs = "rerun", flaky = true, basis = "rerun", reason = "passed earlier on this commit" },
	{ name = "typeerror", row = "Type error in a changed file", history = nil, runs = nil, flaky = false, basis = nil, reason = "Error in src/lib/query-persister.ts, which this PR changed" },
	{ name = "typeerror_infra", row = "Type error in a changed file, with infrastructure text and main failures", history = "busy", runs = "rerun", flaky = false, basis = nil, reason = "Error in src/lib/query-persister.ts, which this PR changed" },
	{ name = "outside", row = "Errors only in files the PR didn't change", history = nil, runs = nil, flaky = true, basis = "outside_diff", reason = "errors only in files this PR didn't change" },
	{ name = "plain", row = "No annotations and no other evidence", history = nil, runs = nil, flaky = false, basis = nil, reason = nil },
} :: { Case }

-- The recorded history of main (the smoke repo's two approve runs: no failures) and the synthetic busy one.
M.history = {
	busy = Github.parseHistory(Busy, "main"),
	smoke = Github.parseHistory(require("./raw-runs-main"), "main"),
} :: { [string]: Github.RepoHistory }
M.rawBusy = Busy
M.rawRerun = Rerun
M.runs = { rerun = Github.parseRuns(Rerun) } :: { [string]: { Github.RunRow } }

-- The FixDetails of a case, and the evidence for its first failing check.
function M.details(case: Case): Fixes.FixDetails
	local pr = { key = "acme/web#" .. case.name } :: any
	return Github.parseDetails(Details[case.name], pr) :: Fixes.FixDetails
end

function M.evidence(case: Case): Model.FlakeEvidence
	local d = M.details(case)
	return Github.evidenceFor(d.checks[1], d.changedPaths, if case.history then M.history[case.history] else nil, if case.runs then M.runs[case.runs] else nil)
end

-- The fixture hub's Needs fixes cards with a failing check, and the case each shows: #111 is flaky and moves Re-run
-- first, #104 is a real type error (Fix with agent stays first), #112 is flaky but also conflicts.
M.board = {
	["acme/web#111"] = "history", ["acme/web#104"] = "typeerror", ["acme/api#112"] = "timeout",
} :: { [string]: string }

M.runIds = { ["acme/web#111"] = { 5107 }, ["acme/web#104"] = { 5110 }, ["acme/api#112"] = { 5101 } } :: { [string]: { number } }

return M
