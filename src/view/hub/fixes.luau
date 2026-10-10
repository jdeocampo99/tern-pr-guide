--!strict
-- The fixes page: a Needs fixes card opened at what needs fixing, in the guided review's layout. The left
-- column lists the problems as steps (requested changes, comments, failing checks, merge conflicts); the
-- right shows the code for the step on show with the thread, annotation or conflict pinned in it.
-- Everything it draws was decided by `State.fix*` and `Fixes.steps`.
local Fields = require("../../text-field")
local Fixes = require("../../hub/fixes")
local Model = require("../../hub/model")
local State = require("../../hub/state")
local Text = require("../../text")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

type Step = Fixes.Step

local M = {}

local function rootClass(s: State.State): string
	return "gp-root gp-hub gp-fx" .. (if s.keyed then "" else " gp-soft")
end

-- A button that shows its key, selected when the panel's highlight is on it.
local function keyed(class: string, label: string, hint: string, action: string, on: boolean): Node
	return el("button", { class = "gp-btn gp-btn-keyed " .. class .. (if on then " gp-fx-item-on" else ""), actions = { click = action } }, {
		span("gp-fx-btn-label", label),
		Ui.keys(hint),
	})
end

-- Prose of a comment: a paragraph per line, `code` spans drawn.
local function paragraphs(text: string): { Node }
	local out: { Node } = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		if line ~= "" then table.insert(out, el("div", { class = "gp-fx-p" }, { Ui.rich(line) })) end
	end
	return out
end

local function cardHead(avatar: Node, who: string, action: string, where: string): Node
	return el("div", { class = "gp-card-head" }, {
		avatar,
		el("span", { class = "gp-card-line" }, { span("gp-card-who", who), span("gp-card-action", action) }),
		span("gp-card-where", where),
	})
end

-- Header ---------------------------------------------------------------------------------------------------

local function header(s: State.State, pr: Model.HubPR, steps: { Step }): Node
	local route = s.route :: State.Route
	local actions: { Node } = {}
	local main = State.fixMain(s)
	if main then
		-- The card's own wording ("Fix with agent", "Hand off to Tandem", "Summarize"); the button itself arrives with the agent.
		table.insert(actions, el("button", { class = "gp-btn gp-btn-keyed gp-fx-agent-btn", key = "agent", actions = { click = main.act .. "=" .. pr.key } }, {
			span("gp-fx-btn-label", main.label), Ui.keys(main.key or "A"),
		}))
	end
	local title: { Node } = {
		el("span", { class = "gp-hdr-act", key = "back", actions = { click = "fixes-close" } }, { span("gp-hdr-act-label", "Pull requests"), Ui.keys("esc") }),
		span("gp-title-num", "#" .. pr.number),
		span("gp-title-text", pr.title),
		Ui.spacer(),
		el("div", { class = "gp-fx-hdr", key = "actions" }, actions),
	}
	local status: { Node } = {}
	-- The card's own chips, so the page and the board never disagree; a card off the board falls back to the steps'.
	local chips: { string } = {}
	local card = State.card(s, pr.key)
	if card then
		for _, chip in card.chips do table.insert(chips, chip.text) end
	else
		chips = Fixes.chips(steps)
	end
	if route.error then
		table.insert(status, span("gp-fx-error", route.error))
	elseif #chips > 0 then
		for _, chip in chips do table.insert(status, span("gp-fx-chip", chip)) end
	elseif route.loading then
		table.insert(status, span("gp-status-text", "Loading what needs fixing…"))
	else
		table.insert(status, span("gp-fx-clear", "Nothing left to fix"))
	end
	table.insert(status, span("gp-status-sep", "·"))
	table.insert(status, span("gp-fx-repo", pr.repo))
	local left = State.fixLeft(s)
	if left > 0 and #chips > 0 then
		table.insert(status, span("gp-status-sep", "·"))
		table.insert(status, span("gp-status-text", left .. " left"))
	end
	return el("div", { class = "gp-header gp-fx-head", key = "header" }, {
		el("div", { class = "gp-title", key = "title" }, title),
		el("div", { class = "gp-status gp-fx-status", key = "status" }, status),
	})
end

-- Steps ----------------------------------------------------------------------------------------------------

