--!strict
-- What the fixes page shows: the details model, the noise filter, the steps (one per problem, grouped),
-- the code excerpts, and the readers of local git output (`git merge-tree`, `git show`, `git log`).
-- Pure: no network, no files, no clock. `github.parseDetails` builds `FixDetails` from GitHub's JSON,
-- `fetch` returns git's text, and this module turns both into what the view draws.
local Model = require("./model")

type HubPR = Model.HubPR

export type ThreadDetail = {
	id: string, group: "requested" | "comment",
	author: string, bot: boolean,
	path: string, line: number?, -- nil when the thread is on the file or the line is gone
	outdated: boolean,
	body: string, -- the first comment
	replies: number, url: string,
	hunk: string?, -- the first comment's diff hunk, which ends at the commented line
}
export type ReviewDetail = { author: string, body: string, at: string, url: string } -- a changes-requested review
export type Annotation = { path: string, line: number, level: "failure" | "warning" | "notice", title: string?, message: string }
export type FailingCheck = {
	name: string, workflow: string?, runId: number?, url: string,
	summary: string?,
	annotations: { Annotation }, -- as GitHub sent them; `usable` drops the noise
}
export type Cause = { number: number?, title: string, author: string, sha: string } -- "Main changed this in #415 by @devon"
-- One side-by-side block of a conflicted file: `start` is the first line in the file on both sides.
export type ConflictHunk = { start: number, branch: { string }, main: { string } }
export type Conflict = { path: string, cause: Cause?, hunks: { ConflictHunk } }
export type FixDetails = {
	key: string, headOid: string, fetchedAt: string,
	reviews: { ReviewDetail },
	threads: { ThreadDetail },
	checks: { FailingCheck },
	changedPaths: { string },
	conflicts: { Conflict }?, -- nil until fetch.luau has read local `git merge-tree --write-tree --name-only`
	conflictNote: string?, -- why `conflicts` is nil: "No local copy of acme/web"
	files: { [string]: string }?, -- annotated files as the head commit has them, read by `git show`
}

-- A line of code in an excerpt. `old` is nil on an added line and for a plain file excerpt.
export type Row = { kind: "ctx" | "add" | "del", old: number?, new: number?, text: string }
-- The rows around a line; `before` and `after` count the lines the excerpt leaves out (`after` is nil when unknown).
export type Excerpt = { rows: { Row }, before: number, after: number? }
-- `git merge-tree --write-tree --name-only`: the merged tree (with conflict markers in the conflicted files) and the files.
export type MergeTree = { tree: string, files: { string } }

export type Group = "requested" | "comment" | "check" | "conflict" | "failure"
export type Step = {
	id: string, group: Group,
	who: string, -- the left row's bold part: "@maria-k", a check's name, a file's name
	text: string, -- the rest of the row, one line
	path: string?, line: number?, -- where the code panel opens
	thread: ThreadDetail?, review: ReviewDetail?, check: FailingCheck?, conflict: Conflict?,
	note: string?, -- shown in the panel when there is no code to show
}

local M = {}

-- The groups in the order the left column lists them, with their headings and the chip each adds to the header.
M.GROUPS = {
	{ id = "requested" :: Group, label = "Requested changes", chip = "Address changes" },
	{ id = "comment" :: Group, label = "Comments", chip = "Reply" },
	{ id = "check" :: Group, label = "Failing checks", chip = "Fix checks" },
	{ id = "conflict" :: Group, label = "Merge conflicts", chip = "Resolve conflicts" },
	{ id = "failure" :: Group, label = "Merge failed", chip = "Merge failed" },
}

local EXCERPT_ROWS = 8 -- the most rows of a diff hunk an excerpt keeps: the ones nearest the commented line
local FILE_RADIUS = 5 -- lines either side of an annotation

