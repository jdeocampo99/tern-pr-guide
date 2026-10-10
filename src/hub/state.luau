--!strict
-- The hub's interaction state (tab, selection, filter, sort, search, open menus) and the board
-- built from it. Views read `State.board` and never filter, sort or classify: every rule is `model`'s.
-- Pure: no clock, no network, no Tern. `now` is passed in.
local Fields = require("../text-field")
local AgentFix = require("./agent-fix")
local Fixes = require("./fixes")
local Links = require("../links")
local Model = require("./model")

type HubPR = Model.HubPR
type Tab = Model.Tab
type Column = Model.Column
type Sort = Model.Sort

-- The modules this one will require once they exist (sync, summary) are
-- not written yet. Their types the state needs are declared here with the same shapes as the spec's
-- contract, and the issue that adds each module replaces its placeholder with the module's own type.
export type Opened = { repo: string, number: number, title: string, author: string, at: string } -- sync.Opened
export type Summary = { verdict: string, comments: { { author: string, text: string } } } -- summary.Summary
export type FixDetails = Fixes.FixDetails

export type Mode = "board" | "search" | "link" | "menu" | "confirm" | "help" | "fixes" | "reply"
export type MenuId = "repositories" | "sort" | "agent" | "merge" | "actions"
export type Ring = "bad" | "good" | "bad-out" | "good-out" -- red ring, green wash, then the same fading
-- What the flake evidence says about a card's failing checks, for the commit it was read on. `runs` are the workflow
-- runs Re-run failed checks sends `gh run rerun` to, once each.
export type Flake = { flaky: boolean, reason: string?, runs: { number }, headOid: string }
export type CardAction = { act: string, value: string?, label: string, key: string?, confirm: boolean }

export type AgentFixState =
	{ kind: "no_clone", slug: string }
	| { kind: "running", run: AgentFix.Run }
	| { kind: "ready", fix: AgentFix.Fix, reviewed: { [string]: boolean } }
	| { kind: "pushing", fix: AgentFix.Fix }
	| { kind: "failed", reason: string, worktree: string? }

-- A pill on a card's chip line. `kind` picks its look; `running` carries the amber spinner.
export type Chip = { text: string, kind: "bad" | "bad-soft" | "info" | "wait" | "done" | "agent" | "running" }

export type Card = {
	pr: HubPR,
	chips: { Chip }, -- the job, or who the card waits on; empty on done cards
	detail: string?, -- the first job's detail, after the chips
	detailKind: ("bad" | "info")?, -- the detail's color: red on your PRs, blue on review requests
	column: Column,
	reasons: { Model.Reason },
	flake: string?, -- "Likely flaky: failed 3 of the last 20 runs on main", shown under the title
	main: CardAction?, -- the split button's action
	more: { CardAction }, -- behind the attached ▾
	agent: AgentFixState?,
	agentSlot: boolean, -- a reserved two-line note region, including before a fix starts
	agentMessage: string?, agentPath: string?, agentCommit: string?,
	summary: Summary?,
	merge: Model.MergeResolution?,
	note: string?, -- a merge in flight ("Commented /merge · waiting for the merge"); shown under the title
	asking: string?, -- an inline question the card is waiting on ("Squash and merge #412?"); the split button gives way to Confirm and Cancel
	busy: string?, -- an action in flight ("Merging…"); the split button gives way to it
	ring: Ring?, -- the arrival ring or wash; the "-out" kinds are fading
	selected: boolean,
	marked: boolean,
}
-- The selection bar over the group being selected, and its confirm once M or X was pressed.
export type BatchRow = { ref: string, title: string } -- "web #412" and its title
export type BatchConfirm = { question: string, rows: { BatchRow }, more: number, lines: { string }, go: string, act: string }
export type Selection = { group: Model.Group, count: number, verb: string, key: string, act: string, confirm: BatchConfirm? }
export type MethodEdit = { repo: string, kind: "comment" | "label", field: Fields.Field }
export type RepoOption = { repo: string, count: number, on: boolean }

-- Everything a view reads, built by `project`.
export type BoardData = {
	tab: Tab,
	columns: { { column: Column, cards: { Card } } }, -- the tab's columns, left to right, filtered and ordered
	inactive: { Card }, -- the fold under "Your pull requests"
	recent: { Opened }, -- the fold under "Review requests"
	open: { inactive: boolean, recent: boolean }, -- which folds show their rows
	grid: { { string } }, -- keys per column, for h j k l
	counts: { mine: number, review: number }, -- your-turn cards per tab: the blue counts
	repositories: { RepoOption },
	nextUp: Model.NextUp?,
	empty: boolean,
}

-- The agent's model and effort for fixes, summaries and guides; the models it can pick from.
export type AgentModel = { selector: string, name: string, efforts: { string } }
export type AgentChoice = { models: { AgentModel }, model: string, effort: string? }

-- The fixes page, open on the Needs fixes card `key`. Its steps come from `s.details[key]` and the card's PR.
export type Route = {
	kind: "fixes",
	key: string,
	cur: number, -- the step on show, 1-based
	focus: "steps" | "panel", -- h and l move between the two
	item: number, -- the panel's highlighted action, 1-based
	loading: boolean, -- details are on their way
	error: string?, -- why they could not be read
	bots: boolean, -- the "Not counted" bot note is open
	resolved: { [string]: boolean }, -- thread ids resolved from the page
	replies: { [string]: { string } }, -- replies posted from the page, by thread id
	reply: Fields.Field?, -- the reply being written (mode "reply")
	busy: boolean, -- a reply or resolve is in flight
}

export type State = {
	prs: { HubPR },
	now: number,
	board: BoardData, -- rebuilt by `project` after any input below changes
	tab: Tab,
	selected: string?,
	marked: { [string]: boolean },
	repositories: { [string]: boolean }?,
	sort: Sort,
	search: Fields.Field,
	link: Fields.Field,
	mode: Mode,
	route: Route?, -- the fixes page, while it is open
	menu: MenuId?,
	menuCursor: number,
	confirm: { kind: string, keys: { string } }?, -- kind "merge" (a GitHub method) or "learned" (a suggested comment command)
	methodEdit: MethodEdit?, -- the merge menu is asking for a command or a label
	folded: { [string]: boolean }, -- true: the fold is closed. Inactive and Recently opened start closed
	recent: { Opened }, -- hub.recent, newest first; the block sets it, `project` builds the Review requests fold from it
	walking: boolean, -- Next up is being walked: the banner shows "2 of 11"
	ringed: { [string]: Ring },
	agents: { [string]: AgentFixState },
	details: { [string]: FixDetails },
	flakes: { [string]: Flake }, -- by card key; the block reads the evidence, so a card without one has no label
	summaries: { [string]: Summary },
	merges: { [string]: Model.MergeResolution }, -- by repo
	autoMerge: { [string]: boolean }, -- by repo: its "Allow auto-merge" setting, once detection has read it
	acted: { [string]: boolean }, -- cards the viewer just acted on (merged, updated): their arrival is not toasted
	busy: { [string]: string }, -- by card key: the action in flight
	refreshedAt: string?,
	loading: boolean,
	error: Model.Error?,
	agent: AgentChoice?, -- nil until the block has found the agent
	keyed: boolean, -- the change being drawn came from a key: it never animates
	born: { [string]: string },
	booted: boolean, -- arrival motion, as src/state.luau
}

export type MenuRow = { label: string, sub: string?, count: number?, on: boolean, kind: "choice" | "check" | "clear" }

local M = {}

-- Lifecycle data only. The block owns the engine, cancellation and lease effects.
function M.agentRunning(s: State): string?
	for key, agent in s.agents do
		if agent.kind == "running" then return key end
	end
	return nil
end

function M.beginAgent(s: State, key: string, now: number): boolean
	local previous = s.agents[key]
	if M.agentRunning(s) or (previous and (previous.kind == "ready" or previous.kind == "pushing")) then return false end
	if not M.prOf(s, key) then return false end
	s.agents[key] = { kind = "running", run = AgentFix.start(key, now) }
	M.project(s)
	return true
end