local function stepRow(s: State.State, step: Step, index: number): Node
	local route = s.route :: State.Route
	local here = index == route.cur
	local done = step.thread ~= nil and route.resolved[step.thread.id] == true
	local dot = if done then Ui.icon("check") else nil
	local where = ""
	if step.path then where = step.path .. (if step.line then ":" .. step.line else "") end
	local foot: { Node } = { span("gp-fx-pth", where) }
	if done then table.insert(foot, span("gp-fx-state gp-fx-state-done", "Resolved")) end
	local lead: Node = if dot then el("span", { class = "gp-ol-dot gp-fx-dot-done" }, { dot }) else span("gp-ol-dot gp-fx-dot-open", "○")
	return el("div", { class = "gp-fx-step" .. (if here then " gp-ol-herebox" else ""), key = "s" .. index, actions = { click = "fixes-step=" .. index } }, {
		el("div", { class = "gp-ol-step" .. (if here then " gp-ol-here" else ""), key = "row" }, {
			lead,
			el("span", { class = "gp-ol-steptitle gp-fx-st-t" }, {
				el("span", { class = "gp-fx-st-a" }, { span("gp-fx-who", step.who), span("gp-fx-text", step.text) }),
				el("span", { class = "gp-fx-st-f" }, foot),
			}),
		}),
	})
end

