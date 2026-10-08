--!strict
local Diff = require("./diff")
local Review = require("./review")
local Text = require("./text")

-- Where choosing a result goes; exactly one of `step`, `suggestion`, `own` or `file` is set.
export type Target = {
 -- A step, as an index into the review's steps.
 step: number?,
 -- A suggested comment, by id.
 suggestion: string?,
 -- One of the reader's comments, by index.
 own: number?,
 -- A file; with `entry`, one changed line of it.
 file: string?,
 entry: number?,
}

export type Result = { kind: string, text: string, sub: string, go: Target }

local MAX_RESULTS = 12
local PREVIEW_CHARS = 100

local M = {}

-- Steps, files, comments and changed lines of the PR that contain `query`, in that order; without
-- a guide each step is a whole file, so files stand for them. A plain substring scan per
-- keystroke; a PR's rows are few enough that no index is needed.
function M.run(query: string, r: Review.Review, diffs: { [string]: Diff.FileDiff }): { Result }
 local results: { Result } = {}
 local needle = string.lower(query)
 if needle == "" then return results end
 local function has(text: string): boolean
  return string.find(string.lower(text), needle, 1, true) ~= nil
 end
 local function add(result: Result)
  if #results < MAX_RESULTS then table.insert(results, result) end
 end
 local author = r.guide.author

 if r.guide.guided then
  for i, step in r.steps do
   if has(step.title) or has(step.note) then
    add({ kind = "Step", text = step.title, sub = "Change " .. step.change .. "  ·  " .. r.guide.changes[step.change].title, go = { step = i } })
   end
  end
 end
 for _, file in r.pr.files do
  if has(file.path) then
   add({ kind = "File", text = Text.baseName(file.path), sub = file.path, go = { file = file.path } })
  end
 end
 for _, comment in r.guide.comments do
  if has(comment.body) then
   add({ kind = "Comment", text = Text.preview(comment.body, PREVIEW_CHARS), sub = author .. "  ·  " .. Text.location(comment.file, comment.line, comment.line), go = { suggestion = comment.id } })
  end
 end
 for i, own in r.own do
  if has(own.body) then
   add({ kind = "Comment", text = Text.preview(own.body, PREVIEW_CHARS), sub = "You  ·  " .. Text.location(own.file, own.from, own.to), go = { own = i } })
  end
 end
 for _, file in r.pr.files do
  for i, entry in diffs[file.path].entries do
   if entry.diff and has(entry.row.text) then
    local line = entry.row.new or entry.row.old :: number
    add({
     kind = "Code", text = string.match(entry.row.text, "^%s*(.-)%s*$") :: string,
     sub = Text.location(file.path, line, line) .. (if entry.row.kind == "del" then "  ·  removed" else ""),
     go = { file = file.path, entry = i },
    })
   end
  end
 end
 return results
end

return M
