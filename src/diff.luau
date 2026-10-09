--!strict
local Pr = require("./pr")
local Text = require("./text")

-- Byte positions in a line: `from` is the first, `to` the one after the last.
export type Span = { from: number, to: number }
-- Entry numbers, both included.
export type Interval = { first: number, last: number }

-- One line of the new-side file. Lines the PR's diff lists carry `diff = true`, the word-diff span
-- of a paired removed/added line, and the hunk label when they open a hunk. Unchanged lines
-- between hunks are filled in from the file source.
export type Entry = {
 row: Pr.Line,
 diff: boolean,
 changed: Span?,
 label: string?,
 -- The new-side line the entry sits at; a removed line belongs with the line after it.
 anchor: number?,
}

export type Token = { text: string, kind: string, changed: boolean }

export type Rows = { kind: "rows", first: number, last: number }
-- A run of unchanged lines of a big file, left to Tern's own code viewer.
export type Native = { kind: "native", first: number, last: number }
-- A run of hidden unchanged lines; `reveal` is what a click opens.
export type Gap = {
 kind: "gap", first: number, last: number,
 hidden: number, reveal: Interval, arrow: string, label: string?,
}
export type Segment = Rows | Native | Gap

-- A code block as segments in file order, with the number of lines it draws as rows; `key` is
-- what it was laid out for.
export type Layout = { key: string, segments: { Segment }, rows: number }

export type FileDiff = {
 file: Pr.File,
 entries: { Entry },
 highlighted: boolean,
 language: string,
 -- Joined text of native runs, by "first-last".
 runs: { [string]: string },
 -- Colored pieces of each entry, by entry number, filled in as lines are first drawn.
 tokens: { [number]: { Token } },
 -- The last layout of each block on the file, by the lines it is based on.
 layouts: { [string]: Layout },
}

-- What a code block shows of a file.
export type Show = {
 -- The entries of the steps the block shows (see `stepSpan`); it starts with the PR's lines within
 -- a couple of lines of them. Nil starts with every line of the PR's diff.
 spans: { Interval }?,
 -- The whole file was asked for.
 whole: boolean,
 -- New-side lines with cards hung under them.
 annotated: { [number]: boolean },
 -- The entry a search jumped to.
 hit: number?,
 -- Ranges the reader opened.
 reveals: { Interval },
}

local KEYWORDS: { [string]: boolean } = {}
for word in string.gmatch("const let var function return if else for while of in new await async export import from type interface class extends implements this null undefined true false throw try catch typeof as readonly", "%S+") do
 KEYWORDS[word] = true
end

local LANGUAGES: { [string]: string } = { ts = "ts", tsx = "tsx", js = "js", md = "markdown", json = "json", luau = "lua", css = "css" }

-- Entries a step shows on each side of its range.
local STEP_CONTEXT = 2
-- Unchanged lines that stay as rows on each side of a change when a big file is shown whole.
local NEAR = 3
-- A file shown whole with more lines than this draws its unchanged stretches natively.
local WHOLE_MAX = 800
-- Lines one click on a gap opens.
local EXPAND_STEP = 20

local M = {}