function M.agentOutcome(s: State, key: string, outcome: AgentFix.Outcome): boolean
	local current = s.agents[key]
	-- Terminal and duplicate callbacks cannot resurrect a stopped or settled run.
	if not current or current.kind ~= "running" then return false end
	if outcome.kind == "running" then
		if outcome.run.key ~= key then return false end
		s.agents[key] = { kind = "running", run = outcome.run }
	elseif outcome.kind == "ready" then
		s.agents[key] = { kind = "ready", fix = outcome.fix, reviewed = {} }
	elseif outcome.kind == "failed" then
		s.agents[key] = { kind = "failed", reason = outcome.reason, worktree = outcome.worktree or current.run.worktree }
	else
		s.agents[key] = nil
	end
	M.project(s)
	return true
end

function M.agentEvent(s: State, key: string, event: AgentFix.Event): boolean
	local current = s.agents[key]
	if not current or current.kind ~= "running" then return false end
	return M.agentOutcome(s, key, AgentFix.step(current.run, event))
end

function M.noAgentClone(s: State, key: string, slug: string)
	s.agents[key] = { kind = "no_clone", slug = slug }
	M.project(s)
end

function M.agentFailed(s: State, key: string, reason: string, worktree: string?)
	s.agents[key] = { kind = "failed", reason = reason, worktree = worktree }
	M.project(s)
end

-- An ephemeral snapshot from Block, never stored in State. A terminal event's path
-- describes where work happened; only the engine's held lease proves current ownership.
export type AgentFlightFacts = {
	settled: boolean, starting: boolean, releasing: boolean, busy: boolean, worktree: string?,
}

function M.agentFlight(s: State, key: string, facts: AgentFlightFacts): "wait" | "release" | "forget" | "ready"
	local agent = s.agents[key]
	if agent and (agent.kind == "ready" or agent.kind == "pushing") then return "ready" end
	if agent and agent.kind == "failed" and agent.worktree ~= facts.worktree then
		agent.worktree = facts.worktree
		M.project(s)
	end
	if not facts.settled or facts.starting or facts.releasing then return "wait" end
	-- busy may be false after settlement even when the lease return failed.
	if facts.worktree then return "release" end
	if facts.busy then return "wait" end
	return "forget"
end

-- Closing stops only running fixes. Ready worktrees and their leases belong to #16.
function M.closeAgent(s: State): string?
	local key = M.agentRunning(s)
	if key then M.agentOutcome(s, key, { kind = "stopped" }) end
	return key
end

function M.reviewed(fix: AgentFix.Fix, reviewed: { [string]: boolean }): boolean
	for _, hunk in fix.hunks do
		if reviewed[hunk.id] ~= true then return false end
	end
	return true
end

local STAGES: { [AgentFix.Stage]: string } = {
	worktree = "Preparing worktree…", merge = "Merging base branch…", rules = "Regenerating files…",
	agent = "Resolving conflicts…", commit = "Committing fix…",
}

function M.agentMessage(agent: AgentFixState): (string, string?, string?)
	if agent.kind == "running" then return STAGES[agent.run.stage], agent.run.worktree, nil end
	if agent.kind == "no_clone" then return "No local copy of " .. agent.slug, nil, nil end
	if agent.kind == "failed" then
		local reason = string.match(agent.reason, "^Couldn't [^:]*: (.*)$") or agent.reason
		return "Couldn't fix pull request: " .. Fixes.firstLine(reason), agent.worktree, nil
	end
	local fix = agent.fix
	return string.sub(fix.commit, 1, 7) .. " · " .. Fixes.firstLine(fix.summary), fix.worktree, string.sub(fix.commit, 1, 7)
end

local askingOf: (s: State, pr: HubPR) -> string?

M.TABS = {
	{ id = "mine" :: Tab, label = "Your pull requests" },
	{ id = "review" :: Tab, label = "Review requests" },
}

M.COLUMNS = {
	mine = { "needs_fixes", "in_review", "ready" },
	review = { "to_review", "waiting_on_author", "approved" },
} :: { [Tab]: { Column } }

M.SORTS = {
	{ id = "repository" :: Sort, label = "Repository", sub = "Priority within each" },
	{ id = "priority" :: Sort, label = "Priority", sub = "What to do first" },
	{ id = "newest" :: Sort, label = "Newest first", sub = "Most recently opened" },
	{ id = "oldest" :: Sort, label = "Oldest first", sub = "Waiting longest" },
	{ id = "smallest" :: Sort, label = "Smallest first", sub = "Fewest lines changed" },
}

local function emptyBoard(tab: Tab): BoardData
	return {
		tab = tab, columns = {}, inactive = {}, recent = {}, open = { inactive = false, recent = false },
		grid = {}, counts = { mine = 0, review = 0 }, repositories = {}, nextUp = nil, empty = true,
	}
end

local function validTab(value: any): Tab?
	if value == "mine" or value == "review" then return value end
	return nil
end

local function validSort(value: any): Sort?
	for _, sort in M.SORTS do
		if sort.id == value then return sort.id end
	end
	return nil
end

-- `saved` is what the block's `save` returned last time (tab, sort, repositories, folded), or anything at all.
function M.new(prs: { HubPR }, now: number, saved: any): State
	local tab: Tab = "mine"
	local sort: Sort = "repository"
	local repositories: { [string]: boolean }? = nil
	local folded: { [string]: boolean } = { inactive = true, recent = true }
	if type(saved) == "table" then
		tab = validTab(saved.tab) or tab
		sort = validSort(saved.sort) or sort
		if type(saved.repositories) == "table" and #saved.repositories > 0 then
			local set: { [string]: boolean } = {}
			for _, repo in saved.repositories do
				if type(repo) == "string" then set[repo] = true end
			end
			repositories = set
		end
		if type(saved.folded) == "table" then
			for name, value in saved.folded do
				if type(name) == "string" and type(value) == "boolean" then folded[name] = value end
			end
		end
	end
	local s: State = {
		prs = prs, now = now, board = emptyBoard(tab), tab = tab, selected = nil, marked = {},
		repositories = repositories, sort = sort, search = Fields.create(""), link = Fields.create(""),
		mode = "board", route = nil, menu = nil, menuCursor = 1, confirm = nil, methodEdit = nil, folded = folded, recent = {}, walking = false,
		ringed = {}, agents = {}, details = {}, flakes = {}, summaries = {}, merges = {}, autoMerge = {}, acted = {}, busy = {},
		refreshedAt = nil, loading = false, error = nil, agent = nil,
		keyed = false, born = {}, booted = false,
	}
	M.project(s)
	return s
end

-- Swaps in a refresh's pull requests: records the time, clears loading and the error, and rebuilds the board.
function M.replace(s: State, prs: { HubPR }, now: number, refreshedAt: string?)
	s.prs, s.now, s.refreshedAt = prs, now, refreshedAt
	s.loading, s.error = false, nil
	M.project(s)
end

-- Sets the Recently opened list (hub.recent) and rebuilds the board.
function M.setRecent(s: State, recent: { Opened })
	s.recent = recent
	M.project(s)
end

-- The block's reading of the flake evidence for card `key` (nil forgets it, as after a re-run). The cards follow.
function M.setFlake(s: State, key: string, flake: Flake?)
	s.flakes[key] = flake
	M.project(s)
end

-- The flake evidence on hand for `key`, while it is for the commit now at the head.
function M.flakeOf(s: State, key: string): Flake?
	local pr = M.prOf(s, key)
	local flake = s.flakes[key]
	if pr and flake and flake.headOid == pr.headOid then return flake end
	return nil
end

-- What a saved state holds, for the block's `save`.
function M.saved(s: State): { tab: Tab, sort: Sort, repositories: { string }?, folded: { [string]: boolean } }
	local repositories: { string }? = nil
	if s.repositories then
		local list: { string } = {}
		for repo in s.repositories do table.insert(list, repo) end
		table.sort(list)
		repositories = list
	end
	return { tab = s.tab, sort = s.sort, repositories = repositories, folded = s.folded }
end

-- The actions a card offers, from the spec's "Cards and actions" table. Keys are the shortcuts the
-- selected card answers to. Only the pieces that exist at this stage of the hub are listed.
local function action(act: string, label: string, key: string?): CardAction
	return { act = act, value = nil, label = label, key = key, confirm = false }
end

