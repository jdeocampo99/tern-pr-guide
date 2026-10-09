--!strict
local FileTree = require("./file-tree")
local Pr = require("./pr")
local Text = require("./text")

export type Kind = "problem" | "question" | "suggestion" | "nit"
export type Tone = "added" | "changed" | "removed"
-- Which file's line numbers a step's range is in: the new one (after the PR) or the old one.
export type Side = "new" | "old"
export type Span = { from: number, to: number }

export type Step = {
 -- Stable node key, "c<change>s<index>".
 key: string,
 -- Number of the change it belongs to, 1-based.
 change: number,
 -- Place within its change, 1-based.
 index: number,
 -- Place among all steps in reading order, 1-based.
 position: number,
 file: string,
 -- Which file `from`..`to` count lines in; a range on the old side points at removed lines.
 side: Side,
 from: number,
 to: number,
 -- Where the step sits in the new file's numbering: `from`..`to` itself on the new side, the lines
 -- its removed lines sat at on the old side.
 at: Span,
 -- The code block that shows it: the id of the first step of its run of consecutive steps on one
 -- file in one change, so those steps share a block.
 block: string,
 title: string,
 note: string,
}

export type Change = { title: string, why: string, steps: { Step } }

-- A run of consecutive steps on one file in one change, drawn as one code block.
export type Block = { id: string, file: string, steps: { Step } }

export type Comment = { id: string, file: string, line: number, kind: Kind, body: string }

export type Box = { type: "box", text: string, kind: Tone?, change: number?, note: string? }
export type Edge = { type: "edge", label: string }
export type Arm = { label: string, text: string }
export type Fork = { type: "fork", arms: { Arm } }
export type FlowItem = Box | Edge | Fork
export type Flow = { title: string, subtitle: string, rows: { { FlowItem } } }

export type Guide = {
 -- Whether the steps came from a guide file; without one there is a step per file, in tree order.
 guided: boolean,
 -- The PR commit the guide was written against.
 head: string?,
 -- Who suggested the comments.
 author: string,
 -- The review lens the guide was written through, when it says.
 lens: string?,
 overview: string,
 flow: Flow?,
 changes: { Change },
 comments: { Comment },
 -- The drafted opening comment of the review.
 summary: string,
}

type StepSpec = { file: string, side: Side, from: number, to: number, at: Span, title: string, note: string }
type ChangeSpec = { title: string, why: string, steps: { StepSpec } }

local SCHEMA = 1
local DEFAULT_AUTHOR = "Guide"

local KINDS: { [string]: boolean } = { problem = true, question = true, suggestion = true, nit = true }
local TONES: { [string]: boolean } = { added = true, changed = true, removed = true }

local function text(value: any, fallback: string): string
 return if type(value) == "string" then value else fallback
end

local function isLine(value: any): boolean
 return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function indexFiles(pr: Pr.PR): { [string]: Pr.File }
 local files = {}
 for _, file in pr.files do files[file.path] = file end
 return files
end

local function newSideLines(file: Pr.File): { [number]: boolean }
 local lines = {}
 for _, row in file.rows do
  if row.kind ~= "hunk" and row.new then lines[row.new] = true end
 end
 return lines
end

-- The new-side lines a file's diff covers; a file with none (deleted) spans line 1.
local function diffSpan(file: Pr.File): (number, number)
 local first, last = math.huge, 0
 for line in newSideLines(file) do
  first, last = math.min(first, line), math.max(last, line)
 end
 if last == 0 then return 1, 1 end
 return first, last
end

