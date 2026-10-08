--!strict
-- Every shortcut, grouped in the order a review goes: read, react, finish.
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

type Group = { title: string, keys: { { string } } }

local GUIDED: { Group } = {
 { title = "1  Read", keys = { { "j  k", "next / previous step" }, { "n  p", "next / previous suggestion" }, { "/", "search the PR" }, { "i", "PR description" }, { "s", "supporting changes" }, { "o", "open every supporting file" }, { "g", "open on GitHub" } } },
 { title = "2  React", keys = { { "⏎", "step reviewed, move on" }, { "⇧ ⏎", "whole change reviewed" }, { "v", "whole file reviewed" }, { "m", "mark / unmark all reviewed" }, { "a  d", "add / dismiss suggestion" }, { "c", "comment on this step" } } },
 { title = "3  Finish", keys = { { "r", "open your review" }, { "j  k", "move between comments" }, { "x", "include or leave out" }, { "a", "include / exclude all" }, { "1 2 3", "comment, approve, request changes" }, { "⌘ ⏎", "submit" } } },
}

-- Without a guide every step is a whole file and there is one change: the whole PR.
local FILES: { Group } = {
 { title = "1  Read", keys = { { "j  k", "next / previous file" }, { "/", "search the PR" }, { "i", "PR description" }, { "g", "open on GitHub" }, { "⇧ G", "generate AI guided review" }, { "⇧ M", "AI model, effort and lens" } } },
 { title = "2  React", keys = { { "⏎", "file reviewed, move on" }, { "m", "mark / unmark all reviewed" }, { "c", "comment on this file" } } },
 GUIDED[3],
}

local M = {}

function M.view(closing: boolean, guided: boolean): Node
 local cols = {}
 for _, group in if guided then GUIDED else FILES do
  local rows = { span("gp-panel-h", group.title) }
  for _, key in group.keys do
   table.insert(rows, el("div", { class = "gp-keyrow" }, { span("gp-kbd", key[1]), span("gp-keylabel", key[2]) }))
  end
  table.insert(cols, el("div", { class = "gp-keycol" }, rows))
 end
 table.insert(cols, el("div", { class = "gp-keycol gp-keynote" }, {
  span("gp-panel-h", "Mouse"),
  span("gp-keylabel", "Hover a line and click + to comment. Click a second + to cover a range. Click a file name to fold it."),
 }))
 return el("div", { class = "gp-panel gp-keys" .. (if closing then " gp-closing-panel" else ""), key = "keys" }, cols)
end

return M
