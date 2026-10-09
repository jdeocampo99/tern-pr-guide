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

local REASONS: { [Model.Reason]: string } = {
	merge_failed = "Merge failed",
	feedback = "Feedback",
	checks = "Checks failing",
	conflict = "Merge conflict",
}

local function chip(class: string, text: string): Node
	return span("gp-hc-chip " .. class, text)
end

-- The chip line: the job, or who the card waits on.
local function chips(card: State.Card): { Node }
	local pr = card.pr
	local out: { Node } = {}
	if card.column == "needs_fixes" then
		for _, reason in card.reasons do table.insert(out, chip("gp-hc-chip-bad", REASONS[reason])) end
	elseif card.column == "to_review" then
		table.insert(out, chip("gp-hc-chip-info", "Review"))
	elseif card.column == "in_review" then
		if pr.tandem then
			table.insert(out, chip("gp-hc-chip-agent", "Waiting on Tandem"))
		elseif pr.checks.state == "pending" then
			table.insert(out, el("span", { class = "gp-hc-chip gp-hc-chip-wait" }, { span("gp-hc-spin", ""), span("gp-hc-chip-text", "Waiting on checks") }))
		else
			table.insert(out, chip("gp-hc-chip-wait", "Waiting on review"))
		end
	elseif card.column == "waiting_on_author" then
		local mine = pr.reviews.mine
		table.insert(out, chip(if mine and mine.verdict == "changes_requested" then "gp-hc-chip-bad-soft" else "gp-hc-chip-wait", if mine and mine.verdict == "changes_requested" then "You requested changes" else "You commented"))
	elseif card.column == "approved" then
		table.insert(out, chip("gp-hc-chip-done", "Approved"))
	elseif card.column == "inactive" then
		table.insert(out, chip("gp-hc-chip-wait", if pr.draft then "Draft" else "No recent activity"))
	end
	return out
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
	if pr.role == "review" then
		table.insert(lead, span("gp-hc-who", "@" .. pr.author))
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
	if main then table.insert(meta, el("span", { class = "gp-hc-acts", key = "acts" }, { splitButton(card, main) })) end

	local kids: { Node } = {}
	local body: { Node } = {}
	if card.column == "ready" or card.column == "approved" then
		table.insert(kids, el("span", { class = "gp-hc-tick", key = "tick" }, { Ui.icon("check") }))
	end
	table.insert(body, el("div", { class = "gp-hc-chips", key = "chips" }, chips(card)))
	table.insert(body, span("gp-hc-title", pr.title))
	local summary = card.summary
	if summary then table.insert(body, span("gp-hc-note", summary.verdict)) end
	table.insert(body, el("div", { class = "gp-hc-meta", key = "meta" }, meta))
	table.insert(kids, el("div", { class = "gp-hc-body", key = "body" }, body))

	local class = "gp-hc gp-hc-" .. toneOf(card)
	if card.selected then class ..= " gp-hc-on" end
	if main then class ..= " gp-hc-act" end
	if card.ring then class ..= " gp-hc-ring-" .. card.ring end
	return el("div", {
		class = class, key = Paths.cardKey(pr.key),
		actions = { click = "hub-select=" .. pr.key, dblclick = "hub-open=" .. pr.key },
	}, kids)
end

return M