local function actionsFor(pr: HubPR, column: Column, reasons: { Model.Reason }, merge: Model.MergeResolution?, flake: Flake?, autoMerge: boolean?): (CardAction?, { CardAction })
	if column == "needs_fixes" then
		local feedback, checks = false, false
		for _, reason in reasons do
			if reason == "feedback" then feedback = true end
			if reason == "checks" then checks = true end
		end
		local main, more
		if feedback and #reasons == 1 then
			main, more = action("card-summarize", "Summarize", "A"), {}
		else
			main = if pr.tandem then action("card-handoff", "Hand off to Tandem", "A") else action("card-agent", "Fix with agent", "A")
			more = if feedback then { action("card-summarize", "Summarize", "⇧A") } else {}
		end
		if checks then
			-- Behind Fix checks ▾ for every failing check. It moves first only when the evidence says flaky and the
			-- checks are all that is wrong; the agent stays first when an annotation points at a changed file.
			local rerun = action("card-rerun", "Re-run failed checks", "⇧R")
			if flake and flake.flaky and #reasons == 1 then
				table.insert(more, 1, main :: CardAction)
				return rerun, more
			end
			table.insert(more, rerun)
		end
		return main, more
	elseif column == "in_review" then
		local copy = action("card-copy", "Copy link", "C")
		local main, more = copy, {}
		-- A reviewer waits on the author to say the fix is in: asking again is the card's job until they have been asked.
		local again = Model.awaitingReReview(pr)
		if again and #again.ask > 0 then
			main, more = action("card-rerequest", "Re-request review", "Q"), { copy }
		end
		if pr.pending then
			local method = if merge then merge.method else nil
			if not (method and method.kind == "comment" and not method.cancel) then
				table.insert(more, action("card-cancel", "Cancel merge", "M"))
			end
		elseif Model.canMergeWhenReady(merge, autoMerge) then
			table.insert(more, action("card-auto", "Merge when ready", "M"))
		end
		return main, more
	elseif column == "ready" then
		if pr.pending then
			-- A merge in flight: only Cancel merge, and only when the method can be taken back.
			local method = if merge then merge.method else nil
			if method and method.kind == "comment" and not method.cancel then return nil, {} end
			return action("card-cancel", "Cancel merge", "M"), {}
		end
		if pr.behind then return action("card-update", "Update branch", "U"), { action("card-method", "Merge method", ",") } end
		return action("card-merge", "Merge", "M"), { action("card-method", "Merge method", ",") }
	elseif column == "to_review" then
		return action("open", "Review", "⏎"), if pr.addedByMe then { action("card-remove", "Remove from Review requests", "X") } else {}
	end
	return nil, {}
end

local function chip(text: string, kind: "bad" | "bad-soft" | "info" | "wait" | "done" | "agent" | "running"): Chip
	return { text = text, kind = kind }
end

-- The chip line's labels and detail text, from the mockup's job names.
local function chipsFor(pr: HubPR, placement: Model.Placement, now: number): ({ Chip }, string?, ("bad" | "info")?)
	local column = placement.column
	local chips: { Chip } = {}
	local detail: string? = nil
	local kind: ("bad" | "info")? = nil
	if column == "needs_fixes" then
		kind = "bad"
		local function add(text: string, why: string)
			table.insert(chips, chip(text, "bad"))
			if detail == nil then detail = why end
		end
		for _, reason in placement.reasons do
			if reason == "merge_failed" then
				add("Merge failed", if pr.mergeFailure then pr.mergeFailure.reason else "Merge failed")
			elseif reason == "feedback" then
				local asker: string? = nil
				for _, review in pr.reviews.latest do
					if review.verdict == "changes_requested" and not review.bot then asker = review.author end
				end
				local open = 0
				if pr.reviews.threadsKnown then
					for _, thread in pr.reviews.threads do
						if not thread.bot then open += 1 end
					end
				else
					open = pr.reviews.unresolved
				end
				if asker then add("Address changes", "Changes requested by @" .. asker) end
				if open > 0 or not asker then add("Reply", open .. (if open == 1 then " unresolved comment" else " unresolved comments")) end
			elseif reason == "checks" then
				local total = pr.checks.passing + pr.checks.failing + pr.checks.pending
				add("Fix checks", pr.checks.failing .. "/" .. total .. (if total == 1 then " check failing" else " checks failing"))
			elseif reason == "conflict" then
				add("Resolve conflicts", "Conflicts with main")
			end
		end
	elseif column == "to_review" then
		kind = "info"
		local mine = pr.reviews.mine
		if mine and mine.oid ~= pr.headOid and not pr.reviews.requestedMe then
			table.insert(chips, chip("Re-review", "info"))
			detail = "New commits since you " .. (if mine.verdict == "approved" then "approved" else "reviewed")
		else
			table.insert(chips, chip("Review", "info"))
			if pr.reviews.requestedMe then
				detail = "@" .. pr.author .. " asked " .. Model.ago(pr.lastActivityAt, now)
			elseif pr.addedByMe then
				detail = "Added by you"
			end
		end
	elseif column == "in_review" then
		local again = Model.awaitingReReview(pr)
		if pr.tandem then
			table.insert(chips, chip("Waiting on Tandem", "agent"))
		elseif again then
			table.insert(chips, chip("Waiting on " .. Model.reviewerList(again.waiting) .. " to re-review", "wait"))
		elseif pr.checks.state == "pending" then
			table.insert(chips, chip("Waiting on checks", "running"))
		else
			table.insert(chips, chip("Waiting on review", "wait"))
		end
	elseif column == "waiting_on_author" then
		local mine = pr.reviews.mine
		if mine and mine.verdict == "changes_requested" then
			table.insert(chips, chip("You requested changes", "bad-soft"))
		else
			table.insert(chips, chip("You commented", "wait"))
		end
	elseif column == "inactive" then
		table.insert(chips, chip(if pr.draft then "Draft" else "No recent activity", "wait"))
	end
	return chips, detail, kind
end

local MERGE_LABELS: { [string]: string } = { squash = "Squash and merge", merge = "Create a merge commit", rebase = "Rebase and merge" }

-- The repo's GitHub merge method: the resolved one when it is squash, merge or rebase, else squash
-- (viewerDefaultMergeMethod arrives with the method detection).
function M.mergeMethodFor(s: State, pr: HubPR): "squash" | "merge" | "rebase"
	local resolved = s.merges[pr.repo]
	local kind = if resolved then resolved.method.kind else "squash"
	if kind == "merge" or kind == "rebase" then return kind end
	return "squash"
end

function M.mergeLabel(kind: string): string
	return MERGE_LABELS[kind] or MERGE_LABELS.squash
end

-- What a merge in flight reads on its card.
function M.pendingNote(s: State, pr: HubPR): string?
	local pending = pr.pending
	if not pending then return nil end
	local resolved = s.merges[pr.repo]
	local method = if resolved then resolved.method else nil
	-- Asked for before the PR is ready: whatever the method, it merges by itself once approved and green.
	if Model.classify(pr, s.now) == "in_review" then return "Merges when ready" end
	if pending.method == "queue" then return "In the merge queue" end
	if pending.method == "label" then
		return "Labeled " .. (if method and method.kind == "label" then method.label else "for merge") .. " · waiting for the merge"
	end
	local command = if method and method.kind == "comment" then method.command else "/merge"
	if string.sub(command, 1, 8) == "/aviator" then return "Queued in Aviator" end
	return "Commented " .. command .. " · waiting for the merge"
end

-- What M does on a card: a GitHub method asks first ("confirm"), a suggested comment asks once ("ask"), and
-- a method the repo or the viewer chose (comment, label, queue) just runs: it can be cancelled.
function M.mergeStep(s: State, pr: HubPR): "confirm" | "ask" | "run"
	local resolved = s.merges[pr.repo]
	if resolved == nil then return "confirm" end
	local kind = resolved.method.kind
	if resolved.ask then return "ask" end
	if kind == "squash" or kind == "merge" or kind == "rebase" then return "confirm" end
	return "run"
end