-- Gives every step its change, its place in the change, its place overall, its key and its block.
local function numbered(specs: { ChangeSpec }): { Change }
 local changes, position = {}, 0
 for ci, spec in specs do
  local steps: { Step } = {}
  for si, step in spec.steps do
   position += 1
   local key = "c" .. ci .. "s" .. si
   local previous = steps[#steps]
   table.insert(steps, {
    key = key, change = ci, index = si, position = position,
    file = step.file, side = step.side, from = step.from, to = step.to, at = step.at,
    block = if previous and previous.file == step.file then previous.block else key,
    title = step.title, note = step.note,
   })
  end
  table.insert(changes, { title = spec.title, why = spec.why, steps = steps })
 end
 return changes
end

local function singleChange(pr: Pr.PR): { Change }
 local steps: { StepSpec } = {}
 for _, file in FileTree.order(pr.files) do
  local from, to = diffSpan(file)
  local step: StepSpec = { file = file.path, side = "new", from = from, to = to, at = { from = from, to = to }, title = file.path, note = "" }
  table.insert(steps, step)
 end
 return numbered({ { title = pr.title, why = "", steps = steps } })
end

-- The number of `row` on `side`, nil when the line isn't there.
local function numberOn(row: Pr.Row, side: Side): number?
 if row.kind == "hunk" then return nil end
 return if side == "old" then row.old else row.new
end

-- Whether lines from..to on `side` of `file` hold a line the PR changed: an added line on the new
-- side, a removed one on the old side.
local function touchesChange(file: Pr.File, side: Side, from: number, to: number): boolean
 local kind = if side == "old" then "del" else "add"
 for _, row in file.rows do
  local line = numberOn(row, side)
  if row.kind == kind and line and line >= from and line <= to then return true end
 end
 return false
end

-- The new-file line the row `i` of `rows` sits at: its own, else that of the next line in its hunk
-- (a removed line sits before it), else the one before.
local function newLineAt(rows: { Pr.Row }, i: number): number?
 if rows[i].kind ~= "hunk" and (rows[i] :: Pr.Line).new then return (rows[i] :: Pr.Line).new end
 for step = 1, -1, -2 do
  local j = i + step
  while rows[j] and rows[j].kind ~= "hunk" do
   local line = (rows[j] :: Pr.Line).new
   if line then return line end
   j += step
  end
 end
 return nil
end

-- Where lines from..to on `side` of `file` sit in the new file's numbering.
local function placeOf(file: Pr.File, side: Side, from: number, to: number): Span
 if side == "new" then return { from = from, to = to } end
 local first, last = nil, nil
 for i, row in file.rows do
  local line = numberOn(row, side)
  if line and line >= from and line <= to then
   first = first or i
   last = i
  end
 end
 local a = if first then newLineAt(file.rows, first) else nil
 local b = if last then newLineAt(file.rows, last) else nil
 return { from = a or b or 1, to = b or a or 1 }
end

-- A change's steps as the guide wrote them, minus the ones that point at nothing: a step needs a
-- changed line in its range (see `touchesChange`). One that has none is about untouched code, so
-- its note joins the note of the change's step before it when that is on the same file, and
-- otherwise it is dropped.
local function parseSteps(raw: any, files: { [string]: Pr.File }): { StepSpec }
 local steps: { StepSpec } = {}
 if type(raw) ~= "table" then return steps end
 for _, item in raw do
  if type(item) == "table" and type(item.file) == "string" and files[item.file]
   and (item.side == nil or item.side == "new" or item.side == "old")
   and isLine(item.from) and isLine(item.to) and item.from <= item.to then
   local file = files[item.file]
   local side: Side = if item.side == "old" then "old" else "new"
   local note = text(item.note, "")
   if touchesChange(file, side, item.from, item.to) then
    table.insert(steps, {
     file = item.file, side = side, from = item.from, to = item.to, at = placeOf(file, side, item.from, item.to),
     title = text(item.title, item.file), note = note,
    })
   else
    local previous = steps[#steps]
    if previous and previous.file == item.file and note ~= "" then
     previous.note = if previous.note == "" then note else previous.note .. " " .. note
    end
   end
  end
 end
 return steps
end

local function parseChanges(raw: any, files: { [string]: Pr.File }): { Change }
 local specs: { ChangeSpec } = {}
 if type(raw) ~= "table" then return {} end
 for _, item in raw do
  if type(item) == "table" then
   local steps = parseSteps(item.steps, files)
   if #steps > 0 then
    table.insert(specs, { title = text(item.title, "Change " .. (#specs + 1)), why = text(item.why, ""), steps = steps })
   end
  end
 end
 return numbered(specs)
end

local function parseComments(raw: any, files: { [string]: Pr.File }): { Comment }
 local comments, seen, lineSets = {}, {}, {}
 if type(raw) ~= "table" then return comments end
 for _, item in raw do
  local file = if type(item) == "table" and type(item.file) == "string" then files[item.file] else nil
  if file and type(item.id) == "string" and item.id ~= "" and not seen[item.id]
   and KINDS[item.kind] and type(item.body) == "string" and item.body ~= "" and isLine(item.line) then
   lineSets[file.path] = lineSets[file.path] or newSideLines(file)
   if lineSets[file.path][item.line] then
    seen[item.id] = true
    table.insert(comments, { id = item.id, file = item.file, line = item.line, kind = item.kind, body = item.body })
   end
  end
 end
 return comments
end

local function parseFlowItem(raw: any, changeCount: number): FlowItem?
 if type(raw) ~= "table" then return nil end
 if type(raw.branch) == "table" then
  local arms = {}
  for _, arm in raw.branch do
   if type(arm) == "table" and type(arm.text) == "string" then
    table.insert(arms, { label = text(arm.edge, ""), text = arm.text })
   end
  end
  return if #arms > 0 then { type = "fork", arms = arms } else nil
 end
 if type(raw.edge) == "string" then return { type = "edge", label = raw.edge } end
 if type(raw.text) ~= "string" then return nil end
 local change = if isLine(raw.change) and raw.change <= changeCount then raw.change else nil
 return {
  type = "box", text = raw.text, kind = if TONES[raw.kind] then raw.kind else nil,
  change = change, note = if type(raw.note) == "string" then raw.note else nil,
 }
end

local function parseFlow(raw: any, changeCount: number): Flow?
 if type(raw) ~= "table" or type(raw.rows) ~= "table" then return nil end
 local rows = {}
 for _, rawRow in raw.rows do
  local row = {}
  if type(rawRow) == "table" then
   for _, rawItem in rawRow do
    local item = parseFlowItem(rawItem, changeCount)
    if item then table.insert(row, item) end
   end
  end
  if #row > 0 then table.insert(rows, row) end
 end
 if #rows == 0 then return nil end
 return { title = text(raw.title, ""), subtitle = text(raw.subtitle, ""), rows = rows }
end

local M = {}

-- `steps` cut into the code blocks that show them: runs of consecutive steps on one file.
function M.blocks(steps: { Step }): { Block }
 local blocks: { Block } = {}
 for _, step in steps do
  local last = blocks[#blocks]
  if last and last.id == step.block then
   table.insert(last.steps, step)
  else
   table.insert(blocks, { id = step.block, file = step.file, steps = { step } })
  end
 end
 return blocks
end

-- A guide from decoded JSON, or nil when it isn't a guide file. Steps and comments that don't fit
-- the PR are dropped; a guide left with no steps falls back to the one-change walkthrough.
function M.parse(raw: any, pr: Pr.PR): Guide?
 if type(raw) ~= "table" or raw.schema ~= SCHEMA then return nil end
 local files = indexFiles(pr)
 local changes = parseChanges(raw.changes, files)
 local guided = #changes > 0
 if not guided then changes = singleChange(pr) end
 return {
  guided = guided,
  head = if type(raw.head) == "string" then raw.head else nil,
  author = if type(raw.author) == "string" and raw.author ~= "" then raw.author else DEFAULT_AUTHOR,
  lens = if type(raw.lens) == "string" and raw.lens ~= "" then raw.lens else nil,
  overview = text(raw.overview, ""),
  flow = parseFlow(raw.flow, #changes),
  changes = changes,
  comments = parseComments(raw.comments, files),
  summary = text(raw.summary, ""),
 }
end

-- What the page shows when no guide exists: one change named after the PR with a step per changed
-- file spanning its diff, and nothing suggested.
function M.defaultGuide(pr: Pr.PR): Guide
 return {
  guided = false,
  head = pr.head,
  author = DEFAULT_AUTHOR,
  lens = nil,
  overview = "",
  flow = nil,
  changes = singleChange(pr),
  comments = {},
  summary = "",
 }
end

-- `guide` read as the plain file list: one change, a step per changed file, and everything the
-- guide says about the PR (suggested comments, author, lens, head, summary) kept.
function M.filesOf(guide: Guide, pr: Pr.PR): Guide
 local files = M.defaultGuide(pr)
 files.head, files.author, files.lens, files.summary, files.comments = guide.head, guide.author, guide.lens, guide.summary, guide.comments
 return files
end

-- The guide file at `path` for `pr`, or why it can't be used. The one place guide data enters
-- the plugin.
function M.read(path: string, pr: Pr.PR): (Guide?, string?)
 local decoded, raw = pcall(function(): any
  return tern.json.decode(tern.fs.read(path))
 end)
 if not decoded then return nil, Text.errorLine(raw) end
 local guide = M.parse(raw, pr)
 if not guide then return nil, "not a guided review (expected \"schema\": " .. SCHEMA .. ")" end
 return guide, nil
end

-- Whether the PR has moved on since the guide was written.
function M.isStale(guide: Guide, pr: Pr.PR): boolean
 return guide.head ~= pr.head
end

return M
