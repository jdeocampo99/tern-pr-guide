--!strict
-- The page that picks a PR: a filter field over the checkout's open PRs, the current branch's first,
-- or, away from a GitHub checkout, over the reader's open PRs across GitHub.
local Fields = require("../text-field")
local Picker = require("../picker")
local Text = require("../text")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local PICKER = "main.page.picker"

local KEYS = { { "↑ ↓", "move" }, { "⏎", "open" }, { "esc", "clear" } }

local M = {}

local function rowKey(pr: Picker.Summary): string
 return pr.key
end

local function row(p: Picker.Picker, item: Picker.Row, on: boolean): Node
 local pr = item.pr
 local title = { span("gp-sr-text", pr.title) }
 local inCheckout = pr.repo == nil or Picker.sameRepo(pr.repo, p.slug)
 if inCheckout and p.guided[pr.number] then table.insert(title, span("gp-pk-tag", "Guide")) end
 if pr.draft then table.insert(title, span("gp-pk-tag", "Draft")) end
 local sub = if pr.repo then pr.repo .. " #" .. pr.number .. "  ·  " .. pr.author else pr.author .. "  ·  " .. pr.branch
 local cells = {}
 if not pr.repo then table.insert(cells, span("gp-pk-num", "#" .. pr.number)) end
 table.insert(cells, el("span", { class = "gp-pk-main" }, {
  el("span", { class = "gp-pk-title" }, title),
  span("gp-sr-sub", sub),
 }))
 table.insert(cells, Ui.spacer())
 if pr.adds and pr.dels and pr.files then
  table.insert(cells, span("gp-adds", "+" .. pr.adds))
  table.insert(cells, span("gp-dels", "−" .. pr.dels))
  table.insert(cells, span("gp-pk-stat", pr.files .. (if pr.files == 1 then " file" else " files")))
 end
 table.insert(cells, span("gp-pk-stat gp-pk-when", Picker.ago(pr.updated, p.loadedAt)))
 return el("div", { class = "gp-sr-row gp-pk-row" .. (if on then " gp-sr-row-on" else ""), key = rowKey(pr), actions = { click = "pick-pr=" .. Picker.reference(pr) } }, cells)
end

-- What the field's text names, when it names a PR.
local function named(p: Picker.Picker): string?
 local n = Picker.named(p.field.text)
 if not n then return nil end
 if not p.anywhere or Picker.linkRepo(p.field.text) then return "⏎ opens #" .. n end
 return "A number alone doesn't say which repository: paste the PR's link to open #" .. n .. "."
end

-- Rows that stand where the list will be while it loads, each a title and a line under it.
local SKELETON_ROWS = { "a", "b", "c", "b" }

local function skeleton(): Node
 local rows = {}
 for n, width in SKELETON_ROWS do
  table.insert(rows, el("div", { class = "gp-sk-row", key = "k" .. n }, {
   el("span", { class = "gp-sk-main" }, { span("gp-sk gp-sk-title gp-sk-" .. width, ""), span("gp-sk gp-sk-sub", "") }),
   Ui.spacer(),
   span("gp-sk gp-sk-when", ""),
  }))
 end
 return el("div", { class = "gp-sk-list", key = "skeleton" }, rows)
end

-- The section a row sits under: its own label (recently opened, or why GitHub lists it), else
-- "This branch" or "Open" in a checkout's list once anything above the rest needs setting apart.
local function groupOf(item: Picker.Row, labelled: boolean): string?
 if item.pr.group then return item.pr.group end
 if item.thisBranch then return "This branch" end
 return if labelled then "Open" else nil
end

-- Rows under section labels, or what the list has instead of rows; true beside them while the
-- list is still loading. Recently opened PRs show at once, before the list arrives.
local function list(p: Picker.Picker, repoName: string): ({ Node }, boolean)
 local kids = {}
 local hint = named(p)
 if hint then table.insert(kids, span("gp-sr-empty", hint)) end
 local rows = Picker.rows(p)
 local labelled = #rows > 0 and (rows[1].thisBranch or rows[1].pr.group ~= nil)
 local label: string? = nil
 for n, item in rows do
  local group = groupOf(item, labelled)
  if group and group ~= label then
   table.insert(kids, span("gp-panel-h gp-pk-section", group))
   label = group
  end
  table.insert(kids, row(p, item, n == p.selected))
 end
 if p.error then
  table.insert(kids, span("gp-sr-empty gp-notice-error", p.error))
  return kids, false
 end
 if not p.prs then
  table.insert(kids, span("gp-sr-empty", "Loading open pull requests…"))
  table.insert(kids, skeleton())
  return kids, true
 end
 if #rows == 0 then
  if #(p.prs :: { Picker.Summary }) == 0 and #p.recent == 0 then
   table.insert(kids, span("gp-sr-empty", if p.anywhere then "None of your open pull requests are waiting on a review or yours. Paste a PR link to open one." else "No open pull requests in " .. repoName .. "."))
  elseif not hint then
   table.insert(kids, span("gp-sr-empty", "No pull request matches “" .. p.field.text .. "”."))
  end
 end
 return kids, false
end

function M.view(p: Picker.Picker, root: string?): Node
 local repoName = if root then Text.baseName(root) else ""
 local placeholder = if p.anywhere then "Filter, or paste a PR link…" else "Filter, or paste a PR number or link…"
 local body, loading = list(p, repoName)
 -- Its key changes when the list arrives, so the list fades in once; typing in the filter only
 -- changes the rows inside it.
 local panel = {
  el("div", { class = "gp-sr-box", key = "box" }, { span("gp-sr-slash", "#"), Fields.node(p.field, "field", placeholder) }),
  el("div", { class = "gp-pk-body" .. (if loading then "" else " gp-pk-arrive"), key = if loading then "wait" else "list" }, body),
 }
 local hints = { span("gp-hb-mode", "Pick a pull request"), Ui.spacer() }
 for _, key in KEYS do
  table.insert(hints, el("span", { class = "gp-hb-item" }, { span("gp-hb-key", key[1]), span("gp-hb-label", key[2]) }))
 end
 return el("div", {}, { el("div", { class = "gp-root gp-page", key = "page" }, {
  el("div", { class = "gp-header", key = "header" }, {
   el("div", { class = "gp-title" }, { span("gp-title-text", "Pull requests"), span("gp-title-num", if p.anywhere then "on GitHub" else (root or "")) }),
  }),
  el("div", { class = "gp-panel gp-search gp-picker", key = "picker" }, panel),
  el("div", { class = "gp-hintbar", key = "hints" }, hints),
 }) })
end

M.fieldPath = PICKER .. ".box.field"

function M.rowPath(pr: Picker.Summary): string
 return PICKER .. ".list." .. rowKey(pr)
end

return M