-- Changed middle of a paired removed/added line: the span on each side.
local function changedMiddle(old: string, new: string): (Span, Span)
 local prefix = 0
 while prefix < #old and prefix < #new and string.byte(old, prefix + 1) == string.byte(new, prefix + 1) do prefix += 1 end
 local suffix = 0
 while suffix < #old - prefix and suffix < #new - prefix and string.byte(old, #old - suffix) == string.byte(new, #new - suffix) do suffix += 1 end
 return { from = prefix + 1, to = #old - suffix + 1 }, { from = prefix + 1, to = #new - suffix + 1 }
end

local function rowText(row: Pr.Row): string
 return if row.kind == "hunk" then "" else row.text
end

local function trimmed(span: Span, text: string): Span
 local first = string.find(text, "%S") or (#text + 1)
 local last = #text
 while last > 0 and string.match(string.sub(text, last, last), "%s") do last -= 1 end
 return { from = math.max(span.from, first), to = math.min(span.to, last + 1) }
end

-- Pairs each run of removed lines with the added lines after it: row index -> changed span.
local function pairChanges(rows: { Pr.Row }): { [number]: Span }
 local spans: { [number]: Span } = {}
 local i = 1
 while i <= #rows do
  if rows[i].kind == "del" then
   local firstDel = i
   while i <= #rows and rows[i].kind == "del" do i += 1 end
   local firstAdd = i
   while i <= #rows and rows[i].kind == "add" do i += 1 end
   local dels, adds = firstAdd - firstDel, i - firstAdd
   for k = 0, math.min(dels, adds) - 1 do
    spans[firstDel + k], spans[firstAdd + k] = changedMiddle(rowText(rows[firstDel + k]), rowText(rows[firstAdd + k]))
   end
   if dels > 0 and adds > 0 and dels ~= adds then
    -- Several removed lines collapsed into one added line (or the reverse): compare the joined removed text.
    local firstText = rowText(rows[firstDel])
    local joined = ""
    for k = 0, dels - 1 do
     joined ..= (if k == 0 then "" else " ") .. string.gsub(rowText(rows[firstDel + k]), "^%s+", "")
    end
    joined = (string.match(firstText, "^%s*") :: string) .. joined
    local _, addedSpan = changedMiddle(joined, rowText(rows[firstAdd]))
    spans[firstAdd] = addedSpan
    for k = 1, dels - 1 do spans[firstDel + k] = { from = 1, to = #rowText(rows[firstDel + k]) + 1 } end
    spans[firstDel] = (changedMiddle(firstText, rowText(rows[firstAdd])))
   end
  else
   i += 1
  end
 end
 for index, span in spans do spans[index] = trimmed(span, rowText(rows[index])) end
 return spans
end

local function buildEntries(file: Pr.File, spans: { [number]: Span }): { Entry }
 local entries: { Entry } = {}
 local src = file.src or {}
 local newN, oldN, label = 1, 1, nil
 local function fillUnchanged(untilNew: number)
  while newN < untilNew and newN <= #src do
   local row: Pr.Line = { kind = "ctx", old = oldN, new = newN, text = src[newN] }
   table.insert(entries, { row = row, diff = false })
   newN += 1
   oldN += 1
  end
 end
 for index, row in file.rows do
  if row.kind == "hunk" then
   fillUnchanged(row.newStart)
   newN, oldN, label = row.newStart, row.oldStart, row.label
  else
   table.insert(entries, { row = row, diff = true, changed = spans[index], label = label })
   label = nil
   if row.new then newN = row.new + 1 end
   if row.old then oldN = row.old + 1 end
  end
 end
 fillUnchanged(#src + 1)
 return entries
end

local function anchorEntries(entries: { Entry })
 local following: number? = nil
 for i = #entries, 1, -1 do
  local line = entries[i].row.new
  following = line or following
  entries[i].anchor = following
 end
 local preceding: number? = nil
 for _, entry in entries do
  preceding = entry.row.new or preceding
  entry.anchor = entry.anchor or preceding
 end
end

-- Whether a block starts with entry `i`: a line of the PR's diff, and for a block of steps within a
-- couple of entries of one of their `spans`.
local function inBase(entries: { Entry }, i: number, spans: { Interval }?): boolean
 if not entries[i].diff then return false end
 if spans == nil then return true end
 for _, span in spans do
  if i >= span.first - STEP_CONTEXT and i <= span.last + STEP_CONTEXT then return true end
 end
 return false
end

-- Rows of the entries to draw: every shown entry, and for a big file shown whole only those near
-- changes, comments and the search hit.
local function shownEntries(fd: FileDiff, show: Show): ({ boolean }, boolean)
 local entries = fd.entries
 local total = #entries
 local big = show.whole and total > WHOLE_MAX
 local shown = table.create(total, false)
 for i = 1, total do shown[i] = (show.whole and not big) or inBase(entries, i, show.spans) end
 if big then
  for i, entry in entries do
   if entry.diff then
    for j = math.max(i - NEAR, 1), math.min(i + NEAR, total) do shown[j] = true end
   elseif entry.row.new and show.annotated[entry.row.new] then
    shown[i] = true
   end
  end
  if show.hit and entries[show.hit] then shown[show.hit] = true end
 end
 for _, range in show.reveals do
  for i = math.max(range.first, 1), math.min(range.last, total) do shown[i] = true end
 end
 return shown, big
end

-- A click opens the lines nearest the code (all of them when few are left); the arrow says which
-- way the gap grows.
local function gapAt(first: number, last: number, total: number, label: string?): Gap
 local hidden = last - first + 1
 local from, to, arrow = first, math.min(last, first + EXPAND_STEP - 1), "↓"
 if first == 1 then
  from, to, arrow = math.max(first, last - EXPAND_STEP + 1), last, "↑"
 elseif last < total then
  arrow = "↕"
 end
 if hidden <= EXPAND_STEP + 10 then from, to = first, last end
 return { kind = "gap", first = first, last = last, hidden = hidden, reveal = { first = from, last = to }, arrow = arrow, label = label }
end

local function tokenize(line: string): { { string } }
 local tokens, i, n = {}, 1, #line
 local function take(last: number, kind: string)
  table.insert(tokens, { string.sub(line, i, last), kind })
  i = last + 1
 end
 while i <= n do
  local c = string.sub(line, i, i)
  local _, last = string.find(line, "^%s+", i)
  if last then take(last, "plain"); continue end
  if string.sub(line, i, i + 1) == "//" then take(n, "com"); break end
  if c == '"' or c == "'" or c == "`" then
   local j = i + 1
   while j <= n and string.sub(line, j, j) ~= c do
    if string.sub(line, j, j) == "\\" then j += 1 end
    j += 1
   end
   take(math.min(j, n), "str")
   continue
  end
  _, last = string.find(line, "^[%a_$][%w_$]*", i)
  if last then
   local word = string.sub(line, i, last)
   take(last, if KEYWORDS[word] then "kw" elseif string.match(word, "^%u") then "type" elseif string.sub(line, last + 1, last + 1) == "(" then "fn" else "plain")
   continue
  end
  _, last = string.find(line, "^%d+", i)
  if last then take(last, "num"); continue end
  take(i, "punct")
 end
 return tokens
end

-- Splits tokens at the edges of `changed`, flagging the pieces inside it.
local function markChanged(tokens: { { string } }, changed: Span?): { Token }
 local out: { Token } = {}
 local pos = 1
 for _, token in tokens do
  local text, kind = token[1], token[2]
  local first, after = pos, pos + #text
  if not changed or changed.from >= changed.to then
   table.insert(out, { text = text, kind = kind, changed = false })
  else
   local cuts = { first }
   if changed.from > first and changed.from < after then table.insert(cuts, changed.from) end
   if changed.to > first and changed.to < after then table.insert(cuts, changed.to) end
   table.insert(cuts, after)
   for k = 1, #cuts - 1 do
    table.insert(out, {
     text = string.sub(text, cuts[k] - first + 1, cuts[k + 1] - first),
     kind = kind,
     changed = cuts[k] >= changed.from and cuts[k] < changed.to,
    })
   end
  end
  pos = after
 end
 return out
end

-- Prepares a file for display: word-diff spans, the whole new-side file as entries, line anchors.
function M.analyze(file: Pr.File): FileDiff
 local entries = buildEntries(file, pairChanges(file.rows))
 anchorEntries(entries)
 local extension = Text.extension(file.path)
 return {
  file = file,
  entries = entries,
  highlighted = extension == "ts",
  language = LANGUAGES[extension] or extension,
  runs = {},
  tokens = {},
  layouts = {},
 }
end

-- The entries a step covers, first to last of the lines of the PR's diff in its range: those
-- numbered within it on its side, and on the new side the removed lines that sit at them. Nil when
-- the range holds none.
function M.stepSpan(fd: FileDiff, step: { side: "new" | "old", from: number, to: number }): Interval?
 local first: number?, last: number? = nil, nil
 for i, entry in fd.entries do
  if entry.diff then
   local row = entry.row
   local line, within
   if step.side == "old" then
    line = row.old
    within = line ~= nil and line >= step.from and line <= step.to
   else
    line = row.new or entry.anchor
    within = line ~= nil and (row.new ~= nil or row.kind == "del") and line >= step.from and line <= step.to
   end
   if within then
    first = first or i
    last = i
   end
  end
 end
 if first and last then return { first = first, last = last } end
 return nil
end

-- The part of new-side lines from..to one GitHub review comment can cover: the lines of the PR's
-- diff in the last hunk that reaches into the range. Nil when no line of the diff is in it.
function M.commentableRange(fd: FileDiff, from: number, to: number): (number?, number?)
 local first, last, inHunk = nil, nil, false
 for _, entry in fd.entries do
  local line = entry.row.new
  if line and line >= from and line <= to then
   if not entry.diff then
    inHunk = false
   elseif not inHunk then
    first, last, inHunk = line, line, true
   else
    last = line
   end
  end
 end
 return first, last
end

-- What a layout of `show` depends on besides the file, as one string.
local function layoutKey(show: Show): string
 local parts = { if show.whole then "whole" else "diff", tostring(show.hit or "") }
 for _, range in show.reveals do table.insert(parts, range.first .. "-" .. range.last) end
 if show.whole then
  local lines = {}
  for line in show.annotated do table.insert(lines, line) end
  table.sort(lines)
  table.insert(parts, table.concat(lines, ","))
 end
 return table.concat(parts, "|")
end

-- The code block as a sequence of line runs, hidden gaps and native runs, in file order. Each
-- block's last layout is kept until what it shows changes, so redrawing the page lays out nothing.
function M.layout(fd: FileDiff, show: Show): Layout
 local base = "all"
 if show.spans then
  local parts = {}
  for _, span in show.spans do table.insert(parts, span.first .. "-" .. span.last) end
  base = table.concat(parts, ",")
 end
 local key = layoutKey(show)
 local kept = fd.layouts[base]
 if kept and kept.key == key then return kept end
 local total = #fd.entries
 local shown, big = shownEntries(fd, show)
 local segments: { Segment } = {}
 local rows = 0
 local i = 1
 while i <= total do
  local first = i
  local visible = shown[i]
  while i <= total and shown[i] == visible do i += 1 end
  local last = i - 1
  if visible then
   table.insert(segments, { kind = "rows", first = first, last = last } :: Rows)
   rows += last - first + 1
  elseif big then
   table.insert(segments, { kind = "native", first = first, last = last } :: Native)
  else
   local following = fd.entries[i]
   table.insert(segments, gapAt(first, last, total, following and following.label))
  end
 end
 local layout = { key = key, segments = segments, rows = rows }
 fd.layouts[base] = layout
 return layout
end

-- The text of entries first..last, joined once per run.
function M.runText(fd: FileDiff, first: number, last: number): string
 local key = first .. "-" .. last
 local text = fd.runs[key]
 if not text then
  local lines = table.create(last - first + 1)
  for i = first, last do table.insert(lines, fd.entries[i].row.text) end
  text = table.concat(lines, "\n")
  fd.runs[key] = text
 end
 return text
end

-- Colored pieces of entry `i` of a highlighted file, tokenized once.
function M.tokens(fd: FileDiff, i: number): { Token }
 local entry = fd.entries[i]
 local tokens = fd.tokens[i]
 if not tokens then
  tokens = markChanged(tokenize(entry.row.text), entry.changed)
  fd.tokens[i] = tokens
 end
 return tokens
end

return M
