--!strict
-- The left column beside one change: its place and reviewed tick, why, its files, then its steps.
-- Every change's row carries its own card pinned with position: sticky, so scrolling into the next
-- row swaps in the next card: Tern gives plugins no scroll events to drive one shared copy.
local Guide = require("../guide")
local Review = require("../review")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local M = {}

local function fileList(r: Review.Review, change: number): { Node }
 local list = {}
 for _, file in Review.filesOfChange(r, change) do
  table.insert(list, el("div", { class = "gp-cfile", key = "cf-" .. Text.keyOf(file.path), actions = { click = "goto-step=" .. Review.firstStep(r, change, file.path) } }, {
   Ui.fileIcon(file.path),
   span("gp-cfile-name", Text.baseName(file.path)),
   span("gp-cfile-dir", Text.dirName(file.path)),
   Ui.spacer(),
   span("gp-adds", if file.adds > 0 then "+" .. file.adds else ""),
   span("gp-dels", if file.dels > 0 then "−" .. file.dels else ""),
  }))
 end
 return list
end

-- The step you are on sits in a tinted box with its note, matching the outlined code block.
local function stepList(r: Review.Review, change: Guide.Change, current: Guide.Step): { Node }
 local steps = {}
 for _, step in change.steps do
  local key = step.key
  local here = step == current
  local row = el("div", { class = "gp-ol-step" .. (if here then " gp-ol-here" else ""), key = "os" .. key }, {
   el("span", { class = "gp-ol-dot", text = if r.reviewed[key] then "✓" else "○", actions = { click = "review-step=" .. key } }),
   el("span", { class = "gp-ol-steptitle", text = step.title, actions = { click = "goto-step=" .. step.position } }),
  })
  if here then
   table.insert(steps, el("div", { class = "gp-ol-herebox", key = "hb" .. key }, {
    row,
    el("div", { class = "gp-ol-stepbody", key = "ob" .. key }, { Ui.rich(step.note) }),
   }))
  else
   table.insert(steps, row)
  end
 end
 return steps
end

function M.view(s: State.State, n: number): Node
 local r = s.review
 local change = r.guide.changes[n]
 local keys = Review.keysOfChange(r, n)
 local done = Review.reviewedCount(r, keys)
 local all = done == #keys
 local meta = { Ui.check(all, "Reviewed", "mark-change=" .. n) }
 if not all and #keys > 1 then table.insert(meta, span("gp-band-steps", done .. " of " .. #keys .. " steps done")) end
 table.insert(meta, span("gp-act-key", "⇧ ⏎"))
 return el("div", { class = "gp-outline gp-sticky gp-ccard", key = "outline" }, {
  span("gp-band-label", "Change " .. n .. " of " .. #r.guide.changes),
  span("gp-band-title", change.title),
  el("div", { class = "gp-band-meta" }, meta),
  el("div", { class = "gp-band-why" }, { Ui.rich(change.why) }),
  el("div", { class = "gp-cfiles" }, fileList(r, n)),
  span("gp-ccard-h", "Steps"),
  el("div", { class = "gp-ccard-steps" }, stepList(r, change, State.currentStep(s))),
 })
end

return M