local function outline(s: State.State, steps: { Step }, bots: { { author: string, count: number } }): Node
	local route = s.route :: State.Route
	local kids: { Node } = {}
	local first = true
	for _, group in Fixes.GROUPS do
		local rows: { Node } = {}
		for index, step in steps do
			if step.group == group.id then table.insert(rows, stepRow(s, step, index)) end
		end
		if #rows > 0 then
			table.insert(kids, el("div", { class = "gp-ccard-h" .. (if first then " gp-fx-first" else ""), key = "h-" .. group.id }, {
				span("gp-fx-gl", group.label), span("gp-fx-gn", " · " .. #rows),
			}))
			table.insert(kids, el("div", { class = "gp-ccard-steps", key = "g-" .. group.id }, rows))
			first = false
		end
	end
	if #steps == 0 then
		table.insert(kids, span("gp-fx-muted", if route.loading then "Loading what needs fixing…" else "Nothing left to fix."))
	end
	if #bots > 0 then
		local names: { string } = {}
		local count = 0
		for _, bot in bots do
			table.insert(names, bot.author)
			count += bot.count
		end
		local label = table.concat(names, ", ")
		local group: { Node } = {
			el("div", { class = "gp-fx-gh", key = "bots", actions = { click = "fixes-bots" } }, {
				el("span", { class = "gp-ol-dot" }, { Ui.icon(if route.bots then "chev" else "chev-r") }),
				el("span", { class = "gp-fx-gt" }, { span("", label), span("gp-fx-gn", " · bot " .. (if count == 1 then "comment" else "comments")) }),
				Ui.keys("B"),
			}),
		}
		if route.bots then
			table.insert(group, span("gp-fx-muted", label .. " left " .. count .. (if count == 1 then " comment" else " comments") .. ". Bot comments aren't counted as requested changes."))
		end
		table.insert(kids, span("gp-ccard-h", "Not counted"))
		table.insert(kids, el("div", { class = "gp-ccard-steps", key = "g-bots" }, { el("div", { class = "gp-fx-g" }, group) }))
	end
	return el("div", { class = "gp-outline gp-ccard gp-sticky gp-fx-steps", key = "steps" }, kids)
end

-- Code -----------------------------------------------------------------------------------------------------

local function gap(arrow: string, count: number, key: string): Node
	return el("div", { class = "gp-gap gp-fx-gap", key = key }, {
		span("gp-gap-gut", arrow),
		span("gp-gap-count", count .. " unchanged " .. (if count == 1 then "line" else "lines")),
	})
end

local SIGNS = { add = "+", del = "−", ctx = " " }

local function codeRow(row: Fixes.Row, index: number, pinned: boolean, pinClass: string): Node
	return el("div", { class = "gp-row gp-" .. row.kind .. (if pinned then " gp-on " .. pinClass else ""), key = "r" .. index }, {
		span("gp-plus-none", ""),
		span("gp-gut", if row.old then tostring(row.old) else ""),
		span("gp-gut", if row.new then tostring(row.new) else ""),
		span("gp-sign", SIGNS[row.kind]),
		el("span", { class = "gp-code", text = row.text }),
	})
end

local function lineRun(rows: { Node }, key: string): Node
	return el("div", { class = "gp-hscroll", key = key }, { el("div", { class = "gp-hlines" }, rows) })
end

-- Pins: the cards hung under a line, by the index of the row they follow.
type Pin = { row: number, node: Node, class: string }

-- A file excerpt: its header, the lines, and `pins` hung under their rows. `extra` goes in the header's right end.
local function excerpt(path: string, shown: Fixes.Excerpt, pins: { Pin }, extra: { Node }): Node
	local first, last = shown.rows[1], shown.rows[#shown.rows]
	local adds, dels = 0, 0
	for _, row in shown.rows do
		if row.kind == "add" then adds += 1 elseif row.kind == "del" then dels += 1 end
	end
	local from, to = first.new or first.old or 1, last.new or last.old or 1
	local head: { Node } = {
		el("span", { class = "gp-fpath gp-fx-path" }, {
			el("span", { class = "gp-fcaret" }, { Ui.icon("chev") }),
			span("gp-fdir", Text.dirName(path)),
			span("gp-fbase", Text.baseName(path)),
		}),
		span("gp-frange", Text.lineSpan(from, to)),
		Ui.spacer(),
		span("gp-adds", if adds > 0 then "+" .. adds else ""),
		span("gp-dels", if dels > 0 then "−" .. dels else ""),
	}
	for _, node in extra do table.insert(head, node) end
	local body: { Node } = {}
	if shown.before > 0 then table.insert(body, gap("↑", shown.before, "gap-up")) end
	local pinAt: { [number]: { Pin } } = {}
	for _, pin in pins do
		pinAt[pin.row] = pinAt[pin.row] or {}
		table.insert(pinAt[pin.row], pin)
	end
	local run: { Node } = {}
	local runs = 0
	local function flush()
		if #run == 0 then return end
		runs += 1
		table.insert(body, lineRun(run, "h" .. runs))
		run = {}
	end
	for index, row in shown.rows do
		local here = pinAt[index]
		table.insert(run, codeRow(row, index, here ~= nil, if here then here[1].class else ""))
		if here then
			flush()
			for _, pin in here do table.insert(body, pin.node) end
		end
	end
	flush()
	if shown.after and shown.after > 0 then table.insert(body, gap("↓", shown.after, "gap-down")) end
	return el("div", { class = "gp-excerpt gp-current", key = "ex" }, {
		el("div", { class = "gp-fhead", key = "fhead" }, head),
		el("div", { class = "gp-body", key = "body" }, body),
	})
end

-- The same container with no code, for a card that has none to hang from. It keeps the excerpt's keys.
local function cardsOnly(nodes: { Node }): Node
	return el("div", { class = "gp-fx-stack", key = "ex" }, { el("div", { class = "gp-fx-stack", key = "body" }, nodes) })
end

local function itemOn(s: State.State, act: string): boolean
	local route = s.route :: State.Route
	return route.focus == "panel" and route.reply == nil and State.fixItems(s, State.fixStep(s))[route.item] == act
end

local function avatarFor(author: string): Node
	return Ui.avatar("gp-fx-av", author)
end

-- The row showing new-side line `line`.
local function rowOf(rows: { Fixes.Row }, line: number?): number?
	if line then
		for index, row in rows do
			if row.new == line then return index end
		end
	end
	return nil
end

local function threadPanel(s: State.State, motion: Ui.Motion, step: Step, pr: Model.HubPR): Node
	local route = s.route :: State.Route
	local thread = step.thread :: Fixes.ThreadDetail
	local done = route.resolved[thread.id] == true
	local composing = route.reply ~= nil
	local action = if thread.group == "requested" then "requested changes" else "commented"
	if thread.outdated then action ..= " · outdated" end
	local where = if thread.line then "line " .. thread.line else Text.baseName(thread.path)
	local msgs: { Node } = {
		el("div", { class = "gp-fx-msg" .. (if done then " gp-fx-dim" else ""), key = "m0" }, {
			cardHead(avatarFor(thread.author), thread.author, action, where),
			el("div", { class = "gp-card-body" }, paragraphs(thread.body)),
		}),
	}
	if thread.replies > 0 then
		table.insert(msgs, el("div", { class = "gp-fx-more", key = "more" }, { span("gp-fx-muted-line", thread.replies .. (if thread.replies == 1 then " reply" else " replies") .. " on GitHub") }))
	end
	for n, reply in route.replies[thread.id] or {} do
		table.insert(msgs, el("div", { class = "gp-fx-msg", key = "mine" .. n }, {
			cardHead(Ui.avatar("gp-avatar-you", "You"), "You", "replied", "just now"),
			el("div", { class = "gp-card-body" }, paragraphs(reply)),
		}))
	end
	local kids: { Node } = { el("div", { class = "gp-fx-msgs", key = "msgs" }, msgs) }
	local reply = route.reply
	if reply then
		table.insert(kids, el("div", { class = "gp-card-body gp-fx-compose", key = "body" }, { Fields.node(reply, "field", "Reply to @" .. thread.author) }))
		table.insert(kids, el("div", { class = "gp-card-foot", key = "foot" }, {
			keyed("gp-fx-ok", if route.busy then "Replying…" else "Reply", "⌘⏎", "fixes-post", false),
			keyed("gp-btn-ghost", "Cancel", "esc", "fixes-cancel", false),
		}))
	else
		table.insert(kids, el("div", { class = "gp-card-foot", key = "foot" }, {
			keyed("", "Reply", "R", "fixes-reply", itemOn(s, "reply")),
			if done then el("span", { class = "gp-card-state gp-card-state-added" }, { Ui.icon("check"), span("gp-card-state-text", "Resolved") })
				else keyed("", "Resolve", "E", "fixes-resolve", itemOn(s, "resolve")),
			Ui.spacer(),
		}))
	end
	local enter = if composing then Ui.entering(motion, "fx:composer", "gp-enter-card") else ""
	local class = "gp-card" .. (if thread.group == "requested" and not done then " gp-card-problem" else "") .. (if composing then " gp-card-composer " .. enter else "")
	local card = el("div", { class = class, key = if composing then "composer" else "card" }, kids)
	local shown = if thread.hunk then Fixes.hunkExcerpt(thread.hunk) else nil
	if shown == nil then return cardsOnly({ card }) end
	return excerpt(thread.path, shown, { { row = rowOf(shown.rows, thread.line) or #shown.rows, node = card, class = "" } }, {})
end

local function reviewPanel(step: Step): Node
	local review = step.review :: Fixes.ReviewDetail
	return cardsOnly({
		el("div", { class = "gp-card gp-card-problem", key = "card" }, {
			cardHead(avatarFor(review.author), review.author, "requested changes", ""),
			el("div", { class = "gp-card-body" }, paragraphs(review.body)),
			el("div", { class = "gp-card-foot", key = "foot" }, { keyed("", "Open on GitHub", "G", "fixes-github", false) }),
		}),
	})
end

local function annotationCard(check: Fixes.FailingCheck, annotation: Fixes.Annotation): Node
	local verb = if annotation.level == "failure" then "reported an error" elseif annotation.level == "warning" then "reported a warning" else "left a notice"
	return el("div", { class = "gp-card gp-card-problem", key = "a" .. annotation.line }, {
		cardHead(Ui.avatar("gp-fx-av-bad", "×"), check.name, verb, (if annotation.title then annotation.title .. " · " else "") .. "line " .. annotation.line),
		el("div", { class = "gp-card-body" }, { el("div", { class = "gp-fx-p" }, { span("gp-fx-code", annotation.message) }) }),
	})
end

local function checkPanel(s: State.State, step: Step, pr: Model.HubPR, details: Fixes.FixDetails): Node
	local check = step.check :: Fixes.FailingCheck
	local total = pr.checks.passing + pr.checks.failing + pr.checks.pending
	local meta = (if check.workflow then check.workflow .. " · " else "") .. pr.checks.failing .. " of " .. total .. (if total == 1 then " check failing" else " checks failing")
	local kids: { Node } = {
		el("div", { class = "gp-fx-chk", key = "strip" }, {
			span("gp-fx-cname", check.name), span("gp-fx-cfail", "Failed"), span("gp-fx-cmeta", meta), Ui.spacer(),
			keyed("", "View log", "⇧L", "fixes-log", itemOn(s, "log")),
		}),
	}
	local usable = Fixes.usable(check.annotations)
	if #usable == 0 then
		table.insert(kids, el("div", { class = "gp-panel gp-fx-note", key = "note" }, {
			span("gp-fx-t", check.summary or "The check failed."), span("gp-fx-n", "No annotations on source files."),
		}))
		return el("div", { class = "gp-fx-stack", key = "ex" }, { el("div", { class = "gp-fx-stack", key = "body" }, kids) })
	end
	-- One excerpt per annotated file (the first three), each with its annotations pinned; a file the page has
	-- no copy of shows its annotations alone.
	local paths: { string } = {}
	for _, annotation in usable do
		if #paths < 3 and table.find(paths, annotation.path) == nil then table.insert(paths, annotation.path) end
	end
	for _, path in paths do
		local text = if details.files then details.files[path] else nil
		local ofPath: { Fixes.Annotation } = {}
		for _, annotation in usable do
			if annotation.path == path then table.insert(ofPath, annotation) end
		end
		local shown = if text then Fixes.fileExcerpt(text, ofPath[1].line) else nil
		local pins: { Pin } = {}
		local alone: { Node } = {}
		for _, annotation in ofPath do
			local index = if shown then rowOf(shown.rows, annotation.line) else nil
			if index then
				table.insert(pins, { row = index, node = annotationCard(check, annotation), class = "gp-fx-err" })
			else
				table.insert(alone, annotationCard(check, annotation))
			end
		end
		if shown then table.insert(kids, excerpt(path, shown, pins, {})) end
		if #alone > 0 then
			table.insert(kids, span("gp-fx-where", path))
			for _, node in alone do table.insert(kids, node) end
		end
	end
	return el("div", { class = "gp-fx-stack", key = "ex" }, { el("div", { class = "gp-fx-stack", key = "body" }, kids) })
end

local function side(label: string, detail: string, start: number, lines: { string }, other: { string }, key: string): Node
	local shared: { [string]: boolean } = {}
	for _, line in other do shared[line] = true end
	local rows: { Node } = {}
	for k, text in lines do
		rows[k] = el("div", { class = "gp-row" .. (if text == "" or shared[text] then " gp-fx-shared" else ""), key = "r" .. k }, {
			span("gp-plus-none", ""), span("gp-gut", tostring(start + k - 1)), span("gp-sign", ""), el("span", { class = "gp-code", text = text }),
		})
	end
	table.insert(rows, el("div", { class = "gp-fx-pad", key = "pad" }, {}))
	return el("div", { class = "gp-fx-side", key = key }, {
		el("div", { class = "gp-fx-side-h", key = "h" }, { span("gp-fx-side-n", label), span("gp-fx-side-b", detail) }),
		lineRun(rows, "lines"),
	})
end

local function causeLine(cause: Fixes.Cause): Node
	local ref = if cause.number then "#" .. cause.number else string.sub(cause.sha, 1, 7)
	local by = if string.find(cause.author, "%s") then cause.author else "@" .. cause.author
	return el("div", { class = "gp-fx-cause", key = "cause" }, {
		span("gp-fx-causetext", "Main changed this in "), span("gp-fx-b", ref), span("gp-fx-causetext", " " .. cause.title .. " by " .. by),
	})
end

local function conflictPanel(s: State.State, step: Step, pr: Model.HubPR): Node
	local main = State.fixMain(s)
	local conflict = step.conflict
	if conflict == nil then
		local kids: { Node } = {
			span("gp-fx-t", "Conflicts with " .. pr.baseBranch),
			span("gp-fx-n", step.note or ""),
			el("div", { class = "gp-fx-fbtns", key = "btns" }, { keyed("", "Resolve on GitHub", "G", "fixes-github", itemOn(s, "github")) }),
		}
		return cardsOnly({ el("div", { class = "gp-panel gp-fx-note", key = "note" }, kids) })
	end
	local buttons: { Node } = {}
	if main then table.insert(buttons, keyed("gp-fx-agent-btn", main.label, main.key or "A", main.act .. "=" .. pr.key, itemOn(s, "agent"))) end
	table.insert(buttons, keyed("", "Resolve on GitHub", "G", "fixes-github", itemOn(s, "github")))
	local count = #conflict.hunks
	local head: { Node } = {
		el("span", { class = "gp-fpath gp-fx-path" }, {
			el("span", { class = "gp-fcaret" }, { Ui.icon("chev") }),
			span("gp-fdir", Text.dirName(conflict.path)),
			span("gp-fbase", Text.baseName(conflict.path)),
		}),
		span("gp-frange", count .. (if count == 1 then " conflict" else " conflicts")),
		Ui.spacer(),
		el("span", { class = "gp-fx-fbtns" }, buttons),
	}
	local parts: { Node } = { el("div", { class = "gp-fhead", key = "fhead" }, head) }
	if conflict.cause then table.insert(parts, causeLine(conflict.cause)) end
	local body: { Node } = {}
	for n, hunk in conflict.hunks do
		local last = hunk.start + math.max(#hunk.branch, #hunk.main) - 1
		table.insert(body, span("gp-fx-chead", "Conflict " .. n .. " of " .. count .. " · lines " .. hunk.start .. "–" .. last))
		table.insert(body, side("Your branch", "#" .. pr.number, hunk.start, hunk.branch, hunk.main, "b" .. n))
		table.insert(body, side(pr.baseBranch, "origin/" .. pr.baseBranch, hunk.start, hunk.main, hunk.branch, "m" .. n))
	end
	if count == 0 then body = { span("gp-fx-muted", "Git reports a conflict here, but no conflict markers were found.") } end
	table.insert(parts, el("div", { class = "gp-body", key = "body" }, body))
	return el("div", { class = "gp-excerpt gp-current", key = "ex" }, parts)
end

local function failurePanel(s: State.State, step: Step): Node
	return cardsOnly({
		el("div", { class = "gp-panel gp-fx-note", key = "note" }, {
			span("gp-fx-t", "Merge failed"), span("gp-fx-n", step.note or step.text),
			el("div", { class = "gp-fx-fbtns", key = "btns" }, { keyed("", "Open on GitHub", "G", "fixes-github", itemOn(s, "github")) }),
		}),
	})
end

local function panel(s: State.State, motion: Ui.Motion, pr: Model.HubPR, details: Fixes.FixDetails, step: Step?): Node
	local route = s.route :: State.Route
	local inner: Node
	if step == nil then
		inner = cardsOnly({ el("div", { class = "gp-panel gp-fx-note", key = "note" }, {
			span("gp-fx-t", if route.loading then "Loading what needs fixing…" else "Nothing left to fix."),
			span("gp-fx-n", if route.loading then "" else "Every problem on this pull request is resolved."),
		}) })
	elseif step.thread then
		inner = threadPanel(s, motion, step, pr)
	elseif step.review then
		inner = reviewPanel(step)
	elseif step.check then
		inner = checkPanel(s, step, pr, details)
	elseif step.group == "conflict" then
		inner = conflictPanel(s, step, pr)
	else
		inner = failurePanel(s, step)
	end
	return el("div", { class = "gp-code-col", key = "code" }, { inner })
end

-- Hint bar -------------------------------------------------------------------------------------------------

local function hints(s: State.State, steps: { Step }): Node
	local route = s.route :: State.Route
	local step = steps[route.cur]
	local function item(key: string, label: string): Node
		return el("span", { class = "gp-hb-item" }, { Ui.keys(key), span("gp-hb-label", label) })
	end
	local kids: { Node } = {}
	if route.reply and step and step.thread then
		kids = { span("gp-hb-mode", "Replying to @" .. step.thread.author), Ui.spacer(), item("⌘⏎", "post reply"), item("esc", "cancel") }
	else
		local short = if step == nil then "Nothing left to fix" elseif step.check then step.check.name elseif step.path then Text.baseName(step.path) else step.who
		kids = { span("gp-hb-mode", if step then "Step " .. route.cur .. " of " .. #steps .. " · " .. short else short), Ui.spacer() }
		table.insert(kids, item("h j k l", "move"))
		table.insert(kids, item("⏎", if route.focus == "steps" then "go to code" else "choose"))
		if step and step.thread then
			table.insert(kids, item("R", "reply"))
			table.insert(kids, item("E", "resolve"))
		end
		if step and step.check then table.insert(kids, item("⇧L", "view log")) end
		local main = State.fixMain(s)
		if main and main.key then table.insert(kids, item(main.key, string.lower(main.label))) end
		if step then table.insert(kids, item("G", if step.group == "conflict" then "resolve on GitHub" else "open on GitHub")) end
		if #Fixes.bots(State.fixDetails(s) :: Fixes.FixDetails) > 0 then table.insert(kids, item("B", "bot comments")) end
		table.insert(kids, item("esc", "back"))
	end
	return el("div", { class = "gp-hintbar", key = "hints" }, kids)
end

function M.view(s: State.State, motion: Ui.Motion): Node
	local route = s.route :: State.Route
	local pr = State.prOf(s, route.key)
	local details = State.fixDetails(s)
	if pr == nil or details == nil then
		return el("div", {}, { el("div", { class = rootClass(s), key = "fixes" }, { span("gp-hub-error", "Couldn't open the fixes page: that pull request is no longer on the board.") }) })
	end
	local steps = Fixes.steps(details, pr)
	local step = steps[route.cur]
	return el("div", {}, { el("div", { class = rootClass(s), key = "fixes" }, {
		header(s, pr, steps),
		el("div", { class = "gp-guide gp-fx-cols" .. (if route.focus == "panel" then " gp-fx-pf" else ""), key = "cols" }, {
			outline(s, steps, Fixes.bots(details)),
			panel(s, motion, pr, details, step),
		}),
		hints(s, steps),
	}) })
end

return M