function askingOf(s: State, pr: HubPR): string?
	local confirm = s.confirm
	if confirm and confirm.keys[1] == pr.key then
		if confirm.kind == "merge" then return M.mergeLabel(M.mergeMethodFor(s, pr)) .. " #" .. pr.number .. "?" end
		local resolved = s.merges[pr.repo]
		if confirm.kind == "learned" and resolved and resolved.method.kind == "comment" then
			return "Comment " .. resolved.method.command .. ", as this repository usually does?"
		end
	end
	return nil
end

local function toCard(pr: HubPR, placement: Model.Placement, s: State): Card
	local known = s.flakes[pr.key]
	local flake = if known and known.headOid == pr.headOid then known else nil
	local main, more = actionsFor(pr, placement.column, placement.reasons, s.merges[pr.repo], flake, s.autoMerge[pr.repo])
	local chips, detail, detailKind = chipsFor(pr, placement, s.now)
	local agent = s.agents[pr.key]
	local message: string? = nil
	local path: string? = nil
	local commit: string? = nil
	if agent then
		message, path, commit = M.agentMessage(agent)
		detail, detailKind = nil, nil
		if agent.kind == "running" then
			main, more, chips = action("card-agent-stop", "Stop", "A"), {}, { chip("Agent running", "agent") }
		elseif agent.kind == "no_clone" then
			main, more, chips = action("card-agent-clone", "Clone repo", "A"), { action("card-agent-folder", "Choose folder…", "O") }, { chip("No local clone", "wait") }
		elseif agent.kind == "failed" then
			main, more, chips = action("card-agent-retry", "Try again", "A"), {}, { chip("Fix failed", "bad-soft") }
			if agent.worktree then table.insert(more, action("card-agent-worktree", "Open worktree", "O")) end
		else
			-- Review, Discard and Push are deliberately left to #16.
			main, more, chips = nil, {}, { chip(if agent.kind == "ready" then "Fix ready" else "Pushing fix…", "done") }
		end
	end
	return {
		flake = if flake and flake.flaky and flake.reason then "Likely flaky: " .. flake.reason else nil,
		pr = pr, chips = chips, detail = detail, detailKind = detailKind, column = placement.column, reasons = placement.reasons, main = main, more = more,
		agent = agent, agentSlot = agent ~= nil or placement.column == "needs_fixes",
		agentMessage = message, agentPath = path, agentCommit = commit,
		summary = s.summaries[pr.key], merge = s.merges[pr.repo], note = M.pendingNote(s, pr),
		asking = askingOf(s, pr), busy = s.busy[pr.key],
		ring = s.ringed[pr.key], selected = s.selected == pr.key, marked = s.marked[pr.key] == true,
	}
end

local function shortRepo(repo: string): string
	return string.match(repo, "[^/]+$") or repo
end

-- The key a Recently opened row is selected and clicked by. A card's key is a node id, so the two never clash.
function M.recentKey(opened: Opened): string
	return "rc:" .. string.lower(opened.repo) .. "#" .. opened.number
end

local function recentMatches(opened: Opened, needle: string): boolean
	for _, text in { "#" .. opened.number, opened.title, opened.author, opened.repo } do
		if string.find(string.lower(text), needle, 1, true) then return true end
	end
	return false
end

-- Rebuilds the Next up banner's data: the item after the selection while walking, else the first.
local function refreshNext(s: State)
	s.board.nextUp = Model.nextUp(s.prs, s.now, if s.walking then s.selected else nil)
end

-- A mark lasts while its card is still selectable, in this tab, matches the filter and, for Inactive, shows.
-- Marks are of one group: a refresh that leaves two groups (a Ready card went behind main) keeps the first's.
local function pruneMarks(s: State, byKey: { [string]: HubPR }, placements: { [string]: Model.Placement }, filter: Model.Filter, foldOpen: boolean)
	if next(s.marked) == nil then return end
	local group: Model.Group? = nil
	for _, column in s.board.columns do
		for _, card in column.cards do
			if s.marked[card.pr.key] and group == nil then group = Model.selectGroup(card.pr, s.now) end
		end
	end
	if group == nil then
		for _, card in s.board.inactive do
			if s.marked[card.pr.key] and group == nil then group = Model.selectGroup(card.pr, s.now) end
		end
	end
	local kept: { [string]: boolean } = {}
	for key in s.marked do
		local pr = byKey[key]
		if pr and placements[key].tab == s.tab and Model.visible(pr, filter) then
			local own = Model.selectGroup(pr, s.now)
			if own ~= nil and own == group and (own == "ready" or foldOpen) then kept[key] = true end
		end
	end
	s.marked = kept
	if next(kept) == nil and s.confirm and (s.confirm.kind == "batch-merge" or s.confirm.kind == "batch-close") then
		s.confirm = nil
		if s.mode == "confirm" then s.mode = "board" end
	end
	for _, column in s.board.columns do
		for _, card in column.cards do card.marked = kept[card.pr.key] == true end
	end
	for _, card in s.board.inactive do card.marked = kept[card.pr.key] == true end
end

-- Recomputes `s.board` from `s.prs` and the inputs. Keeps the selection only while its card is on the board.
function M.project(s: State)
	local filter: Model.Filter = { repositories = s.repositories, search = s.search.text }
	local placements: { [string]: Model.Placement } = {}
	local counts = { mine = 0, review = 0 }
	local inTab: { HubPR } = {}
	local byKey: { [string]: HubPR } = {}
	for _, pr in s.prs do
		local placement = Model.placement(pr, s.now)
		placements[pr.key] = placement
		byKey[pr.key] = pr
		if Model.visible(pr, filter) then
			if placement.column == "needs_fixes" then counts.mine += 1 end
			if placement.column == "to_review" then counts.review += 1 end
			if placement.tab == s.tab then table.insert(inTab, pr) end
		end
	end

	local columns: { { column: Column, cards: { Card } } } = {}
	local grid: { { string } } = {}
	local present: { [string]: boolean } = {}
	local total = 0
	for _, column in M.COLUMNS[s.tab] do
		local cards: { Card } = {}
		local keys: { string } = {}
		for _, pr in Model.order(inTab, column, s.sort, s.now) do
			table.insert(cards, toCard(pr, placements[pr.key], s))
			table.insert(keys, pr.key)
			present[pr.key] = true
		end
		total += #cards
		table.insert(columns, { column = column, cards = cards })
		table.insert(grid, keys)
	end
	local inactive: { Card } = {}
	if s.tab == "mine" then
		for _, pr in Model.order(inTab, "inactive", s.sort, s.now) do
			table.insert(inactive, toCard(pr, placements[pr.key], s))
		end
	end
	-- The fold opens on its own while a search is typed, so its matches show.
	local searching = s.search.text ~= ""
	local foldOpen = #inactive > 0 and (not s.folded.inactive or searching)
	if foldOpen then
		for _, card in inactive do present[card.pr.key] = true end
	end

	-- Recently opened: under Review requests only, narrowed by the search, open on its own while a search finds some.
	local recent: { Opened } = {}
	if s.tab == "review" then
		local needle = string.lower(s.search.text)
		for _, opened in s.recent do
			if needle == "" or recentMatches(opened, needle) then table.insert(recent, opened) end
		end
	end
	local recentOpen = #recent > 0 and (not s.folded.recent or searching)
	if recentOpen then
		for _, opened in recent do present[M.recentKey(opened)] = true end
	end

	-- Every repository in this tab that the search matches, most pull requests first. A chosen repository
	-- with nothing left to show stays listed, so it can be unchosen.
	local counted: { [string]: number } = {}
	for _, pr in s.prs do
		if placements[pr.key].tab == s.tab and Model.visible(pr, { repositories = nil, search = s.search.text }) then
			counted[pr.repo] = (counted[pr.repo] or 0) + 1
		end
	end
	if s.repositories then
		for repo in s.repositories do counted[repo] = counted[repo] or 0 end
	end
	local repositories: { RepoOption } = {}
	for repo, count in counted do
		table.insert(repositories, { repo = repo, count = count, on = s.repositories ~= nil and s.repositories[repo] == true })
	end
	table.sort(repositories, function(a: RepoOption, b: RepoOption): boolean
		if a.count ~= b.count then return a.count > b.count end
		return string.lower(shortRepo(a.repo)) < string.lower(shortRepo(b.repo))
	end)

	s.board = {
		tab = s.tab, columns = columns, inactive = inactive, recent = recent,
		open = { inactive = foldOpen, recent = recentOpen },
		grid = grid, counts = counts, repositories = repositories, nextUp = nil,
		empty = total == 0 and #inactive == 0 and #recent == 0,
	}
	if s.selected and not present[s.selected] then s.selected = nil end
	if not s.selected then s.walking = false end
	refreshNext(s)
	pruneMarks(s, byKey, placements, filter, foldOpen)
