--!strict
-- The retained agent fix as conflict steps and tagged commit lines. Reads prepared state; builds nodes only.
local State = require("../../hub/state")
local Text = require("../../text")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span
local M = {}

local function button(label: string, key: string, action: string, class: string?, disabled: boolean?): Node
	return el("button", { class = "gp-btn gp-btn-keyed " .. (class or ""), disabled = disabled == true, actions = { click = action } }, {
		span("gp-fx-btn-label", label), Ui.keys(key),
	})
end

local function header(page: State.ReviewPage): Node
	local cleanup = page.completion == "push"
	local pushLabel = if cleanup then "Return worktree lease" else "Push to branch"
	local status: { Node }
	if page.ask then
		status = {
			span("gp-rfix-question", "Discard the fix? The agent's changes are deleted and nothing is pushed."),
			button("Discard fix", "⌘⏎", "review-fix-discard-confirm", "gp-rfix-danger", page.busy),
			button("Cancel", "esc", "review-fix-discard-cancel", nil, page.busy),
		}
	elseif page.busy then
		status = { span("gp-status-text", page.progress or "Returning worktree lease…") }
	elseif page.error then
		status = { span("gp-fx-error", page.error) }
	elseif page.loading then
		status = { span("gp-status-text", "Reading fix…") }
	else
		status = {
			span("gp-status-text", page.count .. " of " .. #page.fix.hunks .. " conflicts reviewed"),
			span("gp-status-sep", "·"),
			span("gp-rfix-agent", if page.fix.usedAgent then "Fix by agent" else "Merged without the agent"),
			span("gp-fx-repo", string.sub(page.fix.commit, 1, 7) .. " · " .. page.fix.branch),
		}
	end
	return el("div", { class = "gp-header gp-fx-head", key = "header" }, {
		el("div", { class = "gp-title", key = "title" }, {
			button("Pull requests", "esc", "review-fix-close", nil, page.busy or page.ask),
			span("gp-title-num", "#" .. page.pr.number), span("gp-title-text", page.pr.title), Ui.spacer(),
			el("div", { class = "gp-fx-hdr gp-rfix-actions" }, {
				button("Discard fix", "D", "review-fix-discard", nil, page.busy or page.ask or cleanup),
				el("button", {
					class = "gp-rv-button" .. (if page.all and page.completion ~= "discard" then "" else " gp-rfix-locked"),
					disabled = page.busy or page.ask or page.completion == "discard",
					attrs = { ["aria-disabled"] = not page.all or page.busy or page.ask or page.completion == "discard" },
					actions = { click = "review-fix-push" },
				}, { span("gp-rv-button-label", pushLabel), Ui.keys("P") }),
			}),
		}),
		el("div", { class = "gp-status gp-fx-status gp-rfix-status", key = "status" }, status),
	})
end

local function outline(page: State.ReviewPage): Node
	local rows: { Node } = {}
	for index, hunk in page.fix.hunks do
		local here, reviewed = index == page.cur, page.reviewed[hunk.id] == true
		local detail: { Node } = {}
		if here then
			if hunk.resolved then table.insert(detail, span("gp-fx-muted", if hunk.resolved.by == "rule" then "Resolved by rule" else "Agent's resolution")) end
			table.insert(detail, Ui.check(reviewed, "Reviewed", "review-fix-reviewed=" .. index, "⏎"))
		end
		table.insert(rows, el("div", {
			class = "gp-fx-step" .. (if here then " gp-ol-herebox" else ""), key = "step" .. index,
			actions = { click = "review-fix-step=" .. index },
		}, {
			el("div", { class = "gp-ol-step" .. (if here then " gp-ol-here" else "") }, {
				el("span", { class = "gp-ol-dot" .. (if reviewed then " gp-fx-dot-done" else "") }, { Ui.icon(if reviewed then "check" else "file-code") }),
				el("span", { class = "gp-ol-steptitle gp-fx-st-t" }, {
					span("", "Conflict " .. index .. " of " .. #page.fix.hunks), span("gp-fx-pth", hunk.path),
				}),
			}),
			el("div", { class = "gp-ol-stepbody" }, detail),
		}))
	end
	if #rows == 0 then table.insert(rows, span("gp-fx-muted", "No conflicts to review.")) end
	return el("div", { class = "gp-outline gp-ccard gp-sticky gp-fx-steps", key = "steps" }, {
		span("gp-ccard-h gp-fx-first", "Conflicts"), el("div", { class = "gp-ccard-steps" }, rows),
	})
end

local function excerpt(page: State.ReviewPage): Node
	local hunk = page.current
	if not hunk then
		return el("div", { class = "gp-panel gp-fx-note" }, {
			span("gp-fx-t", if page.loading then "Reading fix…" elseif page.error then "No resolution available." else "No conflicts to review."),
		})
	end
	local rows: { Node } = {}
	for index, line in page.lines do
		local kids: { Node } = {
			span("gp-plus-none", ""), span("gp-gut", tostring(line.number)), span("gp-sign", ""),
			el("span", { class = "gp-code", text = line.text }),
		}
		if line.label then table.insert(kids, span("gp-rfix-from" .. (if line.tag == "agent" then " gp-rfix-agent" else ""), line.label)) end
		table.insert(rows, el("div", { class = "gp-row gp-ctx" .. (if line.tag == "agent" then " gp-add gp-on" else ""), key = "line" .. index }, kids))
	end
	if #rows == 0 then table.insert(rows, span("gp-fx-muted", if page.original then "No lines on either side." else "No resolution lines available.")) end
	return el("div", { class = "gp-excerpt gp-current", key = "excerpt" }, {
		el("div", { class = "gp-fhead gp-rfix-fhead" }, {
			el("span", { class = "gp-fpath gp-fx-path" }, {
				span("gp-fdir", Text.dirName(hunk.path)), span("gp-fbase", Text.baseName(hunk.path)),
			}),
			span("gp-rfix-tag", if page.original then "Before the agent" else "Agent's resolution"), Ui.spacer(),
			button(if page.original then "Show resolution" else "Original conflict", "B", "review-fix-original", nil, page.busy or page.ask),
			Ui.check(page.reviewed[hunk.id] == true, "Reviewed", "review-fix-reviewed", "⏎"),
		}),
		el("div", { class = "gp-body" }, {
			el("div", { class = "gp-hscroll" }, { el("div", { class = "gp-hlines" }, rows) }),
		}),
	})
end

local function hints(page: State.ReviewPage): Node
	local function item(key: string, label: string): Node
		return el("span", { class = "gp-hb-item" }, { Ui.keys(key), span("gp-hb-label", label) })
	end
	local kids: { Node }
	if page.ask then kids = { span("gp-hb-mode", "Discard the fix?"), Ui.spacer(), item("⌘⏎", "discard fix"), item("esc", "cancel") }
	else kids = {
		span("gp-hb-mode", "Review fix"), Ui.spacer(), item("j k", "move"), item("⏎", "reviewed"),
		item("B", "original conflict"), item("P", if page.completion == "push" then "return lease" else "push"), item("esc", "back"),
	} end
	return el("div", { class = "gp-hintbar", key = "hints" }, kids)
end

function M.view(s: State.State, _motion: Ui.Motion): Node
	local page = State.reviewPage(s)
	if not page then
		return el("div", {}, { el("div", { class = "gp-root gp-hub gp-fx gp-rfix" }, {
			span("gp-fx-error", "Couldn't open the fix: that pull request is no longer available."),
			button("Pull requests", "esc", "review-fix-close"),
		}) })
	end
	-- No gp-soft or entrance class: conflict navigation, review and confirmation stay instant.
	return el("div", {}, { el("div", { class = "gp-root gp-hub gp-fx gp-rfix", key = "review-fix" }, {
		header(page),
		el("div", { class = "gp-guide gp-fx-cols", key = "columns" }, {
			outline(page), el("div", { class = "gp-code-col", key = "code" }, { excerpt(page) }),
		}),
		hints(page),
	}) })
end

return M
