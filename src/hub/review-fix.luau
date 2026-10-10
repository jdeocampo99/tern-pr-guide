--!strict
-- Conflict-only excerpts from an immutable fix commit, and the plans that gate Push and Discard.
-- Pure: callers supply commit files, identity and ownership; Fetch executes process plans.
local AgentFix = require("./agent-fix")
local Fixes = require("./fixes")

export type Line = { tag: AgentFix.LineTag, text: string, label: string?, number: number }
export type Hunk = { id: string, path: string, start: number, by: "rule" | "agent", lines: { Line }, ours: { string }, theirs: { string } }
export type Review = { hunks: { Hunk }, verified: boolean, error: string? }
export type Original = { path: string, start: number, base: { string }, ours: { string }, theirs: { string } }
export type Command = { argv: { string }, cwd: string }
export type Request = {
	kind: string, key: string, selectedKey: string?, routeKey: string?, repo: string, number: number,
	headOid: string, fix: AgentFix.Fix, reviewed: { [string]: boolean }, verified: boolean,
	completion: ("push" | "discard")?,
}
export type Plan = {
	kind: "push" | "discard", request: Request, command: Command?, returnLease: boolean,
	remoteHeadOid: string, next: "refresh" | "needs_fixes",
}
export type Result = { clear: boolean, remoteHeadOid: string, card: "fix_ready" | "needs_fixes" | "refresh" }

local M = {}
local LABELS: { [string]: string } = { ours = "Your branch", theirs = "main", agent = "Agent" }
local CONTEXT_WIDTH = 240 -- tools/conflicts bounds each context preview to this many characters.

local function validIds(fix: AgentFix.Fix): boolean
	local seen: { [string]: boolean } = {}
	for _, hunk in fix.hunks do
		if type(hunk.id) ~= "string" or hunk.id == "" or seen[hunk.id] then return false end
		seen[hunk.id] = true
	end
	return true
end

function M.allReviewed(fix: AgentFix.Fix, reviewed: { [string]: boolean }): boolean
	if not validIds(fix) then return false end
	for _, hunk in fix.hunks do
		if reviewed[hunk.id] ~= true then return false end
	end
	return true
end

local function fileLines(text: string): { string }
	local lines: { string } = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do table.insert(lines, line) end
	if string.sub(text, -1) == "\n" or text == "" then table.remove(lines) end
	return lines
end

local function same(a: { string }, b: { string }): boolean
	if #a ~= #b then return false end
	for i, line in a do if line ~= b[i] then return false end end
	return true
end

-- #15's captured sides are authoritative. Reuse #12's original only for the same path,
-- start and exact sides, so a refresh cannot replace the conflict the agent actually resolved.
local function original(hunk: AgentFix.ConflictHunk, details: Fixes.FixDetails?, snapshot: Original?): ({ string }, { string })
	local ours, theirs = if snapshot then snapshot.ours else hunk.ours, if snapshot then snapshot.theirs else hunk.theirs
	if details then
		for _, conflict in (details.conflicts or {}) do
			if conflict.path ~= hunk.path then continue end
			for _, prior in conflict.hunks do
				if prior.start == hunk.start and same(prior.branch, ours) and same(prior.main, theirs) then
					return table.clone(prior.branch), table.clone(prior.main)
				end
			end
		end
	end
	return table.clone(ours), table.clone(theirs)
end

