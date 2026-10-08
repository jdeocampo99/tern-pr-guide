--!strict
local Fields = require("./text-field")
local Guide = require("./guide")
local Pr = require("./pr")

export type Decision = "added" | "dismissed"
export type VerdictId = "comment" | "approve" | "changes"
export type Verdict = { id: VerdictId, event: string, label: string }

-- A comment the reader wrote. Excluded ones stay in the list but out of the review.
export type Own = { file: string, from: number, to: number, body: string, excluded: boolean }

-- A suggested comment (`suggestion`) or one of the reader's (`own`, its index), as the review lists them.
export type Item = { file: string, line: number, suggestion: Guide.Comment?, own: number?, order: number }

export type Counts = { filesReviewed: number, included: number, waiting: number }

-- One inline comment of a submitted review, on the new side ("RIGHT"); `start_line` and
-- `start_side` are set for a range.
export type PostedComment = {
 path: string, line: number, side: string, start_line: number?, start_side: string?, body: string,
}
-- The body of GitHub's create-review request: the PR head the comments are on, the summary, the
-- verdict as a review event, the included comments.
export type Payload = { commit_id: string, body: string, event: string, comments: { PostedComment } }
-- Where a submitted review went: posted to GitHub (`url` is the review's page) or, in a dry run,
-- saved to the file at `path`.
export type Delivery = { kind: "posted", url: string } | { kind: "saved", path: string }
export type Posted = { verdict: VerdictId, payload: Payload, delivery: Delivery }

export type Review = {
 pr: Pr.PR,
 guide: Guide.Guide,
 -- Every step in reading order.
 steps: { Guide.Step },
 -- The step the reader is on, an index into `steps`.
 cur: number,
 -- The suggestion the reader jumped to, by id.
 focus: string?,
 -- Step keys marked reviewed.
 reviewed: { [string]: boolean },
 -- Paths marked reviewed that no step visits.
 filesViewed: { [string]: boolean },
 -- The reader's call on each suggestion, by id.
 decisions: { [string]: Decision },
 own: { Own },
 verdict: VerdictId,
 summary: Fields.Field,
 posted: Posted?,
}

local M = {}

M.verdicts = {
 { id = "comment", event = "COMMENT", label = "Comment" },
 { id = "approve", event = "APPROVE", label = "Approve" },
 { id = "changes", event = "REQUEST_CHANGES", label = "Request changes" },
} :: { Verdict }

-- Suggestions within this many lines of a step belong to it.
local STEP_REACH = 3
-- A step owns the lines of its code block: its range plus this many either side.
local STEP_BLOCK_CONTEXT = 2

local function verdictOf(id: VerdictId): Verdict
 for _, verdict in M.verdicts do
  if verdict.id == id then return verdict end
 end
 return M.verdicts[1]
end

local function fileIndexes(r: Review): { [string]: number }
 local order = {}
 for i, file in r.pr.files do order[file.path] = i end
 return order
end

function M.new(pr: Pr.PR, guide: Guide.Guide): Review
 local steps = {}
 for _, change in guide.changes do
  for _, step in change.steps do table.insert(steps, step) end
 end
 return {
  pr = pr, guide = guide, steps = steps, cur = 1, focus = nil,
  reviewed = {}, filesViewed = {}, decisions = {}, own = {},
  verdict = "comment", summary = Fields.create(guide.summary, true), posted = nil,
 }
end

-- Steps and files

function M.keysOfChange(r: Review, change: number): { string }
 local keys = {}
 for _, step in r.steps do
  if step.change == change then table.insert(keys, step.key) end
 end
 return keys
end

function M.keysOfFile(r: Review, path: string): { string }
 local keys = {}
 for _, step in r.steps do
  if step.file == path then table.insert(keys, step.key) end
 end
 return keys
end

-- Each file of a change once, in the order its steps visit it.
function M.filesOfChange(r: Review, change: number): { Pr.File }
 local byPath = {}
 for _, file in r.pr.files do byPath[file.path] = file end
 local seen, files = {}, {}
 for _, step in r.guide.changes[change].steps do
  if not seen[step.file] then
   seen[step.file] = true
   table.insert(files, byPath[step.file])
  end
 end
 return files
end

-- The changed files no step visits.
function M.supportingFiles(r: Review): { Pr.File }
 local files = {}
 for _, file in r.pr.files do
  if #M.keysOfFile(r, file.path) == 0 then table.insert(files, file) end
 end
 return files
end

-- The first step of a change (or of its visit to `file`), as an index into `steps`.
function M.firstStep(r: Review, change: number, file: string?): number
 for i, step in r.steps do
  if step.change == change and (file == nil or step.file == file) then return i end
 end
 return 1
end

-- The step whose code block shows `line` of `file`.
function M.stepShowing(r: Review, file: string, line: number): number?
 for i, step in r.steps do
  if step.file == file and line >= step.from - STEP_BLOCK_CONTEXT and line <= step.to + STEP_BLOCK_CONTEXT then return i end
 end
 return nil
end

-- Reviewed state: a step's code block is the unit; a change or a guided file is reviewed when
-- all its blocks are; a supporting file has its own tick.

function M.reviewedCount(r: Review, keys: { string }): number
 local n = 0
 for _, key in keys do
  if r.reviewed[key] then n += 1 end
 end
 return n
end

function M.allReviewed(r: Review, keys: { string }): boolean
 return M.reviewedCount(r, keys) == #keys
end

function M.isFileReviewed(r: Review, path: string): boolean
 local keys = M.keysOfFile(r, path)
 if #keys == 0 then return r.filesViewed[path] == true end
 return M.allReviewed(r, keys)
end

-- The last step among `keys`, as an index into `steps`; 0 when none match.
function M.lastStep(r: Review, keys: { string }): number
 local last = 0
 for i, step in r.steps do
  if table.find(keys, step.key) then last = i end
 end
 return last
end

-- Marks the steps in `keys` reviewed; returns the ones that were not yet.
function M.mark(r: Review, keys: { string }): { string }
 local fresh = {}
 for _, key in keys do
  if not r.reviewed[key] then
   r.reviewed[key] = true
   table.insert(fresh, key)
  end
 end
 return fresh
end

function M.unmark(r: Review, keys: { string })
 for _, key in keys do r.reviewed[key] = nil end
end

-- Moves to the next unreviewed step after `from`, wrapping around; stays put when none is left.
function M.advance(r: Review, from: number)
 for offset = 1, #r.steps do
  local i = (from - 1 + offset) % #r.steps + 1
  if not r.reviewed[r.steps[i].key] then
   r.cur, r.focus = i, nil
   return
  end
 end
end

-- Suggestions

function M.suggestionsNear(r: Review, step: Guide.Step): { Guide.Comment }
 local near = {}
 for _, comment in r.guide.comments do
  if comment.file == step.file and comment.line >= step.from - STEP_REACH and comment.line <= step.to + STEP_REACH then
   table.insert(near, comment)
  end
 end
 return near
end

-- The suggestion the keys act on: the one jumped to, else the first undecided near the current
-- step, else the first near it.
function M.currentSuggestion(r: Review): Guide.Comment?
 if r.focus then
  for _, comment in r.guide.comments do
   if comment.id == r.focus then return comment end
  end
 end
 local near = M.suggestionsNear(r, r.steps[r.cur])
 for _, comment in near do
  if r.decisions[comment.id] == nil then return comment end
 end
 return near[1]
end

-- Ids of the suggestions near some step, in the order the steps are read.
function M.suggestionOrder(r: Review): { string }
 local order, seen = {}, {}
 for _, step in r.steps do
  for _, comment in M.suggestionsNear(r, step) do
   if not seen[comment.id] then
    seen[comment.id] = true
    table.insert(order, comment.id)
   end
  end
 end
 return order
end

function M.suggestion(r: Review, id: string): Guide.Comment?
 for _, comment in r.guide.comments do
  if comment.id == id then return comment end
 end
 return nil
end

-- Adds a suggestion to the review, dismisses it, or (nil) leaves it undecided again.
function M.decide(r: Review, id: string, decision: Decision?)
 r.decisions[id] = decision
end

-- The reader's own comments

-- Keeps a comment of the reader's on lines from..to; blank text is not a comment.
function M.addOwn(r: Review, file: string, from: number, to: number, body: string)
 if string.find(body, "%S") then
  table.insert(r.own, { file = file, from = from, to = to, body = body, excluded = false })
 end
end

-- The review

function M.setVerdict(r: Review, id: string)
 for _, verdict in M.verdicts do
  if verdict.id == id then r.verdict = verdict.id end
 end
end

-- Every comment the review could carry, grouped by file in PR order and by line within a file.
function M.items(r: Review): { Item }
 local order = fileIndexes(r)
 local items: { Item } = {}
 for _, comment in r.guide.comments do
  table.insert(items, { file = comment.file, line = comment.line, suggestion = comment, order = #items })
 end
 for i, own in r.own do
  table.insert(items, { file = own.file, line = own.from, own = i, order = #items })
 end
 table.sort(items, function(a: Item, b: Item): boolean
  if a.file ~= b.file then return (order[a.file] or 0) < (order[b.file] or 0) end
  if a.line ~= b.line then return a.line < b.line end
  return a.order < b.order
 end)
 return items
end

function M.isIncluded(r: Review, item: Item): boolean
 if item.suggestion then return r.decisions[item.suggestion.id] == "added" end
 return not r.own[item.own :: number].excluded
end

function M.include(r: Review, item: Item, on: boolean)
 if item.suggestion then
  r.decisions[item.suggestion.id] = if on then "added" else "dismissed"
 else
  r.own[item.own :: number].excluded = not on
 end
end

-- Includes every comment, or excludes every one when all are already included.
function M.toggleAll(r: Review)
 local items = M.items(r)
 local all = true
 for _, item in items do
  if not M.isIncluded(r, item) then all = false end
 end
 for _, item in items do M.include(r, item, not all) end
end

-- The item the review list starts on: the first suggestion still undecided, else the first.
function M.firstWaiting(r: Review): number
 for n, item in M.items(r) do
  if item.suggestion and r.decisions[item.suggestion.id] == nil then return n end
 end
 return 1
end

function M.counts(r: Review): Counts
 local filesReviewed, included, waiting = 0, 0, 0
 for _, file in r.pr.files do
  if M.isFileReviewed(r, file.path) then filesReviewed += 1 end
 end
 for _, comment in r.guide.comments do
  local decision = r.decisions[comment.id]
  if decision == "added" then included += 1 elseif decision == nil then waiting += 1 end
 end
 for _, own in r.own do
  if not own.excluded then included += 1 end
 end
 return { filesReviewed = filesReviewed, included = included, waiting = waiting }
end

-- Exactly what submitting posts: the PR head, the summary, the verdict, and each included comment
-- on its line (or on start_line..line for a range of the reader's).
function M.reviewPayload(r: Review): Payload
 local comments: { PostedComment } = {}
 for _, item in M.items(r) do
  if M.isIncluded(r, item) then
   if item.suggestion then
    table.insert(comments, { path = item.file, line = item.suggestion.line, side = "RIGHT", body = item.suggestion.body })
   else
    local own = r.own[item.own :: number]
    local range = own.from < own.to
    table.insert(comments, {
     path = own.file, line = own.to, side = "RIGHT",
     start_line = if range then own.from else nil, start_side = if range then "RIGHT" else nil,
     body = own.body,
    })
   end
  end
 end
 return { commit_id = r.pr.head, body = r.summary.text, event = verdictOf(r.verdict).event, comments = comments }
end

return M
