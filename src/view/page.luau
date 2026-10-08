--!strict
-- The page: header, description, overview, each change's card beside its code, the supporting
-- files, and the hint bar. Also the node paths the block scrolls to and focuses, which follow these keys.
local Change = require("./change")
local Code = require("./code")
local Comments = require("./comments")
local Description = require("./description")
local Header = require("./header")
local Hints = require("./hints")
local Overview = require("./overview")
local Review = require("../review")
local ReviewPanel = require("./review-panel")
local State = require("../state")
local Supporting = require("./supporting")
local Ui = require("./ui")

local el = Ui.el

local PAGE = "main.page"

local M = {}

-- Without a guide: the header, then the file tree and the code side by side, each scrolling on its
-- own, with the description at the top of the code. Keys match the guided page's first change row,
-- so block paths are the same.
local function split(s: State.State, motion: Ui.Motion, plan: State.Plan): Node
 local blocks = { Description.view(s, motion) }
 for _, step in s.review.steps do table.insert(blocks, Code.step(s, motion, plan, step)) end
 return el("div", { class = "gp-fill" }, { el("div", { class = "gp-root gp-page gp-split", key = "page" }, {
  Header.view(s),
  el("div", { class = "gp-split-row", key = "ch1" }, {
   el("div", { class = "gp-split-left", key = "tree" }, { Change.view(s, 1) }),
   el("div", { class = "gp-code-col gp-split-right", key = "code" }, blocks),
  }),
  Hints.view(s),
 }) })
end

function M.view(s: State.State, motion: Ui.Motion): Node
 local plan = State.plan(s)
 if not s.review.guide.guided then return split(s, motion, plan) end
 local page = { Header.view(s), Description.view(s, motion) }
 local overview = Overview.view(s, motion)
 if overview then table.insert(page, overview) end
 for n, change in s.review.guide.changes do
  local blocks = {}
  for _, step in change.steps do table.insert(blocks, Code.step(s, motion, plan, step)) end
  table.insert(page, el("div", { class = "gp-guide gp-crow", key = "ch" .. n }, {
   Change.view(s, n),
   el("div", { class = "gp-code-col", key = "code" }, blocks),
  }))
 end
 local supporting = Supporting.view(s, motion, plan)
 if supporting then
  table.insert(page, el("div", { class = "gp-crow", key = "sup" }, { el("div", { class = "gp-code-col", key = "code" }, { supporting }) }))
 end
 table.insert(page, Hints.view(s))
 return el("div", {}, { el("div", { class = "gp-root gp-page", key = "page" }, page) })
end

-- Where page-up, page-down, home and end scroll: the page, or the code beside the file tree.
function M.scrollPath(s: State.State): string
 return if s.review.guide.guided then "main" else PAGE .. ".ch1.code"
end

-- The code block `blockId`: a step's block in its change row, or a supporting file's.
function M.blockPath(blockId: string): string
 local file = State.supportingPath(blockId)
 if file then return PAGE .. ".sup.code.supporting.body." .. Supporting.fileKey(file) end
 return PAGE .. ".ch" .. (string.match(blockId, "^c(%d+)s") :: string) .. ".code." .. blockId
end

-- The diff line `entry` of a block.
function M.linePath(blockId: string, entry: number): string
 return M.blockPath(blockId) .. ".body.r" .. entry
end

function M.suggestionPath(blockId: string, id: string): string
 return M.blockPath(blockId) .. ".body." .. Comments.suggestionKey(id)
end

function M.composerPath(blockId: string): string
 return M.blockPath(blockId) .. ".body.composer"
end

function M.composerFieldPath(blockId: string): string
 return M.composerPath(blockId) .. ".body.field"
end

M.searchFieldPath = PAGE .. ".header.search.box.field"
M.modelFieldPath = PAGE .. ".header.ai.anchor.models.box.field"

-- Row `n` of the model dropdown's list.
function M.modelRowPath(n: number): string
 return PAGE .. ".header.ai.anchor.models.list.m" .. n
end

M.summaryFieldPath = PAGE .. ".header.review.cols.side.summary.field"

function M.reviewRowPath(item: Review.Item): string
 return PAGE .. ".header.review.cols.list." .. ReviewPanel.rowKey(item)
end

return M
