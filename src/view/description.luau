--!strict
-- The PR description as its author wrote it: a heading with who wrote it, unrolling into the
-- rendered Markdown.
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

-- Rendered height per source line, for the unroll animation.
local LINE_H = 22

local M = {}

function M.view(s: State.State, motion: Ui.Motion): Node
 local pr = s.review.pr
 local body = string.match(pr.body, "^%s*(.-)%s*$") :: string
 if body == "" then
  return el("div", { class = "gp-desc", key = "description" }, {
   el("div", { class = "gp-desc-head" }, { span("gp-caret", " "), span("gp-desc-title", "Description"), span("gp-desc-by", "No description provided.") }),
  })
 end
 local open = s.descriptionOpen
 local kids = { el("div", { class = "gp-desc-head", key = "head", actions = { click = "toggle-description" } }, {
  span("gp-caret", if open then "▾" else "▸"),
  span("gp-desc-title", "Description"),
  span("gp-desc-by", if pr.author ~= "" then "by " .. pr.author else ""),
  Ui.spacer(),
  span("gp-act-key", "i"),
 }) }
 if open or s.closing.description then
  local _, lines = string.gsub(body, "\n", "")
  table.insert(kids, Ui.body(motion, "description", s.closing.description == true, (lines + 1) * LINE_H, {
   el("div", { class = "gp-desc-md" }, { tern.ui.md(body) }),
  }))
 end
 return el("div", { class = "gp-desc", key = "description" }, kids)
end

return M
