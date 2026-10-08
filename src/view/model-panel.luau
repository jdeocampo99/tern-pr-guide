--!strict
-- The model dropdown, a popover under the model button: a filter, the models matching it grouped by
-- provider, the efforts the highlighted model takes as one segmented control, and the review lens.
local Agent = require("../agent")
local Fields = require("../text-field")
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local M = {}

local function provider(model: Agent.Model): string
 return string.match(model.selector, "^([^/]+)/") or ""
end

-- The effort control for `model`; nil when nothing matches the filter, which the list already says.
local function efforts(box: State.ModelBox, model: Agent.Model?): Node?
 if not model then return nil end
 if #model.efforts == 0 then
  return el("div", { class = "gp-md-foot", key = "efforts" }, { span("gp-md-none", "This model has no effort setting") })
 end
 local current = Agent.effortFor(model, box.effort)
 local segments = {}
 for _, effort in model.efforts do
  table.insert(segments, el("span", {
   class = "gp-md-seg" .. (if effort == current then " gp-md-seg-on" else ""),
   text = effort,
   actions = { click = "model-effort=" .. effort },
  }))
 end
 return el("div", { class = "gp-md-foot", key = "efforts" }, {
  span("gp-md-label", "Effort"),
  el("div", { class = "gp-md-segs" }, segments),
  Ui.spacer(),
  span("gp-act-key", "← →"),
 })
end

-- The review lens control: every lens as a segment, the chosen one's description under them, and
-- the way to the folder of the reader's own lenses.
local function lenses(agent: Agent.Agent): Node
 local current = Agent.currentLens(agent)
 local segments = {}
 for n, lens in agent.lenses do
  table.insert(segments, el("span", {
   class = "gp-md-seg" .. (if lens.name == current.name then " gp-md-seg-on" else ""),
   key = "l" .. n,
   text = lens.name,
   actions = { click = "model-lens=" .. n },
  }))
 end
 return el("div", { class = "gp-md-foot gp-md-lens", key = "lenses" }, {
  el("div", { class = "gp-md-lens-row", key = "pick" }, {
   span("gp-md-label", "Lens"),
   el("div", { class = "gp-md-segs gp-md-segs-wrap", key = "segs" }, segments),
   span("gp-act-key", "⇧← →"),
  }),
  el("div", { class = "gp-md-lens-row", key = "about" }, {
   span("gp-md-lens-desc", current.description),
   el("span", { class = "gp-md-edit", key = "edit", actions = { click = "edit-lenses" } }, {
    span("gp-md-edit-label", "Edit lenses…"),
    span("gp-act-key", "⌃E"),
   }),
  }),
 })
end

-- The list starts at match `box.top`, under a row offering the ones above it. Its key changes with
-- `top`, so the list draws as a fresh scroller at its own start and the wheel scrolls it freely.
function M.view(box: State.ModelBox, agent: Agent.Agent): Node
 local choices = State.modelChoices(box, agent)
 local rows, group = {}, nil
 if box.top > 1 then
  local above = box.top - 1
  table.insert(rows, el("div", { class = "gp-md-more", key = "above", text = "↑  " .. above .. " more", actions = { click = "models-top" } }))
 end
 for n = box.top, #choices do
  local model = choices[n]
  local name = provider(model)
  if name ~= group then
   group = name
   table.insert(rows, el("div", { class = "gp-md-group", key = "g-" .. name, text = name }))
  end
  table.insert(rows, el("div", { class = "gp-md-row" .. (if n == box.selected then " gp-md-row-on" else ""), key = "m" .. n, actions = { click = "model-row=" .. n } }, {
   span("gp-md-name", model.name),
   Ui.spacer(),
   span("gp-md-check", if model.selector == agent.model then "✓" else ""),
  }))
 end
 if #agent.models == 0 then
  table.insert(rows, span("gp-md-empty", "Listing models…"))
 elseif #rows == 0 then
  table.insert(rows, span("gp-md-empty", "Nothing matches “" .. box.field.text .. "”"))
 end
 local kids = {
  el("div", { class = "gp-md-search", key = "box" }, { span("gp-md-glass", "⌕"), Fields.node(box.field, "field", "Search models") }),
  el("div", { class = "gp-md-list", key = "list" .. box.top }, rows),
 }
 local foot = efforts(box, choices[box.selected])
 if foot then table.insert(kids, foot) end
 table.insert(kids, lenses(agent))
 return el("div", { class = "gp-md-pop", key = "models" }, kids)
end

return M
