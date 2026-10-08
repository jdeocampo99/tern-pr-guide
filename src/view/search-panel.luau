--!strict
-- The "/" search box and its results, under the header so it works from anywhere on the page.
local Fields = require("../text-field")
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local M = {}

function M.view(box: State.SearchBox, guided: boolean): Node
 local query = box.field.text
 local rows = {}
 for n, result in box.results do
  table.insert(rows, el("div", { class = "gp-sr-row" .. (if n == box.selected then " gp-sr-row-on" else ""), key = "r" .. n, actions = { click = "search-go=" .. n } }, {
   span("gp-sr-kind", result.kind),
   el("span", { class = "gp-sr-main" }, { span("gp-sr-text", result.text), span("gp-sr-sub", result.sub) }),
  }))
 end
 if #rows == 0 then
  local empty = if guided then "Search steps, files, comments and changed code." else "Search files, comments and changed code."
  table.insert(rows, span("gp-sr-empty", if query == "" then empty else "Nothing matches “" .. query .. "”."))
 end
 return el("div", { class = "gp-panel gp-search", key = "search" }, {
  el("div", { class = "gp-sr-box", key = "box" }, { span("gp-sr-slash", "/"), Fields.node(box.field, "field", "Search this PR…") }),
  el("div", { class = "gp-sr-list" }, rows),
 })
end

return M
