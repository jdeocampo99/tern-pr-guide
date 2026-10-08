--!strict
-- The changed files no step visits, grouped, each foldable with its own reviewed tick.
local Code = require("./code")
local Comments = require("./comments")
local Guide = require("../guide")
local Pr = require("../pr")
local Review = require("../review")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

-- Estimated heights (px) for the unroll animation: a group heading, a file header with its margin.
local GROUP_H, FILE_HEAD_H = 28, 45

local M = {}

function M.fileKey(path: string): string
 return "f-" .. Text.keyOf(path)
end

local function heading(s: State.State, files: { Pr.File }): Node
 local viewed, allOpen = 0, #files > 0
 for _, file in files do
  if s.review.filesViewed[file.path] then viewed += 1 end
  if not (s.supportingOpen and s.fileOpen[file.path]) then allOpen = false end
 end
 local allViewed = viewed == #files
 return el("div", { class = "gp-sup-row", key = "head" }, {
  el("div", { class = "gp-sup-head", actions = { click = "toggle-group" } }, {
   span("gp-caret", if s.supportingOpen then "▾" else "▸"),
   span("gp-sup-title", "Supporting changes"),
   span("gp-sup-sub", #files .. " files that follow from the changes above · " .. viewed .. " reviewed"),
  }),
  Ui.spacer(),
  Ui.actionLink(if allOpen then "Close all" else "Open all", "o", "open-all-supporting", false),
  Ui.actionLink(if allViewed then "✓  All " .. #files .. " reviewed" else "Mark all " .. #files .. " reviewed", "⇧ S", "mark-supporting", allViewed),
 })
end

local function fileBlock(s: State.State, motion: Ui.Motion, plan: State.Plan, file: Pr.File): (Node, number)
 local path = file.path
 local blockId = State.supportingBlock(path)
 local open = plan.open[blockId] == true
 local viewed = s.review.filesViewed[path] == true
 local children = { Code.head(s, file, {
  toggle = "toggle-file=" .. path,
  expanded = open,
  blockId = blockId,
  done = viewed,
  check = Ui.check(viewed, "Reviewed", "mark-file=" .. path),
 }) }
 local height = FILE_HEAD_H
 if open then
  local fd = s.diffs[path]
  local show = State.show(s, path, blockId, nil)
  local rows, rowsHeight = Code.rows(s, fd, blockId, show, plan.plain[blockId] == true, Comments.forBlock(s, path, blockId, false))
  table.insert(children, Ui.body(motion, "file:" .. path, s.closing["file:" .. path] == true, rowsHeight, rows))
  height += rowsHeight
 end
 return el("div", { class = "gp-sfile", key = M.fileKey(path) }, children), height
end

local function groups(s: State.State, motion: Ui.Motion, plan: State.Plan, files: { Pr.File }): ({ Node }, number)
 local nodes, height = {}, 0
 for _, group in Guide.supportingGroups(s.review.guide, files) do
  table.insert(nodes, el("div", { class = "gp-subhead", key = "g-" .. Text.keyOf(group.name), text = group.name }))
  height += GROUP_H
  for _, file in group.files do
   local node, fileHeight = fileBlock(s, motion, plan, file)
   table.insert(nodes, node)
   height += fileHeight
  end
 end
 if plan.supportingFolded > 0 then
  local n = plan.supportingFolded
  table.insert(nodes, el("div", { class = "gp-sup-folded", key = "folded", text = n .. " more " .. (if n == 1 then "file" else "files") .. " folded to keep the page fast · open one from its header" }))
  height += GROUP_H
 end
 return nodes, height
end

-- Nil when every changed file is visited by a step.
function M.view(s: State.State, motion: Ui.Motion, plan: State.Plan): Node?
 local files = Review.supportingFiles(s.review)
 if #files == 0 then return nil end
 local nodes = { heading(s, files) }
 if s.supportingOpen then
  local inner, height = groups(s, motion, plan, files)
  table.insert(nodes, Ui.body(motion, "group", s.closing.group == true, height, inner))
 end
 return el("div", { class = "gp-supporting", key = "supporting" }, nodes)
end

return M
