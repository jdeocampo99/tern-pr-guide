--!strict
-- The pinned header: PR title and review button, progress and actions, and whichever panel is open.
local Agent = require("../agent")
local Guide = require("../guide")
local Help = require("./help")
local Review = require("../review")
local ModelPanel = require("./model-panel")
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

-- What the generating row says it is doing, one after another while the agent works.
local PHRASES = {
 "Reading the diff", "Following the changes", "Untangling the why", "Sketching the walkthrough",
 "Picking a reading order", "Looking for trouble", "Drafting comments", "Polishing the notes",
}
local PHRASE_SECONDS = 7

-- Steps the bar fill is drawn in; Tern nodes take no inline style, so each step is a class.
local BAR_STEPS = 50
-- Letters past this many write in together with the last one.
local STAGGERED_LETTERS = 30

-- `text` one letter per node, each writing in a little after the one before.
local function writing(text: string): { Node }
 local letters = {}
 for i, code in utf8.codes(text) do
  local letter = if code == 32 then "\u{00A0}" else utf8.char(code)
  table.insert(letters, el("span", { class = "gp-ai-ch gp-ai-cd" .. math.min(#letters + 1, STAGGERED_LETTERS), key = "c" .. i, text = letter }))
 end
 return letters
end

-- The run going: a turning spark, the phrase being written in (keyed by phrase, so only a new
-- one animates across the once-a-second redraw) over the one leaving, an estimated progress bar,
-- and the clock.
local function busyRow(run: Agent.Run): Node
 local clock = string.format("%d:%02d", math.floor(run.seconds / 60), run.seconds % 60)
 local turn = math.floor(run.seconds / PHRASE_SECONDS)
 local n = turn % #PHRASES + 1
 local phrases = { el("span", { class = "gp-ai-phrase", key = "p" .. n }, writing(PHRASES[n])) }
 if turn > 0 and run.seconds % PHRASE_SECONDS == 0 then
  local leaving = (turn - 1) % #PHRASES + 1
  table.insert(phrases, 1, el("span", { class = "gp-ai-phrase gp-ai-phrase-out", key = "o" .. leaving, text = PHRASES[leaving] }))
 end
 local step = math.floor(Agent.progress(run.seconds, run.expected) * BAR_STEPS + 0.5)
 return el("div", { class = "gp-ai gp-ai-busy", key = "ai" }, {
  el("span", { class = "gp-ai-spark", key = "spark", text = "✦" }),
  el("span", { class = "gp-ai-phrases", key = "phrases" }, phrases),
  el("span", { class = "gp-ai-bar", key = "bar" }, {
   el("span", { class = "gp-ai-fill gp-pg" .. step, key = "fill" }),
   el("span", { class = "gp-ai-shine", key = "shine" }),
  }),
  el("span", { class = "gp-ai-meta", key = "meta", text = clock }),
 })
end

-- A row offering the reader's AI agent to write a guide, with the model and effort it will use (a
-- button opening the model dropdown, `box`, beneath it) and why the last run failed, or the run going.
local function aiRow(run: Agent.Run, box: State.ModelBox?): Node
 if run.running then return busyRow(run) end
 local anchor = { el("span", { class = "gp-ai-model" .. (if box then " gp-ai-model-open" else ""), key = "button", actions = { click = "toggle-models" } }, {
  span("gp-ai-model-name", Agent.label(run.agent)),
  span("gp-ai-model-caret", "▾"),
  span("gp-act-key", "⇧M"),
 }) }
 if box then
  table.insert(anchor, el("div", { class = "gp-md-scrim", key = "scrim", actions = { click = "toggle-models" } }))
  table.insert(anchor, ModelPanel.view(box, run.agent))
 end
 local kids = {
  el("span", { class = "gp-btn gp-btn-primary gp-ai-button", actions = { click = "generate-guide" } }, {
   span("gp-ai-button-label", "Generate AI Guided Review"),
   span("gp-act-key", "⇧G"),
  }),
  el("span", { class = "gp-md-anchor", key = "anchor" }, anchor),
 }
 if run.error then table.insert(kids, span("gp-ai-error", "Couldn't generate it: " .. run.error)) end
 return el("div", { class = "gp-ai", key = "ai" }, kids)
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
 if s.ai then table.insert(parts, aiRow(s.ai, s.models)) end
 if s.search then table.insert(parts, SearchPanel.view(s.search, s.review.guide.guided)) end
 if s.helpOpen then table.insert(parts, Help.view(s.closing.help == true, s.review.guide.guided)) end
 if s.reviewOpen then table.insert(parts, ReviewPanel.view(s)) end
 return el("div", { class = "gp-header", key = "header" }, parts)
end

return M