end

function M.mode(s: State): Mode
	return s.mode
end

-- The card with `key` on the board.
function M.card(s: State, key: string): Card?
	for _, column in s.board.columns do
		for _, card in column.cards do
			if card.pr.key == key then return card end
		end
	end
	for _, card in s.board.inactive do
		if card.pr.key == key then return card end
	end
	return nil
end

-- The Recently opened row with `key`, while that fold shows its rows.
function M.recentRow(s: State, key: string): Opened?
	if s.board.open.recent then
		for _, opened in s.board.recent do
			if M.recentKey(opened) == key then return opened end
		end
	end
	return nil
end

-- The selected Recently opened row, if one is selected.
function M.selectedRecent(s: State): Opened?
	if s.selected then return M.recentRow(s, s.selected) end
	return nil
end

function M.selectedCard(s: State): Card?
	if s.selected then return M.card(s, s.selected) end
	return nil
end

local function refreshSelection(s: State)
	for _, column in s.board.columns do
		for _, card in column.cards do card.selected = card.pr.key == s.selected end
	end
	for _, card in s.board.inactive do card.selected = card.pr.key == s.selected end
end

function M.select(s: State, key: string?)
	-- Choosing another card drops an inline question about the first, and leaves the add field.
	if s.confirm and s.confirm.kind ~= "batch-merge" and s.confirm.kind ~= "batch-close" and (key == nil or s.confirm.keys[1] ~= key) then M.cancelConfirm(s) end
	if s.mode == "link" and key ~= nil then s.mode = "board" end
	s.selected = key
	s.walking = false
	refreshSelection(s)
	refreshNext(s)
end