local function lines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do table.insert(out, (string.gsub(line, "\r$", ""))) end
	if out[#out] == "" then table.remove(out) end
	return out
end

local function addStep(list: { Step }, step: Step)
	table.insert(list, step)
end

local function addRow(list: { Row }, row: Row)
	table.insert(list, row)
end

local function trimmed(text: string): string
	return (string.match(text, "^%s*(.-)%s*$")) :: string
end

-- The first line of `text` with something in it.
function M.firstLine(text: string): string
	for line in string.gmatch(text, "[^\r\n]+") do
		local stripped = trimmed(line)
		if stripped ~= "" then return stripped end
	end
	return ""
end

-- Annotations that say something about the code: not under `.github`, and not the runner's exit-code line.
function M.usable(annotations: { Annotation }): { Annotation }
	local out: { Annotation } = {}
	for _, annotation in annotations do
		local workflow = annotation.path == ".github" or string.sub(annotation.path, 1, 8) == ".github/"
		local exit = string.find(annotation.message, "Process completed with exit code", 1, true) ~= nil
		if not workflow and not exit then table.insert(out, annotation) end
	end
	return out
end

-- The steps, in group order: requested changes (a review's own words, then its threads), comments,
-- failing checks, merge conflicts. A bot's threads are not steps. A PR with nothing else to fix and a
-- merge failure gets that one note.
function M.steps(d: FixDetails, pr: HubPR): { Step }
	local byGroup: { [Group]: { Step } } = { requested = {}, comment = {}, check = {}, conflict = {}, failure = {} }
	for n, review in d.reviews do
		if trimmed(review.body) ~= "" and review.author ~= pr.author then
			addStep(byGroup.requested, {
				id = "review:" .. n, group = "requested", who = "@" .. review.author, text = M.firstLine(review.body),
				path = nil, line = nil, thread = nil, review = review, check = nil, conflict = nil, note = nil,
			})
		end
	end
	for _, thread in d.threads do
		if Model.threadCounts(pr, thread.author, thread.bot) then
			addStep(byGroup[thread.group], {
				id = "thread:" .. thread.id, group = thread.group, who = "@" .. thread.author, text = M.firstLine(thread.body),
				path = thread.path, line = thread.line, thread = thread, review = nil, check = nil, conflict = nil, note = nil,
			})
		end
	end
	for _, check in d.checks do
		local usable = M.usable(check.annotations)
		local first = usable[1]
		addStep(byGroup.check, {
			id = "check:" .. check.name, group = "check", who = check.name,
			text = if first then first.message else (check.summary or "Failed"),
			path = if first then first.path else nil, line = if first then first.line else nil,
			thread = nil, review = nil, check = check, conflict = nil, note = nil,
		})
	end
	if d.conflicts then
		for _, conflict in d.conflicts do
			local count = #conflict.hunks
			addStep(byGroup.conflict, {
				id = "conflict:" .. conflict.path, group = "conflict", who = string.match(conflict.path, "[^/]+$") or conflict.path,
				text = if count == 0 then "conflicts with main" else "· " .. count .. (if count == 1 then " conflict" else " conflicts"),
				path = conflict.path, line = if conflict.hunks[1] then conflict.hunks[1].start else nil,
				thread = nil, review = nil, check = nil, conflict = conflict, note = nil,
			})
		end
	elseif pr.conflicts then
		addStep(byGroup.conflict, {
			id = "conflict:", group = "conflict", who = "Conflicts with main", text = "",
			path = nil, line = nil, thread = nil, review = nil, check = nil, conflict = nil,
			note = d.conflictNote or "Reading the conflicted files…",
		})
	end
	local out: { Step } = {}
	for _, group in M.GROUPS do
		if group.id ~= "failure" then
			for _, step in byGroup[group.id] do table.insert(out, step) end
		end
	end
	if #out == 0 and pr.mergeFailure then
		addStep(out, {
			id = "failure:", group = "failure", who = "Merge failed", text = pr.mergeFailure.reason,
			path = nil, line = nil, thread = nil, review = nil, check = nil, conflict = nil, note = pr.mergeFailure.reason,
		})
	end
	return out
end

-- The bots that left unresolved threads, with how many each: shown apart, as "Not counted".
function M.bots(d: FixDetails): { { author: string, count: number } }
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, thread in d.threads do
		if thread.bot then
			if counts[thread.author] == nil then table.insert(order, thread.author) end
			counts[thread.author] = (counts[thread.author] or 0) + 1
		end
	end
	local out = {}
	for _, author in order do table.insert(out, { author = author, count = counts[author] }) end
	return out
end

-- The header's chips, one per kind of problem still open, in group order.
function M.chips(steps: { Step }): { string }
	local present: { [Group]: boolean } = {}
	for _, step in steps do present[step.group] = true end
	local out: { string } = {}
	for _, group in M.GROUPS do
		if present[group.id] then table.insert(out, group.chip) end
	end
	return out
end

-- Where View log goes: the workflow run when there is one, else the check's own link.
function M.logUrl(check: FailingCheck, repo: string): string
	if check.runId then return "https://github.com/" .. repo .. "/actions/runs/" .. check.runId end
	return check.url
end

-- Rows -----------------------------------------------------------------------------------------------------

-- The rows of a GitHub diff hunk ("@@ -48,9 +48,11 @@ …" and its lines): the last few, since the hunk ends at the commented line.
function M.hunkExcerpt(hunk: string): Excerpt?
	local all = lines(hunk)
	local old, new = string.match(all[1] or "", "^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
	if old == nil or new == nil then return nil end
	local oldLine, newLine = tonumber(old) :: number, tonumber(new) :: number
	local rows: { Row } = {}
	for i = 2, #all do
		local sign, text = string.sub(all[i], 1, 1), string.sub(all[i], 2)
		if sign == "+" then
			addRow(rows, { kind = "add", old = nil, new = newLine, text = text })
			newLine += 1
		elseif sign == "-" then
			addRow(rows, { kind = "del", old = oldLine, new = nil, text = text })
			oldLine += 1
		elseif sign == " " or all[i] == "" then
			addRow(rows, { kind = "ctx", old = oldLine, new = newLine, text = text })
			oldLine += 1
			newLine += 1
		end
	end
	while #rows > EXCERPT_ROWS do table.remove(rows, 1) end
	local first = rows[1]
	if first == nil then return nil end
	return { rows = rows, before = math.max(0, (first.new or first.old or 1) - 1), after = nil }
end

-- The lines of `text` around `line`, as plain rows.
function M.fileExcerpt(text: string, line: number): Excerpt?
	local all = lines(text)
	if #all == 0 or line < 1 or line > #all then return nil end
	local first, last = math.max(1, line - FILE_RADIUS), math.min(#all, line + FILE_RADIUS)
	local rows: { Row } = {}
	for n = first, last do addRow(rows, { kind = "ctx", old = nil, new = n, text = all[n] }) end
	return { rows = rows, before = first - 1, after = #all - last }
end

-- git ------------------------------------------------------------------------------------------------------

-- `git merge-tree --write-tree --name-only <ours> <theirs>`: the merged tree's id, then the conflicted
-- files, then a blank line and the messages. A clean merge prints the id alone.
function M.parseMergeTree(text: string): MergeTree?
	local all = lines(text)
	local tree = all[1]
	if tree == nil or string.match(tree, "^%x+$") == nil or #tree < 40 then return nil end
	local files: { string } = {}
	local seen: { [string]: boolean } = {}
	for i = 2, #all do
		local line = all[i]
		if line == "" then break end
		if not seen[line] then
			seen[line] = true
			table.insert(files, line)
		end
	end
	return { tree = tree, files = files }
end

-- The conflict blocks of a file with git's markers, as the two sides: ours (the branch) and theirs (main).
-- `start` counts the file as the branch has it.
function M.parseHunks(content: string): { ConflictHunk }
	local out: { ConflictHunk } = {}
	local side: "text" | "ours" | "base" | "theirs" = "text"
	local current: ConflictHunk? = nil
	local n = 0
	for _, line in lines(content) do
		if side == "text" then
			if string.sub(line, 1, 7) == "<<<<<<<" then
				side = "ours"
				current = { start = n + 1, branch = {}, main = {} }
			else
				n += 1
			end
		elseif current then
			if string.sub(line, 1, 7) == "|||||||" and side == "ours" then
				side = "base"
			elseif string.sub(line, 1, 7) == "=======" and side ~= "theirs" then
				side = "theirs"
			elseif string.sub(line, 1, 7) == ">>>>>>>" and side == "theirs" then
				table.insert(out, current)
				current, side = nil, "text"
			elseif side == "ours" then
				table.insert(current.branch, line)
				n += 1
			elseif side == "theirs" then
				table.insert(current.main, line)
			end
		end
	end
	return out
end

-- The last commit on main touching a file, from `git log -1 --format=%H%x09%an%x09%s`; the PR number is
-- the subject's "(#415)" (a squash merge) or "Merge pull request #415" (a merge commit).
function M.parseCause(output: string): Cause?
	local sha, author, subject = string.match(M.firstLine(output), "^(%x+)\t([^\t]*)\t(.*)$")
	if sha == nil or author == nil or subject == nil then return nil end
	local number = tonumber(string.match(subject, "%(#(%d+)%)%s*$")) or tonumber(string.match(subject, "^Merge pull request #(%d+)"))
	local title = string.gsub(subject, "%s*%(#%d+%)%s*$", "")
	return { number = number, title = title, author = author, sha = sha }
end

-- The conflicted files with their blocks and the main commit behind each. `shown` is `git show <tree>:<path>`
-- and `logs` is the `git log` output, by path.
function M.conflicts(tree: MergeTree, shown: { [string]: string }, logs: { [string]: string }): { Conflict }
	local out: { Conflict } = {}
	for _, path in tree.files do
		table.insert(out, { path = path, cause = M.parseCause(logs[path] or ""), hunks = M.parseHunks(shown[path] or "") })
	end
	return out
end

return M
