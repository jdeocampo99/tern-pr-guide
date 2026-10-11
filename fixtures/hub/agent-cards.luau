--!strict
-- Frozen lifecycle cards and events from #15's transcripts. No host or external effects.
local AgentFix = require("../../src/hub/agent-fix")
local Cases: any = require("./cases")
local Tree: any = require("./agent/treehouse")
local Tool: any = require("./agent/conflicts")
local Omp: any = require("./agent/omp")

local M = { asOf = Tree.asOf, asOfIso = "2026-10-10T00:00:00Z", prs = {}, agents = {}, runningKey = "acme/web#1802", runningStep = 4 }
M.keys = { idle = "acme/web#1801", running = M.runningKey, ready = "acme/web#1803", failed = "acme/web#1804", no_clone = "acme/web#1805", failed_no_worktree = "acme/web#1806" }

function M.spec(key: string): AgentFix.Spec
	return {
		key = key, clone = Tree.get.cwd, checkout = "/reader", pool = "/pool", branch = "topic", base = "main",
		headOid = string.rep("a", 40), number = tonumber(string.match(key, "#(%d+)$")) :: number,
		tool = "/plugin/tools/conflicts", omp = Omp.argv[1], model = Omp.argv[4], effort = "high",
	}
end

function M.run(key: string): AgentFix.Run
	return AgentFix.bind(AgentFix.start(key, M.asOf), M.spec(key))
end

function M.events(): { AgentFix.Event }
	return {
		{ kind = "stage", stage = "worktree" },
		{ kind = "worktree", path = Tree.get.reply.path },
		{ kind = "hunks", hunks = { Tool.transcript[2].reply, Tool.transcript[3].reply } },
		{ kind = "stage", stage = "agent" },
		{ kind = "resolved", id = "h2", by = "rule", lines = Tool.resolutions[2].lines },
		{ kind = "resolved", id = "h1", by = "agent", lines = Tool.resolutions[1].lines },
		{ kind = "stage", stage = "commit" },
		{ kind = "committed", commit = string.rep("b", 40), summary = Omp.stdout },
	}
end

local titles = {
	"Keep the promo code when a shipping change re-prices the cart and recalculates the retry budget",
	"Resolve the remaining conflicts while preserving the viewer's changes and the updated base branch",
	"Review the agent's resolved conflict commit in its retained worktree",
	"Retry a failed conflict resolution without losing the path to its worktree",
	"Choose a local clone before preparing an isolated agent worktree",
	"Retry worktree preparation after an agent fails before acquiring a lease",
}
local source = Cases.prs[1]
for i, title in titles do
	local pr = table.clone(source)
	pr.key, pr.repo, pr.number, pr.title = "acme/web#" .. (1800 + i), "acme/web", 1800 + i, title
	pr.url = "https://github.com/acme/web/pull/" .. pr.number
	pr.headOid, pr.baseBranch, pr.conflicts, pr.tandem, pr.mergeFailure = string.rep("a", 40), "main", true, false, nil
	table.insert(M.prs, pr)
end
local run = M.run(M.runningKey)
for i, event in M.events() do
	local outcome = AgentFix.step(run, event)
	if outcome.kind == "running" then
		run = outcome.run
		if i == M.runningStep then M.agents[M.runningKey] = outcome end
	elseif outcome.kind == "ready" then
		M.agents[M.keys.ready] = { kind = "ready", fix = outcome.fix, reviewed = {} }
	end
end
M.agents[M.keys.failed] = { kind = "failed", reason = "Agent exited before resolving the remaining hunk", worktree = Tree.get.reply.path }
M.agents[M.keys.failed_no_worktree] = { kind = "failed", reason = "No worktree was available" }
M.agents[M.keys.no_clone] = { kind = "no_clone", slug = "acme/web" }

return M