function M.build(fix: AgentFix.Fix, files: { [string]: string }, details: Fixes.FixDetails?, originals: { [string]: Original }?): Review
	local review: Review = { hunks = {}, verified = true }
	local function fail(reason: string): Review
		review.verified, review.error = false, "Couldn't read the fix: " .. reason
		-- Keep B available even if commit verification failed; never invent resolution rows.
		if validIds(fix) then
			for index, hunk in fix.hunks do
				if review.hunks[index] then continue end
				local snapshot = if originals then originals[hunk.id] else nil
				if snapshot and (snapshot.path ~= hunk.path or snapshot.start ~= hunk.start) then snapshot = nil end
				local ours, theirs = original(hunk, details, snapshot)
				review.hunks[index] = {
					id = hunk.id, path = hunk.path, start = hunk.start, by = if hunk.resolved then hunk.resolved.by else "agent",
					lines = {}, ours = ours, theirs = theirs,
				}
			end
		end
		return review
	end
	if not validIds(fix) then return fail("conflict ids are missing or duplicated") end
	local positions: { [string]: { [number]: boolean } } = {}
	for _, hunk in fix.hunks do
		local snapshot = if originals then originals[hunk.id] else nil
		if originals and (not snapshot or snapshot.path ~= hunk.path or snapshot.start ~= hunk.start) then return fail("the original conflict is missing or changed") end
		local resolution = hunk.resolved
		local text = files[hunk.path]
		if not resolution or text == nil then return fail("a conflict resolution is missing") end
		local pattern: { string } = table.clone(hunk.context.before)
		for _, line in resolution.lines do
			if line.tag ~= "base" and LABELS[line.tag] == nil then return fail("a line has an unknown source") end
			table.insert(pattern, line.text)
		end
		for _, line in hunk.context.after do table.insert(pattern, line) end
		if #pattern == 0 then return fail("a resolution has no context") end
		local source = fileLines(text)
		local found: number? = nil
		for start = 1, #source - #pattern + 1 do
			local matches = true
			for i, line in pattern do
				local context = i <= #hunk.context.before or i > #hunk.context.before + #resolution.lines
				local actual = source[start + i - 1]
				-- tools/conflicts bounds context previews. Prefix matching is used only
				-- for those previews; every resolution line must match in full.
				local bounded = context and utf8.len(line) == CONTEXT_WIDTH
				if (if bounded then string.sub(actual, 1, #line) ~= line else actual ~= line) then matches = false; break end
			end
			if matches then
				if found then return fail("a resolution matches more than once") end
				found = start
			end
		end
		if not found then return fail("the commit differs from the recorded resolution") end
		local location = (found :: number) + #hunk.context.before
		local used = positions[hunk.path] or {}
		if used[location] then return fail("conflicts share a resolution") end
		used[location], positions[hunk.path] = true, used
		local lines: { Line } = {}
		local function add(tag: AgentFix.LineTag, value: string)
			table.insert(lines, { tag = tag, text = value, label = LABELS[tag], number = (found :: number) + #lines })
		end
		local ours, theirs = original(hunk, details, snapshot)
		local base = if snapshot then snapshot.base else hunk.base
		for index in hunk.context.before do add("base", source[(found :: number) + index - 1]) end
		for _, line in resolution.lines do
			local tag = line.tag
			local inOurs, inTheirs = table.find(ours, line.text) ~= nil, table.find(theirs, line.text) ~= nil
			if inOurs and inTheirs then tag = "base"
			elseif tag == "agent" then
				if inOurs then tag = "ours" elseif inTheirs then tag = "theirs" elseif table.find(base, line.text) then tag = "base" end
			end
			add(tag, line.text)
		end
		for index in hunk.context.after do add("base", source[location + #resolution.lines + index - 1]) end
		table.insert(review.hunks, { id = hunk.id, path = hunk.path, start = hunk.start, by = resolution.by, lines = lines, ours = ours, theirs = theirs })
	end
	return review
end

function M.lines(hunk: Hunk, before: boolean): { Line }
	if not before then return hunk.lines end
	local lines: { Line } = {}
	for _, tag in { "ours", "theirs" } do
		local source = if tag == "ours" then hunk.ours else hunk.theirs
		for i, text in source do table.insert(lines, { tag = tag :: AgentFix.LineTag, text = text, label = LABELS[tag], number = hunk.start + i - 1 }) end
	end
	return lines
end

local function oid(value: string): boolean
	return (#value == 40 or #value == 64) and string.match(value, "^%x+$") ~= nil
end

local function branch(value: string): boolean
	return value ~= "" and string.sub(value, 1, 1) ~= "-" and string.sub(value, 1, 1) ~= "/"
		and string.sub(value, -1) ~= "/" and string.sub(value, -1) ~= "." and not string.find(value, "[%s%c~^:?*%[\\]")
		and not string.find(value, "..", 1, true) and not string.find(value, "@{", 1, true)
		and not string.find(value, "//", 1, true) and not string.find(value, "%.lock$")
end

function M.readCommands(fix: AgentFix.Fix): ({ Command }?, string?)
	if fix.worktree == "" or not oid(fix.commit) or not oid(fix.headOid) then return nil, "Invalid fix commit" end
	local paths: { string } = {}
	for _, hunk in fix.hunks do
		if hunk.path == "" or string.find(hunk.path, "%c") then return nil, "Invalid conflict path" end
		if not table.find(paths, hunk.path) then table.insert(paths, hunk.path) end
	end
	local commands: { Command } = {}
	if #paths > 0 then
		local argv = { "git", "--literal-pathspecs", "-C", fix.worktree, "diff", "--no-ext-diff", "--no-textconv", fix.headOid, fix.commit, "--" }
		for _, path in paths do table.insert(argv, path) end
		table.insert(commands, { argv = argv, cwd = fix.worktree })
	end
	for _, path in paths do
		table.insert(commands, { argv = { "git", "-C", fix.worktree, "show", "--no-ext-diff", "--no-textconv", fix.commit .. ":" .. path }, cwd = fix.worktree })
	end
	if #paths > 0 then table.insert(commands, { argv = { "git", "-C", fix.worktree, "rev-parse", "--absolute-git-dir" }, cwd = fix.worktree }) end
	return commands, nil
end

function M.plan(action: "push" | "discard", request: Request, confirmed: boolean?, remoteRepo: string?): (Plan?, string?)
	local fix = request.fix
	if request.kind ~= "ready" or request.key ~= request.selectedKey or request.key ~= request.routeKey then
		return nil, "select the matching Fix ready pull request"
	end
	if request.completion and request.completion ~= action then return nil, "return the worktree lease first" end
	if fix.worktree == "" then return nil, "the worktree lease is missing" end
	local plan: Plan = { kind = action, request = request, returnLease = true, remoteHeadOid = request.headOid, next = if action == "push" then "refresh" else "needs_fixes" }
	if action == "discard" then
		if confirmed ~= true then return nil, "confirm Discard fix first" end
		return plan, nil
	end
	if not request.verified then return nil, "the fix has not been read from its commit" end
	if not M.allReviewed(fix, request.reviewed) then return nil, "review every conflict first" end
	if request.completion == "push" then plan.remoteHeadOid = fix.commit; return plan, nil end
	if request.headOid ~= fix.headOid and request.headOid ~= fix.commit then return nil, "the pull request head changed; refresh the board" end
	local repo = remoteRepo or request.repo
	if not string.match(repo, "^[%w_.%-]+/[%w_.%-]+$") or not branch(fix.branch) or not oid(fix.commit) or not oid(fix.headOid)
		or request.number < 1 or request.number % 1 ~= 0 then return nil, "invalid pull request refs" end
	plan.command = { argv = { "git", "-C", fix.worktree, "push", "https://github.com/" .. repo .. ".git", fix.commit .. ":refs/heads/" .. fix.branch }, cwd = fix.worktree }
	return plan, nil
end

-- A failed lease return never clears the card or changes the supplied remote head.
function M.result(plan: Plan, pushed: boolean, returned: boolean): Result
	local head = if plan.kind == "push" and pushed then plan.request.fix.commit else plan.remoteHeadOid
	local clear = returned and (plan.kind == "discard" or pushed)
	return { clear = clear, remoteHeadOid = head, card = if clear then plan.next else "fix_ready" }
end

return M
