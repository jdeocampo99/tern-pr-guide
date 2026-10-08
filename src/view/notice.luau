--!strict
-- The page before the review: what loading the PR is doing, or why it failed.
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local M = {}

function M.view(name: string, stage: string, failure: string?): Node
 local pr = if name ~= "" then "PR " .. name else "the PR"
 local card = if failure
  then {
   span("gp-notice-title", "Couldn't open " .. pr),
   span("gp-notice-text gp-notice-error", failure),
  }
  else {
   span("gp-notice-title", "Fetching " .. pr .. "…"),
   span("gp-notice-text", stage),
  }
 return el("div", {}, { el("div", { class = "gp-root gp-page", key = "page" }, {
  el("div", { class = "gp-notice", key = "notice" }, card),
 }) })
end

return M
