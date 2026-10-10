--!strict
-- One pull request as a card: chip line, title, optional note, then the repo line. The repo line ends in
-- a slot that holds the checks and age at rest and the split button while the card is hovered or selected,
-- so a card is the same height in every state.
local Model = require("../../hub/model")
local Paths = require("./paths")
local State = require("../../hub/state")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

local M = {}

local CHIP_CLASS: { [string]: string } = {
	bad = "gp-hc-chip-bad", ["bad-soft"] = "gp-hc-chip-bad-soft", info = "gp-hc-chip-info", wait = "gp-hc-chip-wait",
	done = "gp-hc-chip-done", agent = "gp-hc-chip-agent", running = "gp-hc-chip-wait",
}

-- One chip pill; the Next up banner draws the same one.
function M.chip(chip: State.Chip): Node
	if chip.kind == "running" then
		return el("span", { class = "gp-hc-chip gp-hc-chip-wait" }, { span("gp-hc-spin", ""), span("gp-hc-chip-text", chip.text) })
	end
	return span("gp-hc-chip " .. CHIP_CLASS[chip.kind], chip.text)
end

-- The chip line: one pill per job, then the first job's detail.
local function chipLine(card: State.Card): Node
	local out: { Node } = {}
	for _, chip in card.chips do table.insert(out, M.chip(chip)) end
	-- Three or more chips leave no room for the detail to read, so it is dropped.
	if card.detail and #card.chips < 3 then table.insert(out, span("gp-hc-why gp-hc-why-" .. (card.detailKind or "bad"), card.detail)) end
	return el("div", { class = "gp-hc-chips", key = "chips" }, out)
end

-- Checks as one mark and a count, as GitHub shows them.
local function checks(pr: Model.HubPR): Node?
	local c = pr.checks
	if c.state == "none" then return nil end
	local total = c.passing + c.failing + c.pending
	local count = c.passing .. "/" .. total
	if c.state == "passing" then
		return el("span", { class = "gp-hc-ci gp-hc-ci-ok", key = "ci" }, { Ui.icon("check"), span("gp-hc-ci-n", count) })
	elseif c.state == "failing" then
		return el("span", { class = "gp-hc-ci gp-hc-ci-bad", key = "ci" }, { Ui.icon("warn"), span("gp-hc-ci-n", count) })
	end
	return el("span", { class = "gp-hc-ci", key = "ci" }, { span("gp-hc-spin", ""), span("gp-hc-ci-n", count) })
end

-- The split button: the main action with its key while selected, and the attached ▾ for the alternatives.
local function splitButton(card: State.Card, main: State.CardAction): Node
	local key = card.pr.key
	local parts: { Node } = {
		el("span", { class = "gp-sb-main", key = "main", actions = { click = main.act .. "=" .. key } }, {
			span("gp-sb-label", main.label),
			if card.selected and main.key then Ui.keys(main.key) else span("gp-sb-nokey", ""),
		}),
	}
	if card.selected and #card.more > 0 then
		table.insert(parts, el("span", { class = "gp-sb-more", key = "more", actions = { click = "hub-actions=" .. key } }, { Ui.icon("chev") }))
	end
	return el("span", { class = "gp-sb" .. (if card.selected then " gp-sb-on" else "") .. (if #parts > 1 then " gp-sb-split" else ""), key = "sb" }, parts)
end

-- The inline question that takes the split button's place: the question on the left of the line, Confirm
-- (filled, with ⌘⏎) and Cancel (with esc) on the right.
local function confirmButtons(card: State.Card): Node
	local key = card.pr.key
	return el("span", { class = "gp-hc-confirm", key = "confirm" }, {
		el("span", { class = "gp-sb" }, { el("span", { class = "gp-sb-main gp-sb-confirm", key = "ok", actions = { click = "hub-confirm=" .. key } }, { span("gp-sb-label", "Confirm"), Ui.keys("⌘⏎") }) }),
		el("span", { class = "gp-sb" }, { el("span", { class = "gp-sb-main", key = "no", actions = { click = "hub-confirm-cancel=" .. key } }, { span("gp-sb-label", "Cancel"), Ui.keys("esc") }) }),
	})
end

local function toneOf(card: State.Card): string
	local c = card.column
	if c == "needs_fixes" then return "bad" end
	if c == "to_review" then return "info" end
	if c == "ready" or c == "approved" then return "done" end
	if c == "inactive" then return "quiet" end
	return "wait"
end

function M.view(card: State.Card, now: number): Node
	local pr = card.pr
	local main = card.main
	local lead: { Node } = {}
	table.insert(lead, span("gp-hc-repo", (string.match(pr.repo, "[^/]+$") :: string) .. " #" .. pr.number))
	local named = card.detail ~= nil and string.find(card.detail, "@" .. pr.author, 1, true) ~= nil
	if pr.role == "review" then
		if not named then table.insert(lead, span("gp-hc-who", "@" .. pr.author)) end
		table.insert(lead, el("span", { class = "gp-hc-size" }, {
			span("gp-hc-add", "+" .. pr.additions),
			span("gp-hc-del", "−" .. pr.deletions),
		}))
	end
	if pr.behind then table.insert(lead, span("gp-hc-who", "Behind main")) end

	local info: { Node } = {}
	local ci = checks(pr)
	if ci then table.insert(info, ci) end
	table.insert(info, span("gp-hc-age", Model.ago(pr.lastActivityAt, now)))

	local meta: { Node } = { el("span", { class = "gp-hc-lead", key = "lead" }, lead), el("span", { class = "gp-hc-stats", key = "stats" }, info) }
	if card.asking then
		meta[1] = el("span", { class = "gp-hc-lead", key = "lead" }, { span("gp-hc-ask", card.asking) })
		table.insert(meta, el("span", { class = "gp-hc-acts", key = "acts" }, { confirmButtons(card) }))
	elseif card.busy then
		table.insert(meta, el("span", { class = "gp-hc-acts", key = "acts" }, { el("span", { class = "gp-hc-busy" }, { span("gp-hc-spin", ""), span("gp-hc-busy-text", card.busy) }) }))
	elseif main then
		table.insert(meta, el("span", { class = "gp-hc-acts", key = "acts" }, { splitButton(card, main) }))
	end

	local kids: { Node } = {}
	local body: { Node } = {}
	if card.column == "ready" or card.column == "approved" then
		table.insert(body, el("div", { class = "gp-hc-titlerow", key = "titlerow" }, { el("span", { class = "gp-hc-tick", key = "tick" }, { Ui.icon("check") }), span("gp-hc-title", pr.title) }))
	else
		table.insert(body, chipLine(card))
		table.insert(body, span("gp-hc-title", pr.title))
	end
	local summary = card.summary
	if summary then table.insert(body, span("gp-hc-note", summary.verdict)) end
	table.insert(body, el("div", { class = "gp-hc-meta", key = "meta" }, meta))
	table.insert(kids, el("div", { class = "gp-hc-body", key = "body" }, body))

	local class = "gp-hc gp-hc-" .. toneOf(card)
	if card.selected then class ..= " gp-hc-on" end
	if main and not card.busy then class ..= " gp-hc-act" end
	if card.asking or card.busy then class ..= " gp-hc-pinned" end
	if card.ring then class ..= " gp-hc-ring-" .. card.ring end
	return el("div", {
		class = class, key = Paths.cardKey(pr.key),
		actions = { click = "hub-select=" .. pr.key, dblclick = "hub-open=" .. pr.key },
	}, kids)
end

return M
