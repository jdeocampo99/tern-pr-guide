--!strict
-- The page: header, description, overview, each change's card beside its code, the supporting
-- files, and the hint bar. Also the node paths the block scrolls to and focuses, which follow these keys.
local Change = require("./change")
local Code = require("./code")
local Comments = require("./comments")
local Description = require("./description")
local Guide = require("../guide")
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
-- How many blocks stagger in when an AI guide arrives; later ones come with the last.
local STAGGERED_BLOCKS = 6

local M = {}

-- Everything that fades colors or borders between states (a card added, a block marked reviewed)
-- does so only under `gp-soft`, which the page drops once a key drives it: keys stay instant.
local function rootClass(s: State.State, extra: string): string
 return "gp-root gp-page" .. extra .. (if s.keyed then "" else " gp-soft")
end

-- Adds `class` to `node`'s classes.
local function addClass(node: Node, class: string)
 local props = (node :: any).p
 props.class = props.class .. " " .. class
end

-- Marks the page's blocks as arriving. A PR that just opened fades in as a whole; a guide the AI
-- just finished writing, the rare moment of a review, has the blocks below the header rise in one
-- after another. The classes stay for the page's life: they only play when their node is drawn.
local function arriving(s: State.State, blocks: { Node })
 if s.arrival == "still" then return end
 if s.arrival == "guide" then
  for n = 2, #blocks do addClass(blocks[n], "gp-arrive gp-ad" .. math.min(n - 1, STAGGERED_BLOCKS)) end
 else
  for _, block in blocks do addClass(block, "gp-arrive-load") end
 end
end

-- Without a guide, or in the file view of a PR that has one: the header, then the file tree pinned
-- beside the code with a scroll of its own,
-- and the description at the top of the code. The code scrolls with the page: Tern's reveal into
-- a nested scroller left the wheel unable to scroll past the revealed block. Keys match the guided
-- page's first change row, so block paths are the same.
local function split(s: State.State, motion: Ui.Motion, plan: State.Plan): Node
 local blocks = { Description.view(s, motion) }
 for _, block in Guide.blocks(s.review.steps) do table.insert(blocks, Code.block(s, motion, plan, block)) end
 local main = {
  Header.view(s, motion),
  el("div", { class = "gp-split-row", key = "ch1" }, {
   el("div", { class = "gp-split-left", key = "tree" }, { Change.view(s, 1) }),
   el("div", { class = "gp-code-col gp-split-right", key = "code" }, blocks),
  }),
 }
 arriving(s, main)
 table.insert(main, Hints.view(s))
 return el("div", {}, { el("div", { class = rootClass(s, " gp-split"), key = "page" }, main) })
end

function M.view(s: State.State, motion: Ui.Motion): Node
 local plan = State.plan(s)
 if not s.review.guide.guided then return split(s, motion, plan) end
 local page = { Header.view(s, motion), Description.view(s, motion) }
 local overview = Overview.view(s, motion)
 if overview then table.insert(page, overview) end
 for n, change in s.review.guide.changes do
  local blocks = {}
  for _, block in Guide.blocks(change.steps) do table.insert(blocks, Code.block(s, motion, plan, block)) end
  table.insert(page, el("div", { class = "gp-guide gp-crow", key = "ch" .. n }, {
   Change.view(s, n),
   el("div", { class = "gp-code-col", key = "code" }, blocks),
  }))
 end
 local supporting = Supporting.view(s, motion, plan)
 if supporting then
  table.insert(page, el("div", { class = "gp-crow", key = "sup" }, { el("div", { class = "gp-code-col", key = "code" }, { supporting }) }))
 end
 arriving(s, page)
 table.insert(page, Hints.view(s))
 return el("div", {}, { el("div", { class = rootClass(s, ""), key = "page" }, page) })
end

-- The code block `blockId`: a step's block in its change row, or a supporting file's.
function M.blockPath(blockId: string): string
 local file = State.supportingPath(blockId)
 if file then return PAGE .. ".sup.code.supporting.body." .. Supporting.fileKey(file) end
 return PAGE .. ".ch" .. (string.match(blockId, "^c(%d+)s") :: string) .. ".code." .. blockId
end

-- The first run of code lines of step `step` in its shared block, which starts at entry `first`.
function M.stepPath(step: Guide.Step, first: number): string
 return M.blockPath(step.block) .. ".body.h" .. first
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

M.summaryFieldPath = PAGE .. ".header.review.cols.side.summary.field"

function M.reviewRowPath(item: Review.Item): string
 return PAGE .. ".header.review.cols.list." .. ReviewPanel.rowKey(item)
end

return M
