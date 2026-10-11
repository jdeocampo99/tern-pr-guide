--!strict
-- The add-by-link box at the top of To review: a dashed field ("Paste a pull request link to review", N) and,
-- once something is typed, what the text names and the two things ⏎ and ⇧⏎ do with it.
local Fields = require("../../text-field")
local State = require("../../hub/state")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

local M = {}

local HINT = "A pull request link looks like github.com/owner/repo/pull/123"

local function button(label: string, key: string, action: string, primary: boolean): Node
	return el("span", { class = "gp-sb" .. (if primary then " gp-sb-on" else ""), key = action }, {
		el("span", { class = "gp-sb-main", key = "main", actions = { click = action } }, { span("gp-sb-label", label), Ui.keys(key) }),
	})
end

local function short(repo: string): string
	return string.match(repo, "[^/]+$") or repo
end

-- What the text names, with its two actions.
local function panel(target: State.LinkTarget): Node?
	if target.kind == "empty" then return nil end
	if target.kind == "invalid" then return span("gp-hub-add-msg", HINT) end
	if target.kind == "new" then
		return el("div", { class = "gp-hub-link", key = "link" }, {
			span("gp-hub-link-t", short(target.repo) .. " #" .. target.number),
			span("gp-hub-link-m", target.repo .. " · not on your board"),
			el("span", { class = "gp-hub-link-acts" }, {
				button("Add to review", "⏎", "hub-link-add", true),
				button("Open without adding", "⇧⏎", "hub-link-open", false),
			}),
		})
	end
	local pr = target.pr
	local where = if pr.role == "mine" then "your pull request, already on the board" else "already in Review requests"
	return el("div", { class = "gp-hub-link", key = "link" }, {
		span("gp-hub-link-t", pr.title),
		span("gp-hub-link-m", pr.repo .. " #" .. pr.number .. " · @" .. pr.author .. " · " .. where),
		el("span", { class = "gp-hub-link-acts" }, {
			button("Show on the board", "⏎", "hub-link-add", true),
			button("Open", "⇧⏎", "hub-link-open", false),
		}),
	})
end

function M.view(s: State.State): Node
	local on = s.mode == "link"
	local row = el("div", { class = "gp-hub-add" .. (if on then " gp-hub-add-on" else ""), key = "row", actions = { click = "hub-link" } }, {
		span("gp-hub-add-plus", "+"),
		Fields.node(s.link, "field", "Paste a pull request link to review"),
		Ui.keys("N"),
	})
	local kids: { Node } = { row }
	local below = panel(State.linkTarget(s))
	if below then table.insert(kids, below) end
	return el("div", { class = "gp-hub-addbox", key = "add" }, kids)
end

return M
