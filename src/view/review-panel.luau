--!strict
-- Your review, as GitHub will receive it: the comments it can carry, each ticked in or out, and the
-- summary and verdict that go with them.
local Fields = require("../text-field")
local Review = require("../review")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

-- One comment as the review lists it.
type Row = {
 key: string,
 -- Its place in Review.items, which the tick toggles.
 n: number,
 included: boolean,
 selected: boolean,
 author: string,
 avatarClass: string,
 -- Kind label and its color class, for suggestions.
 kind: { text: string, class: string }?,
 note: string?,
 location: string,
 jump: string,
 body: string,
}

local el, span = Ui.el, Ui.span

local YOU = "You"
local VERDICT_DETAILS: { [Review.VerdictId]: { hint: string, icon: string } } = {
 comment = { hint = "General feedback, no decision", icon = "•" },
 approve = { hint = "Good to merge", icon = "✓" },
 changes = { hint = "Must be fixed before merging", icon = "✕" },
}

local M = {}

local function plural(n: number, word: string): string
 return n .. " " .. word .. (if n == 1 then "" else "s")
end

function M.rowKey(item: Review.Item): string
 return if item.suggestion then "s-" .. item.suggestion.id else "m-" .. (item.own :: number)
end

-- A tick that includes the comment, who wrote it, its kind, a link to its line, and the full text.
-- Unticked comments stay in the list, faded.
local function row(r: Row): Node
 local top = { span("gp-rv-author", r.author) }
 if r.kind then table.insert(top, span("gp-rv-kind gp-rv-kind-" .. r.kind.class, r.kind.text)) end
 if r.note then table.insert(top, span("gp-rv-note-inline", r.note)) end
 table.insert(top, Ui.spacer())
 table.insert(top, el("span", { class = "gp-rv-link", text = r.location, actions = { click = r.jump } }))
 return el("div", { class = "gp-rv-row" .. (if r.included then "" else " gp-rv-row-off") .. (if r.selected then " gp-rv-row-cur" else ""), key = r.key }, {
  el("span", { class = "gp-rv-tick" .. (if r.included then " gp-rv-tick-on" else ""), text = if r.included then "✓" else "", actions = { click = "toggle-item=" .. r.n } }),
  Ui.avatar("gp-avatar-" .. r.avatarClass, r.author),
  el("div", { class = "gp-rv-main" }, { el("div", { class = "gp-rv-top" }, top), el("div", { class = "gp-rv-text" }, { Ui.rich(r.body) }) }),
 })
end

local function itemRow(s: State.State, item: Review.Item, n: number): Node
 local r = s.review
 local key, included, selected = M.rowKey(item), Review.isIncluded(r, item), s.reviewCursor == n
 local comment = item.suggestion
 if comment then
  local kind = Ui.kinds[comment.kind]
  return row({
   key = key, n = n, included = included, selected = selected,
   author = r.guide.author, avatarClass = "guide",
   kind = { text = kind.icon .. kind.word, class = comment.kind },
   note = if r.decisions[comment.id] == nil then "not decided yet" else nil,
   location = "line " .. comment.line, jump = "goto-suggestion=" .. comment.id, body = comment.body,
  })
 end
 local own = r.own[item.own :: number]
 return row({
  key = key, n = n, included = included, selected = selected,
  author = YOU, avatarClass = "you", kind = nil, note = nil,
  location = Text.lineSpan(own.from, own.to), jump = "goto-own=" .. (item.own :: number), body = own.body,
 })
end

local function commentList(s: State.State, included: number): { Node }
 local items = Review.items(s.review)
 local all = #items > 0 and included == #items
 local list = { el("div", { class = "gp-rv-sec" }, {
  el("div", { class = "gp-rv-sec-top" }, {
   span("gp-rv-sec-title", "Comments"),
   span("gp-rv-sec-count", included .. " of " .. #items .. " included"),
   Ui.spacer(),
   if #items > 0 then el("span", { class = "gp-btn gp-btn-sm gp-btn-keyed", actions = { click = "toggle-all" } }, {
    span("gp-btn-label", if all then "Exclude all" else "Include all"), span("gp-act-key", "a"),
   }) else span("", ""),
  }),
  span("gp-rv-sec-explain", "Ticked comments post on their lines. Untick one to leave it out."),
 }) }
 if #items == 0 then
  table.insert(list, span("gp-rv-empty", "No comments yet. Hover a code line and click + to write one."))
 end
 local file = nil
 for n, item in items do
  if item.file ~= file then
   file = item.file
   table.insert(list, el("div", { class = "gp-rv-file", key = "f-" .. Text.keyOf(item.file) }, {
    Ui.fileIcon(item.file), span("gp-rv-file-name", Text.baseName(item.file)), span("gp-rv-file-dir", Text.dirName(item.file)),
   }))
  end
  table.insert(list, itemRow(s, item, n))
 end
 return list
end

