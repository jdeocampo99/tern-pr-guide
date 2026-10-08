--!strict
-- The pinned header: PR title and review button, progress and actions, and whichever panel is open.
local Agent = require("../agent")
local Guide = require("../guide")
local Help = require("./help")
local Review = require("../review")
local ReviewPanel = require("./review-panel")
local SearchPanel = require("./search-panel")
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local METER_CELLS = 24

local M = {}

local function reviewButton(s: State.State, included: number): Node
 local posted = s.review.posted
 local label = if not posted then "Submit review" elseif posted.delivery.kind == "saved" then "Dry run saved" else "Review posted"
 return el("span", { class = "gp-rv-button" .. (if s.reviewOpen then " gp-rv-button-open" else ""), actions = { click = "toggle-review" } }, {
  span("gp-rv-button-label", label),
  span("gp-rv-button-count", if posted then "✓" else tostring(included)),
  span("gp-rv-button-key", "r"),
 })
end

local function headerAction(label: string, keyHint: string?, action: string): Node
 local kids = { span("gp-hdr-act-label", label) }
 if keyHint then table.insert(kids, span("gp-act-key", keyHint)) end
 return el("span", { class = "gp-hdr-act", actions = { click = action } }, kids)
end

-- A row offering the reader's AI agent to write a guide, with why the last run failed, or the run
-- going.
local function aiRow(run: Agent.Run): Node
 if run.running then
  local clock = string.format("%d:%02d", math.floor(run.seconds / 60), run.seconds % 60)
  return el("div", { class = "gp-ai" }, { span("gp-ai-running", "Generating AI guided review with " .. run.agent.name .. "… " .. clock) })
 end
 local kids = {
  Ui.button("gp-btn-primary gp-ai-button", "Generate AI Guided Review", "generate-guide"),
  span("gp-ai-model", run.agent.name),
 }
 if run.error then table.insert(kids, span("gp-ai-error", "Couldn't generate it: " .. run.error)) end
 return el("div", { class = "gp-ai" }, kids)
end

local function status(s: State.State, counts: Review.Counts): Node
 local r = s.review
 local total = #r.pr.files
 local cells, filled = {}, math.floor(METER_CELLS * counts.filesReviewed / math.max(total, 1) + 0.5)
 for i = 1, METER_CELLS do table.insert(cells, span(if i <= filled then "gp-cell gp-cell-on" else "gp-cell", "")) end
 local kids = {
  el("div", { class = "gp-meter" }, cells),
  span("gp-status-text", counts.filesReviewed .. " of " .. total .. " files reviewed"),
 }
 if counts.waiting > 0 then
  table.insert(kids, span("gp-status-sep", "·"))
  table.insert(kids, el("span", {
   class = "gp-status-link",
   text = counts.waiting .. " " .. r.guide.author .. " " .. (if counts.waiting == 1 then "suggestion" else "suggestions") .. " waiting for you",
   actions = { click = "toggle-review" },
  }))
 end
 if Guide.isStale(r.guide, r.pr) then
  table.insert(kids, span("gp-status-sep", "·"))
  table.insert(kids, span("gp-status-text", "Guide written for an older version of this PR"))
 end
 table.insert(kids, Ui.spacer())
 table.insert(kids, headerAction(if counts.filesReviewed == total then "Unmark all reviewed" else "Mark all reviewed", "m", "mark-all"))
 table.insert(kids, headerAction("Search", "/", "open-search"))
 table.insert(kids, headerAction("Open on GitHub ↗", "g", "open-github"))
 return el("div", { class = "gp-status" }, kids)
end

function M.view(s: State.State): Node
 local pr = s.review.pr
 local counts = Review.counts(s.review)
 local parts = {
  el("div", { class = "gp-title" }, { span("gp-title-num", "#" .. pr.number), span("gp-title-text", pr.title), Ui.spacer(), reviewButton(s, counts.included) }),
  status(s, counts),
 }
 if s.ai then table.insert(parts, aiRow(s.ai)) end
 if s.search then table.insert(parts, SearchPanel.view(s.search, s.review.guide.guided)) end
 if s.helpOpen then table.insert(parts, Help.view(s.closing.help == true, s.review.guide.guided)) end
 if s.reviewOpen then table.insert(parts, ReviewPanel.view(s)) end
 return el("div", { class = "gp-header", key = "header" }, parts)
end

return M
