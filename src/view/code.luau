--!strict
-- Code blocks: a file header pinned while its code scrolls, then diff lines with hidden runs as gap
-- bars, comment cards under their lines, and long unchanged stretches of big files drawn natively.
local Comments = require("./comments")
local Diff = require("../diff")
local Guide = require("../guide")
local Pr = require("../pr")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

export type Head = {
 -- The range label beside the path.
 label: string?,
 -- What a click on the path does.
 toggle: string,
 expanded: boolean,
 blockId: string,
 done: boolean,
 check: Node,
}

local el, span = Ui.el, Ui.span

-- Layout estimates (px) measured in Tern; they size the unroll animation.
local ROW_H, GAP_H = 19, 26
local SIGNS = { add = "+", del = "-", ctx = " " }

local M = {}

function M.head(s: State.State, file: Pr.File, head: Head): Node
 local kids = {
  el("span", { class = "gp-fpath", actions = { click = head.toggle } }, {
   span("gp-fcaret", if head.expanded then "▾" else "▸"),
   span("gp-fdir", Text.dirName(file.path)),
   span("gp-fbase", Text.baseName(file.path)),
  }),
  span("gp-frange", head.label or ""),
  Ui.spacer(),
  span("gp-adds", "+" .. file.adds),
  span("gp-dels", "−" .. file.dels),
 }
 if head.expanded and file.src then
  table.insert(kids, el("span", {
   class = "gp-wholefile",
   text = if s.whole[head.blockId] then "Show only the diff" else "Show whole file",
   actions = { click = "whole=" .. head.blockId },
  }))
 end
 table.insert(kids, head.check)
 return el("div", { class = "gp-fhead" .. (if head.done then " gp-fhead-done" else ""), key = "fhead" }, kids)
end

-- The line's code: colored pieces, or its text alone when the block draws `plain` or the file
-- isn't highlighted.
local function codeSpan(fd: Diff.FileDiff, i: number, plain: boolean): Node
 if plain or not fd.highlighted then return el("span", { class = "gp-code", text = fd.entries[i].row.text }) end
 local nodes = {}
 for _, token in Diff.tokens(fd, i) do
  table.insert(nodes, span("gp-" .. token.kind .. (if token.changed then " gp-chg" else ""), token.text))
 end
 return el("span", { class = "gp-code" }, nodes)
end

-- One diff line. New-side lines of the PR's diff carry a "+" that shows on hover and opens a
-- comment there; GitHub takes comments only on those. `selected` tints lines inside the range being
-- commented on; `hit` marks a search result.
local function lineRow(fd: Diff.FileDiff, i: number, plain: boolean, selected: boolean, hit: boolean): Node
 local entry = fd.entries[i]
 local row = entry.row
 return el("div", { class = "gp-row gp-" .. row.kind .. (if selected then " gp-selected" else "") .. (if hit then " gp-hit" else ""), key = "r" .. i }, {
  if row.new and entry.diff then el("span", { class = "gp-plus", text = "+", actions = { click = "comment=" .. fd.file.path .. "|" .. row.new } }) else span("gp-plus-none", ""),
  span("gp-gut", if row.old then tostring(row.old) else ""),
  span("gp-gut", if row.new then tostring(row.new) else ""),
  span("gp-sign", SIGNS[row.kind]),
  codeSpan(fd, i, plain),
 })
end

-- A run of hidden unchanged lines as one quiet bar; a click opens its `reveal` lines.
local function gapRow(blockId: string, gap: Diff.Gap): Node
 local kids = {
  span("gp-gap-gut", gap.arrow),
  span("gp-gap-count", gap.hidden .. " unchanged " .. (if gap.hidden == 1 then "line" else "lines")),
 }
 if gap.label then table.insert(kids, span("gp-gap-label", gap.label)) end
 return el("div", { class = "gp-gap", key = "gap" .. gap.first, actions = { click = "reveal=" .. blockId .. "|" .. gap.reveal.first .. "|" .. gap.reveal.last } }, kids)
end

-- Tern's code viewer only draws the lines on screen, so a long unchanged run costs one node.
local function nativeRun(fd: Diff.FileDiff, run: Diff.Native): Node
 return el("div", { class = "gp-native", key = "n" .. run.first }, {
  tern.ui.code(Diff.runText(fd, run.first, run.last), fd.language, fd.entries[run.first].row.new),
 })
end

-- The rows of block `blockId` on `fd` showing `show`, uncolored when `plain`, and their estimated
-- height.
function M.rows(s: State.State, fd: Diff.FileDiff, blockId: string, show: Diff.Show, plain: boolean, cards: Comments.Cards): ({ Node }, number)
 local path = fd.file.path
 if fd.file.binary then
  return { el("div", { class = "gp-gap", key = "binary" }, { span("gp-gap-count", "Binary file, not shown") }) }, GAP_H
 end
 local hit = show.hit
 local c = if s.composer and s.composer.file == path then s.composer else nil
 local segments = Diff.layout(fd, show).segments
 local rows, height = {}, 0
 for _, segment in segments do
  if segment.kind == "rows" then
   for i = segment.first, segment.last do
    local line = fd.entries[i].row.new
    local selected = c ~= nil and line ~= nil and line >= c.from and line <= c.to
    table.insert(rows, lineRow(fd, i, plain, selected, hit == i))
    height += ROW_H
    local slot = if line then cards[line] else nil
    if slot then
     for _, node in slot.nodes do table.insert(rows, node) end
     height += slot.height
    end
   end
  elseif segment.kind == "native" then
   table.insert(rows, nativeRun(fd, segment))
   height += (segment.last - segment.first + 1) * ROW_H
  else
   table.insert(rows, gapRow(blockId, segment))
   height += GAP_H
  end
 end
 return rows, height
end

-- One step's code block: the step's lines and a couple either side, folded once reviewed or when
-- `plan` leaves it folded. The step you are on keeps a steady outline.
function M.step(s: State.State, motion: Ui.Motion, plan: State.Plan, step: Guide.Step): Node
 local key = step.key
 local fd = s.diffs[step.file]
 local reviewed = s.review.reviewed[key] == true
 local open = plan.open[key] == true
 local head = M.head(s, fd.file, {
  label = "lines " .. step.from .. "–" .. step.to,
  toggle = "peek=" .. key,
  expanded = open,
  blockId = key,
  done = reviewed,
  check = Ui.check(reviewed, "Reviewed", "review-step=" .. key),
 })
 local closingId = if s.closing["block:" .. key] then "block:" .. key else "peek:" .. key
 -- The landing flash alternates two identical animations so landing on the same block replays it.
 local flash = if s.flash == key then " gp-flash" .. (s.flashCount % 2) else ""
 local class = "gp-excerpt" .. flash .. (if State.currentStep(s).key == key then " gp-current" else "")
 if not open then
  return el("div", { class = class .. " gp-excerpt-done", key = key }, { head })
 end
 local show = State.show(s, step.file, key, step)
 local rows, height = M.rows(s, fd, key, show, plan.plain[key] == true, Comments.forBlock(s, step.file, key, true))
 return el("div", { class = class, key = key }, { head, Ui.body(motion, "x:" .. key, s.closing[closingId] == true, height, rows) })
end

return M