-- Moves the selection one step: "down" and "up" within a column (down from the last card enters the open
-- Inactive fold; up from its first card returns), "left" and "right" to the card at the same height in the
-- next column that has any. Nothing selected: any direction selects the first card of the first column.
function M.move(s: State, direction: "up" | "down" | "left" | "right"): boolean
	local grid = s.board.grid
	local fold: { string } = {}
	if s.board.open.inactive then
		for _, card in s.board.inactive do table.insert(fold, card.pr.key) end
	end
	if s.board.open.recent then
		for _, opened in s.board.recent do table.insert(fold, M.recentKey(opened)) end
	end
	local selected = s.selected
	local function go(key: string): boolean
		if key == selected then return false end
		M.select(s, key)
		return true
	end
	if selected == nil then
		for _, keys in grid do
			if #keys > 0 then return go(keys[1]) end
		end
		if #fold > 0 then return go(fold[1]) end
		return false
	end
	local inFold = table.find(fold, selected)
	if inFold then
		if direction == "down" then return go(fold[math.min(#fold, inFold + 1)]) end
		if direction == "up" then
			if inFold > 1 then return go(fold[inFold - 1]) end
			for index = 1, #grid do
				local keys = grid[index]
				if #keys > 0 then return go(keys[#keys]) end
			end
		end
		return false
	end
	local column, row = 0, 0
	for index, keys in grid do
		local at = table.find(keys, selected)
		if at then column, row = index, at end
	end
	if column == 0 then return false end
	local keys = grid[column]
	if direction == "down" then
		if row == #keys and #fold > 0 then return go(fold[1]) end
		return go(keys[math.min(#keys, row + 1)])
	elseif direction == "up" then
		return go(keys[math.max(1, row - 1)])
	end
	local step = if direction == "right" then 1 else -1
	local index = column + step
	while index >= 1 and index <= #grid do
		local next = grid[index]
		if #next > 0 then return go(next[math.min(#next, row)]) end
		index += step
	end
	return false
end

function M.setTab(s: State, tab: Tab)
	if s.tab == tab then return end
	s.tab = tab
	M.project(s)
	refreshSelection(s)
end

function M.switchTab(s: State)
	M.setTab(s, if s.tab == "mine" then "review" else "mine")
end

function M.setSort(s: State, sort: Sort)
	s.sort = sort
	M.project(s)
end

-- Chooses or unchooses `repo`; with none chosen every repository shows.
function M.toggleRepository(s: State, repo: string)
	local set: { [string]: boolean } = {}
	if s.repositories then
		for name in s.repositories do set[name] = true end
	end
	if set[repo] then set[repo] = nil else set[repo] = true end
	s.repositories = if next(set) == nil then nil else set
	M.project(s)
end

function M.clearRepositories(s: State)
	s.repositories = nil
	M.project(s)
end

-- Replaces the search text (tests, and a cleared field).
function M.setSearch(s: State, text: string)
	s.search = Fields.create(text)
	M.project(s)
end

-- A key typed into the search field changed its text.
function M.searched(s: State)
	M.project(s)
end

function M.openSearch(s: State)
	s.mode = "search"
	s.menu = nil
end

-- Leaves the search field; `clear` also empties it (Esc).
function M.closeSearch(s: State, clear: boolean)
	s.mode = "board"
	if clear and s.search.text ~= "" then M.setSearch(s, "") end
end

function M.toggleFold(s: State, name: string)
	s.folded[name] = not s.folded[name]
	M.project(s)
end

-- The card the Next up banner shows: the next item as a board card, whichever tab it sits on.
function M.nextCard(s: State): Card?
	local next = s.board.nextUp
	if not next then return nil end
	for _, pr in s.prs do
		if pr.key == next.item.key then return toCard(pr, Model.placement(pr, s.now), s) end
	end
	return nil
end

-- Selects the next item in the queue (`.` and the banner's Go), switching tabs when needed and clearing the
-- search or repository filter only if it hides the item. Walking then reads "n of N". Returns whether it moved.
function M.walk(s: State): boolean
	local next = s.board.nextUp
	if not next then return false end
	for _, pr in s.prs do
		if pr.key == next.item.key then
			local placement = Model.placement(pr, s.now)
			s.tab = placement.tab
			if not Model.visible(pr, { repositories = s.repositories, search = s.search.text }) then
				s.search = Fields.create("")
				s.repositories = nil
			end
			if placement.column == "inactive" then s.folded.inactive = false end
			s.mode, s.menu = "board", nil
			M.project(s)
			M.select(s, pr.key)
			s.walking = true
			refreshNext(s)
			return true
		end
	end
	return false
end

function M.openHelp(s: State)
	s.mode = "help"
	s.menu = nil
end

function M.closeHelp(s: State)
	if s.mode == "help" then s.mode = "board" end
end

-- The rows of the open menu.
local function row(label: string, sub: string?, count: number?, on: boolean, kind: "choice" | "check" | "clear"): MenuRow
	return { label = label, sub = sub, count = count, on = on, kind = kind }
end

function M.menuRows(s: State): { MenuRow }
	local rows: { MenuRow } = {}
	if s.menu == "sort" then
		for _, sort in M.SORTS do
			table.insert(rows, row(sort.label, sort.sub, nil, s.sort == sort.id, "choice"))
		end
	elseif s.menu == "repositories" then
		for _, option in s.board.repositories do
			table.insert(rows, row(shortRepo(option.repo), nil, option.count, option.on, "check"))
		end
		if s.repositories then table.insert(rows, row("Clear filter", nil, nil, false, "clear")) end
	elseif s.menu == "merge" then
		local repo = M.mergeRepo(s)
		local current = if repo and s.merges[repo] then s.merges[repo].method else nil
		for _, kind in M.MERGE_KINDS do
			local sub: string? = nil
			if current and current.kind == kind.id then
				if current.kind == "comment" then sub = current.command elseif current.kind == "label" then sub = current.label end
			end
			table.insert(rows, row(kind.label, sub, nil, current ~= nil and current.kind == kind.id, "choice"))
		end
	elseif s.menu == "actions" then
		local card = M.selectedCard(s)
		if card then
			for _, more in card.more do table.insert(rows, row(more.label, more.key, nil, false, "choice")) end
		end
	elseif s.menu == "agent" and s.agent then
		for _, model in s.agent.models do
			table.insert(rows, row(model.name, string.match(model.selector, "^([^/]+)/"), nil, model.selector == (s.agent :: AgentChoice).model, "choice"))
		end
	end
	return rows
end

function M.openMenu(s: State, menu: MenuId)
	s.menu = menu
	s.mode = "menu"
	s.menuCursor = 1
	if menu == "sort" then
		for index, sort in M.SORTS do
			if sort.id == s.sort then s.menuCursor = index end
		end
	elseif menu == "agent" and s.agent then
		for index, model in s.agent.models do
			if model.selector == s.agent.model then s.menuCursor = index end
		end
	elseif menu == "merge" then
		local repo = M.mergeRepo(s)
		local current = if repo and s.merges[repo] then s.merges[repo].method.kind else "squash"
		for index, kind in M.MERGE_KINDS do
			if kind.id == current then s.menuCursor = index end
		end
	end
	s.methodEdit = nil
end

function M.closeMenu(s: State)
	s.menu = nil
	s.methodEdit = nil
	if s.mode == "menu" then s.mode = "board" end
end

function M.menuMove(s: State, delta: number)
	s.menuCursor = math.clamp(s.menuCursor + delta, 1, math.max(1, #M.menuRows(s)))
end

-- The efforts the highlighted model takes in the agent menu, and the one now chosen.
function M.agentEfforts(s: State): ({ string }, string?)
	local agent = s.agent
	if s.menu ~= "agent" or not agent then return {}, nil end
	local model = agent.models[s.menuCursor]
	if not model then return {}, nil end
	return model.efforts, agent.effort
end

-- Steps the effort of the highlighted model along its levels.
function M.stepEffort(s: State, delta: number)
	local agent = s.agent
	if not agent then return end
	local efforts, current = M.agentEfforts(s)
	if #efforts == 0 then return end
	local at = (current and table.find(efforts, current)) or table.find(efforts, "high") or 1
	agent.effort = efforts[math.clamp(at + delta, 1, #efforts)]
end

function M.setEffort(s: State, level: string)
	local efforts = M.agentEfforts(s)
	if s.agent and table.find(efforts, level) then s.agent.effort = level end
end

-- Applies row `index` of the open menu: a sort or model is chosen and the menu closes; a repository is
-- toggled and the menu stays; Clear filter clears and closes. Returns whether the menu closed.
function M.menuPick(s: State, index: number): boolean
	local rows = M.menuRows(s)
	local row = rows[index]
	if not row then return false end
	s.menuCursor = index
	if s.menu == "sort" then
		M.setSort(s, M.SORTS[index].id)
		M.closeMenu(s)
		return true
	elseif s.menu == "repositories" then
		if row.kind == "clear" then
			M.clearRepositories(s)
			M.closeMenu(s)
			return true
		end
		M.toggleRepository(s, s.board.repositories[index].repo)
		return false
	elseif s.menu == "agent" and s.agent then
		local model = s.agent.models[index]
		s.agent.model = model.selector
		if #model.efforts == 0 then
			s.agent.effort = nil
		elseif not s.agent.effort or not table.find(model.efforts, s.agent.effort) then
			s.agent.effort = if table.find(model.efforts, "high") then "high" else model.efforts[1]
		end
		M.closeMenu(s)
		return true
	end
	return false
end

-- The alternative the open "actions" menu has highlighted at `index`.
function M.actionAt(s: State, index: number): CardAction?
	local card = M.selectedCard(s)
	if s.menu == "actions" and card then return card.more[index] end
	return nil
end

-- The model button's text: the model and effort, or what the button is for before the agent is found.
function M.agentLabel(s: State): string
	local agent = s.agent
	if not agent then return "Agent model" end
	local name = string.match(agent.model, "[^/]+$") or agent.model
	return if agent.effort then name .. " · " .. agent.effort else name
end

-- The merge chooser ----------------------------------------------------------------------------------------

M.MERGE_KINDS = {
	{ id = "squash", label = "Squash and merge" }, { id = "merge", label = "Create a merge commit" },
	{ id = "rebase", label = "Rebase and merge" }, { id = "queue", label = "Merge when ready" },
	{ id = "comment", label = "Comment a command" }, { id = "label", label = "Add a label" },
}

-- Where the repo's current setting came from, for the chooser's foot.
local SOURCES: { [string]: string } = {
	user = "Set by you", declared = "Declared by the repository", learned = "Learned from the last 8 merges",
	viewer = "Your GitHub default",
}

function M.mergeSource(s: State): string?
	local repo = M.mergeRepo(s)
	local resolved = if repo then s.merges[repo] else nil
	return if resolved then SOURCES[resolved.source] else nil
end

-- The repository the open merge menu is about: the selected card's.
function M.mergeRepo(s: State): string?
	local card = M.selectedCard(s)
	return if card then card.pr.repo else nil
end

-- Sets the repo's resolution (the block resolves it from kv evidence).
function M.setMerge(s: State, repo: string, resolution: Model.MergeResolution)
	s.merges[repo] = resolution
	M.project(s)
end

-- The repo's "Allow auto-merge" setting, read by detection: Merge when ready shows only where it's on.
function M.setAutoMerge(s: State, repo: string, allowed: boolean)
	s.autoMerge[repo] = allowed
	M.project(s)
end

-- Reviewers just asked again: their requests show at once, until a refresh brings GitHub's own.
function M.reRequested(s: State, key: string, logins: { string })
	for _, pr in s.prs do
		if pr.key == key then
			local requested = {}
			for _, name in pr.reviews.requested do table.insert(requested, name) end
			for _, name in logins do
				if not table.find(requested, name) then table.insert(requested, name) end
			end
			local reviews = {}
			for k, v in pr.reviews do reviews[k] = v end
			reviews.requested = requested
			pr.reviews = reviews :: any
		end
	end
	M.project(s)
end

-- Row `index` of the merge menu wants text (a command, a label): the menu shows a field, prefilled with the current one.
function M.beginMethodEdit(s: State, kind: "comment" | "label")
	local repo = M.mergeRepo(s)
	if not repo then return end
	local current = if s.merges[repo] then s.merges[repo].method else nil
	local text = ""
	if current and current.kind == "comment" and kind == "comment" then
		text = current.command .. (if current.cancel then " | " .. current.cancel else "")
	elseif current and current.kind == "label" and kind == "label" then
		text = current.label
	end
	s.methodEdit = { repo = repo, kind = kind, field = Fields.create(text) }
end

function M.cancelMethodEdit(s: State)
	s.methodEdit = nil
end

local function trimmed(text: string): string
	local start = string.gsub(text, "^%s+", "")
	return (string.gsub(start, "%s+$", ""))
end

-- The method the field names: "/merge" or "/merge | /cancel" for a comment, a label's name for a label; nil when empty.
function M.methodOfEdit(s: State): Model.MergeMethod?
	local edit = s.methodEdit
	if not edit then return nil end
	local text = trimmed(edit.field.text)
	if text == "" then return nil end
	if edit.kind == "label" then return { kind = "label", label = text } end
	local command, cancel = string.match(text, "^(.-)%s*|%s*(.*)$")
	command = trimmed(command or text)
	if command == "" then return nil end
	cancel = if cancel and trimmed(cancel) ~= "" then trimmed(cancel) else nil
	return { kind = "comment", command = command, cancel = cancel }
end

-- Card actions --------------------------------------------------------------------------------------------

-- Opens the merge question on the card `key` when it offers Merge and nothing else is running on it.
function M.askMerge(s: State, key: string): boolean
	local card = M.card(s, key)
	if not card or not card.main or card.main.act ~= "card-merge" or s.busy[key] then return false end
	M.select(s, key)
	s.confirm = { kind = if M.mergeStep(s, card.pr) == "ask" then "learned" else "merge", keys = { key } }
	s.mode, s.menu = "confirm", nil
	M.project(s)
	return true
end

function M.cancelConfirm(s: State)
	local had = s.confirm ~= nil
	s.confirm = nil
	if s.mode == "confirm" then s.mode = "board" end
	if had then M.project(s) end
end

-- Selecting several ---------------------------------------------------------------------------------------

-- The marked cards in column order: Ready's cards, or the Inactive rows.
function M.markedCards(s: State): { Card }
	local out: { Card } = {}
	for _, column in s.board.columns do
		for _, card in column.cards do
			if s.marked[card.pr.key] then table.insert(out, card) end
		end
	end
	for _, card in s.board.inactive do
		if s.marked[card.pr.key] then table.insert(out, card) end
	end
	return out
end

-- Space: marks or unmarks the card. Marking in one group clears the other's. Returns false, and why, for a card
-- that can't be selected.
function M.toggleMark(s: State, key: string): (boolean, string?)
	local card = M.card(s, key)
	if not card then return false, nil end
	local group, why = Model.selectGroup(card.pr, s.now)
	if not group then return false, why end
	if s.marked[key] then
		s.marked[key] = nil
	else
		for other in s.marked do
			local mark = M.card(s, other)
			if not mark or Model.selectGroup(mark.pr, s.now) ~= group then s.marked[other] = nil end
		end
		s.marked[key] = true
	end
	M.project(s)
	return true, nil
end

-- Pull requests Close stale would select: no activity for 7 days, not a draft.
function M.staleCount(s: State): number
	local count = 0
	for _, card in s.board.inactive do
		if Model.stale(card.pr, s.now) then count += 1 end
	end
	return count
end

-- ⇧X: replaces the selection with every stale non-draft Inactive row, and opens the fold. Returns how many.
function M.markStale(s: State): number
	if s.tab ~= "mine" then return 0 end
	local marked: { [string]: boolean } = {}
	local count = 0
	for _, card in s.board.inactive do
		if Model.stale(card.pr, s.now) then
			marked[card.pr.key] = true
			count += 1
		end
	end
	if count == 0 then return 0 end
	s.marked = marked
	s.folded.inactive = false
	M.project(s)
	return count
end

-- Esc: drops the selection (and a confirm about it). Returns whether there was one.
function M.clearMarks(s: State): boolean
	if next(s.marked) == nil then return false end
	s.marked = {}
	if s.confirm and (s.confirm.kind == "batch-merge" or s.confirm.kind == "batch-close") then
		s.confirm = nil
		if s.mode == "confirm" then s.mode = "board" end
	end
	M.project(s)
	return true
end

-- M or X on a selection: opens the confirm over the bar. Returns false when nothing of that group is marked.
function M.askBatch(s: State, group: Model.Group): boolean
	local cards = M.markedCards(s)
	if #cards == 0 or Model.selectGroup(cards[1].pr, s.now) ~= group then return false end
	local keys: { string } = {}
	for _, card in cards do table.insert(keys, card.pr.key) end
	s.confirm = { kind = if group == "ready" then "batch-merge" else "batch-close", keys = keys }
	s.mode, s.menu = "confirm", nil
	M.project(s)
	return true
end

-- The method the repo's merge uses; squash until it is known.
local function methodOf(s: State, pr: HubPR): Model.MergeMethod
	local resolved = s.merges[pr.repo]
	return if resolved then resolved.method else { kind = "squash" }
end

-- What the selection bar shows, or nil with nothing selected.
function M.selection(s: State): Selection?
	local cards = M.markedCards(s)
	if #cards == 0 then return nil end
	local group = Model.selectGroup(cards[1].pr, s.now)
	if not group then return nil end
	local merge = group == "ready"
	local n = #cards
	local verb = if merge then "Merge" else "Close"
	local selection: Selection = {
		group = group, count = n, verb = verb, key = if merge then "M" else "X",
		act = if merge then "hub-batch-merge" else "hub-batch-close", confirm = nil,
	}
	local confirm = s.confirm
	if confirm and (confirm.kind == "batch-merge" or confirm.kind == "batch-close") then
		local prs: { HubPR } = {}
		local methods: { Model.MergeMethod } = {}
		for _, card in cards do
			table.insert(prs, card.pr)
			table.insert(methods, methodOf(s, card.pr))
		end
		local list = Model.confirmList(prs)
		local rows: { BatchRow } = {}
		for _, pr in list.shown do table.insert(rows, { ref = shortRepo(pr.repo) .. " #" .. pr.number, title = pr.title }) end
		selection.confirm = {
			question = verb .. " " .. n .. (if n == 1 then " pull request?" else " pull requests?"),
			rows = rows, more = list.more,
			lines = if merge then Model.methodLines(methods) else { "Closed pull requests can be reopened." },
			go = verb .. " " .. n, act = "hub-confirm",
		}
	end
	return selection
end

-- Marks `key` as running `text`, or clears it with nil.
function M.setBusy(s: State, key: string, text: string?)
	s.busy[key] = text
	M.project(s)
end

-- Records (or clears, with nil) a merge asked for through a queue, comment or label.
function M.setPending(s: State, key: string, pending: Model.PendingMerge?)
	for _, pr in s.prs do
		if pr.key == key then pr.pending = pending end
	end
	M.project(s)
end

-- Takes the pull request off the board (merged, or removed from a refresh the viewer just made).
function M.dropPr(s: State, key: string)
	local kept: { HubPR } = {}
	for _, pr in s.prs do
		if pr.key ~= key then table.insert(kept, pr) end
	end
	s.prs = kept
	s.busy[key] = nil
	M.project(s)
end

-- Updating the branch makes its checks run again: the card waits on them until a refresh says otherwise.
function M.branchUpdated(s: State, key: string)
	for _, pr in s.prs do
		if pr.key == key then
			pr.behind = false
			pr.checks = { state = "pending", passing = 0, failing = 0, pending = 0 }
		end
	end
	s.busy[key] = nil
	M.project(s)
end

-- Removes a pull request the viewer added by link: it leaves the board unless it is on it for another
-- reason, in which case only the "Added by you" mark goes. A refresh settles the rest.
function M.unadd(s: State, key: string)
	for _, pr in s.prs do
		if pr.key == key then
			pr.addedByMe = false
			if not pr.reviews.requestedMe and pr.reviews.mine == nil then return M.dropPr(s, key) end
		end
	end
	M.project(s)
end

-- Add by link ---------------------------------------------------------------------------------------------

M.ADDED_CAP = 50

export type LinkTarget =
	{ kind: "empty" }
	| { kind: "invalid" }
	| { kind: "new", repo: string, number: number }
	| { kind: "board", repo: string, number: number, pr: HubPR }

-- The pull request the add field's text names: a github.com pull request link, or `owner/repo#123`.
local function parseRef(text: string): Model.PRRef?
	local trimmed = string.match(text, "^%s*(.-)%s*$") :: string
	-- A link pasted without its scheme ("github.com/owner/repo/pull/123") is the same link.
	local lowered = string.lower(trimmed)
	if string.find(lowered, "^github%.com/") or string.find(lowered, "^www%.github%.com/") then trimmed = "https://" .. trimmed end
	local repo: string?
	local number: number?
	local host = Links.linkHost(trimmed)
	if host then
		local lowerHost = string.lower(host)
		if lowerHost ~= "github.com" and lowerHost ~= "www.github.com" then return nil end
		repo, number = Links.linkRepo(trimmed), Links.named(trimmed)
	else
		local r, n = string.match(trimmed, "^([%w_.%-]+/[%w_.%-]+)#(%d+)$")
		repo, number = r, tonumber(n)
	end
	if repo == nil or number == nil or string.match(repo, "^[%w_.%-]+/[%w_.%-]+$") == nil then return nil end
	if (number :: number) < 1 then return nil end
	return { repo = repo, number = number :: number }
end

-- The pull request on the board named by `repo` (any case) and `number`.
function M.find(s: State, repo: string, number: number): HubPR?
	for _, pr in s.prs do
		if pr.number == number and string.lower(pr.repo) == string.lower(repo) then return pr end
	end
	return nil
end

function M.linkTarget(s: State): LinkTarget
	local text = s.link.text
	if string.match(text, "^%s*$") then return { kind = "empty" } end
	local ref = parseRef(text)
	if not ref then return { kind = "invalid" } end
	local pr = M.find(s, ref.repo, ref.number)
	if pr then return { kind = "board", repo = pr.repo, number = pr.number, pr = pr } end
	return { kind = "new", repo = ref.repo, number = ref.number }
end

-- N: the add field, on Review requests.
function M.openLink(s: State)
	s.menu = nil
	M.setTab(s, "review")
	s.mode = "link"
end

-- Leaves the add field; `clear` empties it too.
function M.closeLink(s: State, clear: boolean)
	if s.mode == "link" then s.mode = "board" end
	if clear and s.link.text ~= "" then s.link = Fields.create("") end
end

-- Brings the pull request `key` into view and selects it: its tab, with the search and repository filter
-- cleared if they hide it, and the Inactive fold open if it sits there. Returns whether it was found.
function M.show(s: State, key: string): boolean
	for _, pr in s.prs do
		if pr.key == key then
			local placement = Model.placement(pr, s.now)
			s.tab = placement.tab
			s.search = Fields.create("")
			s.repositories = nil
			if placement.column == "inactive" then s.folded.inactive = false end
			s.mode, s.menu = "board", nil
			M.project(s)
			M.select(s, key)
			return true
		end
	end
	return false
end

-- Adds `ref` to the added set. Returns the new set, or nil with why it can't (the set is full).
function M.withAdded(added: { [string]: Model.PRRef }, ref: Model.PRRef): ({ [string]: Model.PRRef }?, string?)
	local key = ref.repo .. "#" .. ref.number
	if added[key] then return added, nil end
	local count = 0
	for _ in added do count += 1 end
	if count >= M.ADDED_CAP then
		return nil, M.ADDED_CAP .. " pull requests are added already. Remove one first."
	end
	local out = table.clone(added)
	out[key] = ref
	return out, nil
end

-- `added` with each entry that names a fetched PR under that PR's own spelling of the repo ("Acme/API#5"
-- becomes "acme/api#5"). Returns the set and whether anything changed.
function M.canonicalAdded(added: { [string]: Model.PRRef }, prs: { HubPR }): ({ [string]: Model.PRRef }, boolean)
	local out = table.clone(added)
	local changed = false
	for _, pr in prs do
		local wrong = nil
		for key, ref in added do
			if key ~= pr.key and ref.number == pr.number and string.lower(ref.repo) == string.lower(pr.repo) then wrong = key end
		end
		if wrong then
			out[wrong] = nil
			out[pr.key] = { repo = pr.repo, number = pr.number }
			changed = true
		end
	end
	return out, changed
end

-- Opening a pull request ----------------------------------------------------------------------------------

export type OpenPlan = { kind: "open", url: string } | { kind: "refuse", text: string, sub: string }

-- What opening PR `number` of `slug` does, given what the block found: `root` is a checkout of the repo (or
-- nil), `why` is why PR Guide can't keep its own copy (or nil when it can), `dir` is the folder searched.
function M.openPlan(slug: string, number: number, generate: boolean, root: string?, why: string?, dir: string): OpenPlan
	if root then return { kind = "open", url = Links.openLink(slug, number, root, generate, false) } end
	if why or dir == "" then
		return { kind = "refuse", text = "Couldn't open #" .. number .. " of " .. slug, sub = why or "No folder to look for a checkout in." }
	end
	return { kind = "open", url = Links.openLink(slug, number, dir, generate, true) }
end

-- The fixes page ------------------------------------------------------------------------------------------------
-- A route over the board: Esc returns to it with the card still selected. All pure; the block reads the
-- details, runs git and the writes.

-- Opens the page on the PR `key`; false when no such PR is on hand. Details already read for the same
-- commit show at once while the block reads them again.
function M.openFixes(s: State, key: string): boolean
	local pr = M.prOf(s, key)
	if pr == nil then return false end
	local known = s.details[key]
	s.route = {
		kind = "fixes", key = key, cur = 1, focus = "steps", item = 1,
		loading = known == nil or known.headOid ~= pr.headOid, error = nil, bots = false,
		resolved = {}, replies = {}, reply = nil, busy = false,
	}
	s.mode, s.menu, s.confirm = "fixes", nil, nil
	return true
end

function M.closeFixes(s: State)
	s.route, s.mode = nil, "board"
end

-- The PR with `key`, on the board or not.
function M.prOf(s: State, key: string): HubPR?
	for _, pr in s.prs do
		if pr.key == key then return pr end
	end
	return nil
end

-- Details to build the steps from: what was read, or nothing yet (the PR's own flags still make steps).
function M.fixDetails(s: State): FixDetails?
	local route = s.route
	local pr = if route then M.prOf(s, route.key) else nil
	if route == nil or pr == nil then return nil end
	return s.details[route.key] or {
		key = pr.key, headOid = pr.headOid, fetchedAt = "", reviews = {}, threads = {}, checks = {}, changedPaths = {},
		conflicts = nil, conflictNote = nil, files = nil,
	}
end

function M.fixSteps(s: State): { Fixes.Step }
	local route = s.route
	local pr = if route then M.prOf(s, route.key) else nil
	local details = M.fixDetails(s)
	if route == nil or pr == nil or details == nil then return {} end
	return Fixes.steps(details, pr)
end

function M.fixStep(s: State): Fixes.Step?
	local route = s.route
	if route == nil then return nil end
	return M.fixSteps(s)[route.cur]
end

-- Steps still to do: not a thread resolved from the page.
function M.fixLeft(s: State): number
	local route = s.route
	local left = 0
	for _, step in M.fixSteps(s) do
		if route == nil or step.thread == nil or not route.resolved[step.thread.id] then left += 1 end
	end
	return left
end

-- The actions the panel's j and k move over for `step`; "agent" is the card's own main action.
function M.fixItems(s: State, step: Fixes.Step?): { string }
	if step == nil then return {} end
	local card = if s.route then M.card(s, s.route.key) else nil
	local agent = card ~= nil and card.main ~= nil and card.main.act ~= "open"
	if step.thread then return { "reply", "resolve" } end
	if step.check then return { "log", "rerun" } end
	if step.conflict then return if agent then { "agent", "github" } else { "github" } end
	return { "github" }
end

-- The card's main action, which the page shows under the card's own label ("Hand off to Tandem").
function M.fixMain(s: State): CardAction?
	local card = if s.route then M.card(s, s.route.key) else nil
	local main = if card then card.main else nil
	if main and main.act ~= "open" then return main end
	return nil
end

function M.fixSelect(s: State, index: number)
	local route = s.route
	if route == nil then return end
	route.cur = math.clamp(index, 1, math.max(1, #M.fixSteps(s)))
	route.item, route.reply = 1, nil
	s.mode = "fixes"
end

-- j and k: the next or previous step in the left column, or the next action in the panel.
function M.fixMove(s: State, delta: number)
	local route = s.route
	if route == nil then return end
	if route.focus == "steps" then
		M.fixSelect(s, route.cur + delta)
		return
	end
	route.item = math.clamp(route.item + delta, 1, math.max(1, #M.fixItems(s, M.fixStep(s))))
end

function M.fixFocus(s: State, focus: "steps" | "panel")
	local route = s.route
	if route == nil then return end
	route.focus = focus
	route.item = 1
end

-- ⏎: from the steps into the panel; in the panel, the highlighted action (returned for the block to run).
function M.fixPress(s: State): string?
	local route = s.route
	if route == nil then return nil end
	if route.focus == "steps" then
		M.fixFocus(s, "panel")
		return nil
	end
	return M.fixItems(s, M.fixStep(s))[route.item]
end

function M.fixToggleBots(s: State)
	if s.route then s.route.bots = not s.route.bots end
end

-- R: starts a reply on a thread step.
function M.beginReply(s: State): boolean
	local route, step = s.route, M.fixStep(s)
	if route == nil or step == nil or step.thread == nil or route.resolved[step.thread.id] then return false end
	route.reply, route.focus = Fields.create("", true), "panel"
	s.mode = "reply"
	return true
end

function M.cancelReply(s: State)
	if s.route then s.route.reply = nil end
	if s.mode == "reply" then s.mode = "fixes" end
end

-- The details the block read: the page's steps follow them.
function M.setDetails(s: State, details: FixDetails)
	s.details[details.key] = details
	if s.route and s.route.key == details.key then
		s.route.loading, s.route.error = false, nil
		s.route.cur = math.clamp(s.route.cur, 1, math.max(1, #M.fixSteps(s)))
	end
end

return M
