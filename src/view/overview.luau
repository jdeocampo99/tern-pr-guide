--!strict
-- The PR in plain words, then how one run flows through the code with the changed parts marked.
local Guide = require("../guide")
local Review = require("../review")
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local SIGNS: { [Guide.Tone]: string } = { added = "+", removed = "−", changed = "~" }
-- Estimated height of the open diagram, for its unroll animation.
local FLOW_H = 220

local M = {}

local function box(r: Review.Review, item: Guide.Box): Node
 local main = {}
 if item.kind then table.insert(main, span("gp-fn-sign", SIGNS[item.kind])) end
 table.insert(main, span("gp-fn-text", item.text))
 if item.change then table.insert(main, span("gp-fn-num", string.format("%02d", item.change))) end
 local kids = { el("div", { class = "gp-fn-main" }, main) }
 if item.note then table.insert(kids, span("gp-fn-note", item.note)) end
 local action = if item.change then { click = "goto-step=" .. Review.firstStep(r, item.change) } else nil
 return el("div", { class = "gp-fn gp-fn-" .. (item.kind or "same"), actions = action }, kids)
end

local function edge(label: string): Node
 return el("div", { class = "gp-fe" }, { span("gp-fe-label", label), span("gp-fe-arrow", "────›") })
end

local function flowRow(r: Review.Review, row: { Guide.FlowItem }, n: number): Node
 local items = {}
 for _, item in row do
  if item.type == "fork" then
   local arms = {}
   for _, arm in item.arms do
    table.insert(arms, el("div", { class = "gp-flow-arm" }, { edge(arm.label), box(r, { type = "box", text = arm.text }) }))
   end
   table.insert(items, el("div", { class = "gp-flow-branch" }, arms))
  elseif item.type == "edge" then
   table.insert(items, edge(item.label))
  else
   table.insert(items, box(r, item))
  end
 end
 return el("div", { class = "gp-flow-row" .. (if n > 1 then " gp-flow-cont" else ""), key = "r" .. n }, items)
end

local function flow(s: State.State, motion: Ui.Motion, diagram: Guide.Flow): Node
 local kids = { el("div", { class = "gp-flow-head", key = "head", actions = { click = "toggle-flow" } }, {
  Ui.caret(s.flowOpen),
  span("gp-flow-title", diagram.title),
  Ui.spacer(),
  span("gp-flow-legend", "+ added   ~ changed   − removed"),
 }) }
 if s.flowOpen or s.closing.flow then
  local rows = { span("gp-flow-sub", diagram.subtitle) }
  for n, row in diagram.rows do table.insert(rows, flowRow(s.review, row, n)) end
  table.insert(kids, Ui.body(motion, "flow", s.closing.flow == true, FLOW_H, rows))
 end
 return el("div", { class = "gp-flow", key = "flow" }, kids)
end

-- Nil when the guide has neither a TL;DR nor a diagram.
function M.view(s: State.State, motion: Ui.Motion): Node?
 local guide = s.review.guide
 if guide.overview == "" and not guide.flow then return nil end
 local kids = {}
 if guide.overview ~= "" then
  table.insert(kids, el("div", { class = "gp-ov-text" }, {
   span("gp-ov-h", "Overview"),
   el("div", { class = "gp-ov-summary" }, { Ui.rich(guide.overview) }),
  }))
 end
 if guide.flow then table.insert(kids, flow(s, motion, guide.flow)) end
 return el("div", { class = "gp-overview", key = "overview" }, kids)
end

return M