local function verdicts(s: State.State): { Node }
 local nodes = {}
 for n, verdict in Review.verdicts do
  local details = VERDICT_DETAILS[verdict.id]
  local on = s.review.verdict == verdict.id
  table.insert(nodes, el("div", { class = "gp-rv-verdict gp-rv-verdict-" .. verdict.id .. (if on then " gp-rv-verdict-on" else ""), key = "v-" .. verdict.id, actions = { click = "verdict=" .. verdict.id } }, {
   span("gp-rv-vicon", details.icon),
   el("span", { class = "gp-rv-vtext" }, { span("gp-rv-vname", verdict.label), span("gp-rv-vhint", details.hint) }),
   Ui.spacer(),
   span("gp-act-key", tostring(n)),
  }))
 end
 return nodes
end

local function verdictLabel(id: Review.VerdictId): string
 for _, verdict in Review.verdicts do
  if verdict.id == id then return verdict.label end
 end
 return id
end

local function postedArea(posted: Review.Posted): { Node }
 local what = verdictLabel(posted.verdict) .. " with " .. plural(#posted.payload.comments, "comment")
 local delivery = posted.delivery
 if delivery.kind == "saved" then
  return { el("div", { class = "gp-rv-done" }, {
   span("gp-rv-done-title", "✓  Dry run: review saved"),
   span("gp-rv-done-text", what .. " saved to " .. delivery.path .. ". Nothing was sent to GitHub."),
  }) }
 end
 return { el("div", { class = "gp-rv-done" }, {
  span("gp-rv-done-title", "✓  Review posted"),
  span("gp-rv-done-text", what .. "."),
  el("span", { class = "gp-rv-done-link", text = "Open it on GitHub ↗", actions = { click = "open-posted" } }),
 }) }
end

local function submitArea(s: State.State, included: number): { Node }
 local r, submit = s.review, s.submit
 if r.posted then return postedArea(r.posted) end
 local verdict = verdictLabel(r.verdict)
 local confirming = submit.confirming and not submit.sending
 local label = if submit.sending then "Sending…"
  elseif confirming then "Post " .. verdict .. " with " .. plural(included, "comment") .. "? Press ⌘⏎ again"
  elseif submit.dryRunPath then "Save (dry run)  ·  " .. verdict
  else "Submit review  ·  " .. verdict
 local button = { span("gp-rv-submit-label", label) }
 if not confirming then table.insert(button, span("gp-rv-submit-key", "⌘ ⏎")) end
 local nodes = {
  el("span", { class = "gp-rv-submit" .. (if confirming then " gp-rv-submit-confirm" else ""), actions = { click = "submit-review" } }, button),
  span("gp-rv-note", if submit.dryRunPath
   then "Dry run: saves " .. plural(included, "comment") .. " and the summary to " .. submit.dryRunPath .. "; nothing is sent."
   elseif confirming then "Not posted yet. ⌘⏎ or a click posts to PR #" .. r.pr.number .. "; anything else, or esc, cancels."
   else "Asks you to confirm, then posts " .. plural(included, "comment") .. " and the summary to PR #" .. r.pr.number .. " at once."),
 }
 if submit.error then table.insert(nodes, span("gp-rv-error", "Not sent: " .. submit.error)) end
 return nodes
end

local function side(s: State.State, included: number): { Node }
 local guide = s.review.guide
 local editing = s.editingSummary
 local nodes = {
  el("div", { class = "gp-rv-sec-top" }, {
   span("gp-rv-sec-title", "Summary"),
   Ui.spacer(),
   el("span", { class = "gp-rv-link", text = if editing then "Done  ⏎" else "Edit  e", actions = { click = if editing then "done-summary" else "edit-summary" } }),
  }),
  span("gp-rv-sec-explain", "The opening comment of your review." .. (if guide.summary ~= "" then " Drafted by " .. guide.author .. "." else "")),
  el("div", { class = "gp-rv-summary" .. (if editing then " gp-rv-summary-on" else ""), key = "summary", actions = { click = "edit-summary" } }, {
   Fields.node(s.review.summary, "field", "Say what you think overall…"),
  }),
  el("div", { class = "gp-rv-sec-top gp-rv-gap" }, { span("gp-rv-sec-title", "Verdict") }),
  el("div", { class = "gp-rv-verdicts" }, verdicts(s)),
 }
 for _, node in submitArea(s, included) do table.insert(nodes, node) end
 return nodes
end

function M.view(s: State.State): Node
 local included = Review.counts(s.review).included
 local number = s.review.pr.number
 return el("div", { class = "gp-panel gp-rv" .. (if s.closing.review then " gp-closing-panel" else ""), key = "review" }, {
  el("div", { class = "gp-rv-head" }, {
   el("div", { class = "gp-rv-head-text" }, {
    span("gp-rv-title", "Finish your review"),
    span("gp-rv-sub", if s.submit.dryRunPath
     then "Dry run: submitting saves the review to a file. Nothing is sent to GitHub."
     else "Posts one review to PR #" .. number .. ", after you confirm."),
   }),
   Ui.spacer(),
   el("span", { class = "gp-rv-link", text = "Close  esc", actions = { click = "toggle-review" } }),
  }),
  el("div", { class = "gp-rv-cols", key = "cols" }, {
   el("div", { class = "gp-rv-list", key = "list" }, commentList(s, included)),
   el("div", { class = "gp-rv-side", key = "side" }, side(s, included)),
  }),
 })
end

return M
