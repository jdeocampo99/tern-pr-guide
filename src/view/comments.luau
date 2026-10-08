--!strict
-- Comment cards hung under code lines: suggested comments, the reader's own, and the composer.
local Fields = require("../text-field")
local Guide = require("../guide")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

-- The cards under each new-side line of a code block and their estimated height (px).
export type Cards = { [number]: { nodes: { Node }, height: number } }

local el, span = Ui.el, Ui.span

local YOU = "You"
-- Card heights measured in Tern; they size the unroll animation, so errors only cost a little easing.
local CARD_GAP = 18
local LINE_H = 18
local CHARS_PER_LINE = 120
local COMPOSER_H = 150

local M = {}

local function head(avatarClass: string, name: string, who: string, action: string, where: string): Node
 return el("div", { class = "gp-card-head" }, {
  Ui.avatar(avatarClass, name),
  el("span", { class = "gp-card-line" }, { span("gp-card-who", who), span("gp-card-action", action) }),
  span("gp-card-where", where),
 })
end

local function suggestionFoot(id: string, decision: string?): { Node }
 if decision == nil then
  return {
   Ui.button("gp-btn-primary", "Add to review", "decide=" .. id .. "|added"),
   Ui.button("", "Dismiss", "decide=" .. id .. "|dismissed"),
   Ui.spacer(),
   span("gp-card-keys", "a add  ·  d dismiss"),
  }
 end
 return {
  span("gp-card-state gp-card-state-" .. decision, if decision == "added" then "✓  Will be posted with your review" else "Dismissed  ·  won't be posted"),
  Ui.spacer(),
  Ui.button("gp-btn-ghost", if decision == "added" then "Remove" else "Undo", "decide=" .. id .. "|undo"),
 }
end

local function suggestion(s: State.State, comment: Guide.Comment): (Node, number)
 local author = s.review.guide.author
 local decision = s.review.decisions[comment.id]
 local kind = Ui.kinds[comment.kind]
 local children = { head("gp-avatar-guide", author, kind.icon .. author, kind.verb, "line " .. comment.line) }
 if decision ~= "dismissed" then table.insert(children, el("div", { class = "gp-card-body" }, { Ui.rich(comment.body) })) end
 table.insert(children, el("div", { class = "gp-card-foot" }, suggestionFoot(comment.id, decision)))
 local class = "gp-card gp-card-" .. (decision or "open")
  .. (if comment.kind == "problem" then " gp-card-problem" else "")
  .. (if s.review.focus == comment.id then " gp-card-focus" else "")
 local height = if decision == "dismissed" then 78 + CARD_GAP else 98 + LINE_H * Text.wrappedLines(comment.body, CHARS_PER_LINE) + CARD_GAP
 return el("div", { class = class, key = M.suggestionKey(comment.id) }, children), height
end

local function own(n: number, from: number, to: number, body: string): (Node, number)
 local node = el("div", { class = "gp-card gp-card-you", key = "you" .. n }, {
  head("gp-avatar-you", YOU, YOU, "commented", Text.lineSpan(from, to) .. "  ·  will be posted with your review"),
  el("div", { class = "gp-card-body" }, { Ui.rich(body) }),
 })
 return node, 63 + LINE_H * Text.wrappedLines(body, CHARS_PER_LINE) + CARD_GAP
end

local function composer(c: State.Composer): Node
 return el("div", { class = "gp-card gp-card-composer", key = "composer" }, {
  head("gp-avatar-you", YOU, YOU, "are commenting", Text.lineSpan(c.from, c.to) .. (if c.from == c.to then "  ·  click another + to cover a range" else "")),
  el("div", { class = "gp-card-body", key = "body" }, { Fields.node(c.field, "field", "Leave a comment…") }),
  el("div", { class = "gp-card-foot" }, {
   span("gp-card-keys", "⏎ comment  ·  ⇧⏎ new line  ·  esc cancel"),
   Ui.spacer(),
   Ui.button("gp-btn-ghost", "Cancel", "comment-cancel"),
   Ui.button("gp-btn-primary", "Comment", "comment-save"),
  }),
 })
end

local function hang(cards: Cards, line: number, node: Node, height: number)
 local slot = cards[line]
 if not slot then
  slot = { nodes = {}, height = 0 }
  cards[line] = slot
 end
 table.insert(slot.nodes, node)
 slot.height += height
end

function M.suggestionKey(id: string): string
 return "suggestion-" .. id
end

-- The cards of a code block on `file`: suggested comments when `withSuggestions`, the reader's
-- comments under the last line they cover, and the composer when it belongs to block `blockId`.
function M.forBlock(s: State.State, file: string, blockId: string, withSuggestions: boolean): Cards
 local cards: Cards = {}
 if withSuggestions then
  for _, comment in s.review.guide.comments do
   if comment.file == file then hang(cards, comment.line, suggestion(s, comment)) end
  end
 end
 for n, c in s.review.own do
  if c.file == file then hang(cards, c.to, own(n, c.from, c.to, c.body)) end
 end
 local c = s.composer
 if c and c.file == file and (c.step or State.supportingBlock(file)) == blockId then
  hang(cards, c.to, composer(c), COMPOSER_H)
 end
 return cards
end

return M
