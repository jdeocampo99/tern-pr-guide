--!strict
-- The model dropdown under the AI row: a filter, the models matching it, and the efforts the
-- highlighted model takes.
local Agent = require("../agent")
local Fields = require("../text-field")
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local M = {}

local function effortRow(box: State.ModelBox, agent: Agent.Agent, model: Agent.Model?): Node
 local kids = { span("gp-md-label", "Effort") }
 if not model then
  table.insert(kids, span("gp-md-none", "No model matches"))
 elseif #model.efforts == 0 then
  table.insert(kids, span("gp-md-none", "This model doesn't take an effort"))
 else
  local current = Agent.effortFor(model, box.effort)
  for _, effort in model.efforts do
   table.insert(kids, el("span", {
    class = "gp-md-effort" .. (if effort == current then " gp-md-effort-on" else ""),
    text = effort,
    actions = { click = "model-effort=" .. effort },
   }))
  end
 end
 return el("div", { class = "gp-md-efforts", key = "efforts" }, kids)
end

function M.view(box: State.ModelBox, agent: Agent.Agent): Node
 local choices = State.modelChoices(box, agent)
 local rows = {}
 for n, model in choices do
  local inUse = model.selector == agent.model
  table.insert(rows, el("div", { class = "gp-md-row" .. (if n == box.selected then " gp-md-row-on" else ""), key = "m" .. n, actions = { click = "model-row=" .. n } }, {
   span("gp-md-check", if inUse then "✓" else ""),
   span("gp-md-name", model.name),
   span("gp-md-sel", model.selector),
  }))
 end
 if #agent.models == 0 then
  table.insert(rows, span("gp-sr-empty", "Listing models…"))
 elseif #rows == 0 then
  table.insert(rows, span("gp-sr-empty", "Nothing matches “" .. box.field.text .. "”."))
 end
 return el("div", { class = "gp-panel gp-search gp-models", key = "models" }, {
  el("div", { class = "gp-sr-box", key = "box" }, { span("gp-sr-slash", "⌕"), Fields.node(box.field, "field", "Search models…") }),
  el("div", { class = "gp-sr-list gp-md-list", key = "list" }, rows),
  effortRow(box, agent, choices[box.selected]),
 })
end

return M
