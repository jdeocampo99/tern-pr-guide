--!strict
-- The page that picks a PR: a filter field over the checkout's open PRs, the current branch's first.
local Fields = require("../text-field")
local Picker = require("../picker")
local Text = require("../text")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local PICKER = "main.page.picker"

local KEYS = { { "↑ ↓", "move" }, { "⏎", "open" }, { "esc", "clear" } }

local M = {}

function M.rowKey(number: number): string
 return "pr" .. number
end

local function row(p: Picker.Picker, item: Picker.Row, on: boolean): Node
 local pr = item.pr
 local title = { span("gp-sr-text", pr.title) }
 if p.guided[pr.number] then table.insert(title, span("gp-pk-tag", "Guide")) end
 if pr.draft then table.insert(title, span("gp-pk-tag", "Draft")) end
 return el("div", { class = "gp-sr-row gp-pk-row" .. (if on then " gp-sr-row-on" else ""), key = M.rowKey(pr.number), actions = { click = "pick-pr=" .. pr.number } }, {
  span("gp-pk-num", "#" .. pr.number),
  el("span", { class = "gp-pk-main" }, {
   el("span", { class = "gp-pk-title" }, title),
   span("gp-sr-sub", pr.author .. "  ·  " .. pr.branch),
  }),
  Ui.spacer(),
  span("gp-adds", "+" .. pr.adds),
  span("gp-dels", "−" .. pr.dels),
  span("gp-pk-stat", pr.files .. (if pr.files == 1 then " file" else " files")),
  span("gp-pk-stat gp-pk-when", Picker.ago(pr.updated, p.loadedAt)),
 })
end

-- Rows under section labels, or what the list has instead of rows.
local function list(p: Picker.Picker, repoName: string): { Node }
 local kids = {}
 local named = Picker.named(p.field.text)
 if named then table.insert(kids, span("gp-sr-empty", "⏎ opens #" .. named)) end
 if p.error then
  table.insert(kids, span("gp-sr-empty gp-notice-error", p.error))
  return kids
 end
 if not p.prs then
  table.insert(kids, span("gp-sr-empty", "Loading open pull requests…"))
  return kids
 end
 local rows = Picker.rows(p)
 if #rows == 0 then
  if #(p.prs :: { Picker.Summary }) == 0 then
   table.insert(kids, span("gp-sr-empty", "No open pull requests in " .. repoName .. "."))
  elseif not named then
   table.insert(kids, span("gp-sr-empty", "No open pull request matches “" .. p.field.text .. "”."))
  end
  return kids
 end
 -- With the current branch's PR on top, labels set it apart from the rest.
 local split = rows[1].thisBranch
 for n, item in rows do
  if split and n <= 2 then table.insert(kids, span("gp-panel-h gp-pk-section", if n == 1 then "This branch" else "Open")) end
  table.insert(kids, row(p, item, n == p.selected))
 end
 return kids
end

function M.view(p: Picker.Picker, root: string): Node
 local repoName = Text.baseName(root)
 local panel = {
  el("div", { class = "gp-sr-box", key = "box" }, { span("gp-sr-slash", "#"), Fields.node(p.field, "field", "Filter, or paste a PR number or link…") }),
 }
 for _, node in list(p, repoName) do table.insert(panel, node) end
 local hints = { span("gp-hb-mode", "Pick a pull request"), Ui.spacer() }
 for _, key in KEYS do
  table.insert(hints, el("span", { class = "gp-hb-item" }, { span("gp-hb-key", key[1]), span("gp-hb-label", key[2]) }))
 end
 return el("div", {}, { el("div", { class = "gp-root gp-page", key = "page" }, {
  el("div", { class = "gp-header", key = "header" }, {
   el("div", { class = "gp-title" }, { span("gp-title-text", "Pull requests"), span("gp-title-num", root) }),
  }),
  el("div", { class = "gp-panel gp-search gp-picker", key = "picker" }, panel),
  el("div", { class = "gp-hintbar", key = "hints" }, hints),
 }) })
end

M.fieldPath = PICKER .. ".box.field"

function M.rowPath(number: number): string
 return PICKER .. "." .. M.rowKey(number)
end

return M
