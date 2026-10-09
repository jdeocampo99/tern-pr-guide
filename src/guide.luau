--!strict
local FileTree = require("./file-tree")
local Pr = require("./pr")
local Text = require("./text")

export type Kind = "problem" | "question" | "suggestion" | "nit"
export type Tone = "added" | "changed" | "removed"

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
 from: number,
 to: number,
 title: string,
 note: string,
}

export type Change = { title: string, why: string, steps: { Step } }

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

type StepSpec = { file: string, from: number, to: number, title: string, note: string }
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

-- Gives every step its change, its place in the change, its place overall, and its key.
local function numbered(specs: { ChangeSpec }): { Change }
 local changes, position = {}, 0
 for ci, spec in specs do
  local steps = {}
  for si, step in spec.steps do
   position += 1
   table.insert(steps, {
    key = "c" .. ci .. "s" .. si, change = ci, index = si, position = position,
    file = step.file, from = step.from, to = step.to, title = step.title, note = step.note,
   })
  end
  table.insert(changes, { title = spec.title, why = spec.why, steps = steps })
 end
 return changes
end

local function singleChange(pr: Pr.PR): { Change }
 local steps = {}
 for _, file in FileTree.order(pr.files) do
  local from, to = diffSpan(file)
  table.insert(steps, { file = file.path, from = from, to = to, title = file.path, note = "" })
 end
 return numbered({ { title = pr.title, why = "", steps = steps } })
end

local function parseSteps(raw: any, files: { [string]: Pr.File }): { StepSpec }
 local steps = {}
 if type(raw) ~= "table" then return steps end
 for _, item in raw do
  if type(item) == "table" and type(item.file) == "string" and files[item.file]
   and isLine(item.from) and isLine(item.to) and item.from <= item.to then
   table.insert(steps, {
    file = item.file, from = item.from, to = item.to,
    title = text(item.title, item.file), note = text(item.note, ""),
   })
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
