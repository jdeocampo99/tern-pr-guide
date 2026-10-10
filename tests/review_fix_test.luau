--!strict
-- Frozen conflict provenance and injected command/lease effects. Never loads Fetch, Block, views or Tern.
local ReviewFix = require("../src/hub/review-fix")
local AgentFix = require("../src/hub/agent-fix")
local State = require("../src/hub/state")
local Keys = require("../src/keys")
local Fields = require("../src/text-field")
local Fixture: any = require("../fixtures/hub/review-fix")

local function request(): ReviewFix.Request
	return {
		kind = "ready", key = "acme/web#1803", selectedKey = "acme/web#1803", routeKey = "acme/web#1803",
		repo = "acme/web", number = 1803, headOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		fix = Fixture.fix, reviewed = {}, verified = true,
	}
end

local function key(s: State.State, name: string, action: string, value: string?, modifier: string?)
	local pressed = Keys.hubAction(s, { name = name, meta = modifier == "meta", ctrl = modifier == "ctrl", alt = false, shift = false } :: any)
	assert(pressed and pressed.act == action and pressed.value == value)
end

return function()
	local review = ReviewFix.build(Fixture.fix, Fixture.files, Fixture.details)
	assert(review.verified and not review.error and #review.hunks == 3)
	assert(review.hunks[1].id == "fonts-loader" and review.hunks[1].path == "src/fonts.ts")
	assert(review.hunks[2].id == "fonts-cache" and review.hunks[2].path == "src/fonts.ts")
	assert(review.hunks[3].id == "note-props" and review.hunks[3].path == "src/note.ts" and review.hunks[3].by == "rule")
	local expected = {
		{
			{ "base", "// loader", nil, 1 }, { "base", "shared", nil, 2 }, { "theirs", "main manifest", "main", 3 },
			{ "ours", "branch range", "Your branch", 4 }, { "agent", "  combine(range, manifest);", "Agent", 5 }, { "base", "// end loader", nil, 6 },
		},
		{ { "base", "// cache", nil, 8 }, { "agent", "const cache = combineCaches();", "Agent", 9 }, { "base", "// end cache", nil, 10 } },
		{
			{ "base", "type Props = {", nil, 1 }, { "base", "title: string;", nil, 2 }, { "ours", "script?: string;", "Your branch", 3 },
			{ "theirs", "lessonId: string;", "main", 4 }, { "base", "};", nil, 5 },
		},
	}
	for i, rows in expected do
		local lines = ReviewFix.lines(review.hunks[i], false)
		assert(#lines == #rows)
		for j, row in rows do
			local line = lines[j]
			assert(line.tag == row[1] and line.text == row[2] and line.label == row[3] and line.number == row[4])
			assert(not string.find(line.text, "unrelated", 1, true))
		end
	end
	local original = ReviewFix.lines(review.hunks[1], true)
	assert(#original == 4)
	assert(original[1].text == "shared" and original[1].tag == "ours")
	assert(original[2].text == "branch range" and original[2].label == "Your branch")
	assert(original[3].text == "shared" and original[3].tag == "theirs")
	assert(original[4].text == "main manifest" and original[4].label == "main")
	local changedFiles = table.clone(Fixture.files)
	changedFiles["src/fonts.ts"] = "// loader\nshared\nchanged after journal\n// end loader\n"
	local unreadable = ReviewFix.build(Fixture.fix, changedFiles, nil)
	assert(not unreadable.verified and ReviewFix.lines(unreadable.hunks[1], true)[2].text == "branch range")
	changedFiles["src/fonts.ts"] = Fixture.files["src/fonts.ts"] .. Fixture.files["src/fonts.ts"]
	assert(not ReviewFix.build(Fixture.fix, changedFiles, nil).verified, "ambiguous commit locations fail closed")
	assert(not ReviewFix.build(Fixture.fix, {}, nil).verified)
	local stale = table.clone(Fixture.details)
	stale.conflicts = { { path = "src/fonts.ts", hunks = { { start = 2, branch = { "new branch" }, main = { "new main" } } } } }
	assert(ReviewFix.build(Fixture.fix, Fixture.files, stale).hunks[1].ours[2] == "branch range")
	-- tools/conflicts show bounds side/context previews; write tags even copied lines as agent.
	-- The retained full original restores ownership, and displayed context comes from the commit.
	local bounded = table.clone(Fixture.fix)
	local hunk = table.clone(Fixture.fix.hunks[1])
	local longBranch = "copied branch " .. string.rep("z", 260)
	local longContext = string.rep("x", 240) .. " exact context suffix"
	hunk.context = { before = { string.rep("x", 240) }, after = { "end" } }
	hunk.ours, hunk.theirs = { string.sub(longBranch, 1, 240) }, { "other main" }
	hunk.resolved = { by = "agent", lines = { { tag = "agent", text = longBranch } } }
	bounded.hunks = { hunk }
	local full = ReviewFix.build(bounded, { ["src/fonts.ts"] = longContext .. "\n" .. longBranch .. "\nend\n" }, nil, {
		["fonts-loader"] = { path = "src/fonts.ts", start = 2, base = { "old loader" }, ours = { longBranch }, theirs = { "other main" } },
	})
	assert(full.verified and full.hunks[1].lines[1].tag == "base" and full.hunks[1].lines[1].label == nil)
	assert(full.hunks[1].lines[1].text == longContext and full.hunks[1].lines[2].text == longBranch)
	assert(full.hunks[1].lines[2].tag == "ours" and full.hunks[1].lines[2].label == "Your branch")
	assert(ReviewFix.lines(full.hunks[1], true)[1].text == longBranch)
	assert(not ReviewFix.build(bounded, { ["src/fonts.ts"] = longContext .. "\n" .. longBranch .. "\nend\n" }, nil, {}).verified)

	local ready = request()
	local calls: { { string } } = {}
	local remoteHead = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	local lease = true
	local nextPushOK = true
	local runner: AgentFix.Runner = function(argv, opts, done)
		assert(opts.cwd == "/pool/acme/web/wt-review")
		assert(#argv == 6 and argv[1] == "git" and argv[2] == "-C" and argv[3] == "/pool/acme/web/wt-review" and argv[4] == "push")
		assert(argv[5] == "https://github.com/acme/web.git" and argv[6] == "cccccccccccccccccccccccccccccccccccccccc:refs/heads/topic")
		for _, word in argv do assert(word ~= "--force" and word ~= "--force-with-lease" and string.sub(word, 1, 1) ~= "+") end
		table.insert(calls, table.clone(argv))
		if nextPushOK then remoteHead = "cccccccccccccccccccccccccccccccccccccccc" end
		done({ status = if nextPushOK then 0 else 1, stdout = "", stderr = if nextPushOK then "" else "rejected", timed_out = false })
	end
	local function pressP(pushOK: boolean, returnOK: boolean): ReviewFix.Result?
		local plan = ReviewFix.plan("push", ready)
		if not plan then return nil end
		local pushed = ready.completion == "push"
		if plan.command then
			nextPushOK = pushOK
			runner(plan.command.argv, { cwd = plan.command.cwd }, function(out) pushed = out.status == 0 and not out.timed_out end)
		end
		if pushed then
			ready.completion = "push"
			if returnOK then lease = false end
		end
		return ReviewFix.result(plan, pushed, pushed and returnOK)
	end
	for _, kind in { "running", "pushing", "failed", "no_clone" } do
		ready.kind = kind
		assert(pressP(true, true) == nil and #calls == 0)
	end
	ready.kind = "ready"
	assert(pressP(true, true) == nil and #calls == 0, "Fix ready and Review fix never push on their own")
	ready.reviewed["fonts-loader"] = true
	ready.reviewed["fonts-cache"] = true
	assert(pressP(true, true) == nil and #calls == 0)
	ready.reviewed["note-props"] = true
	assert(ReviewFix.allReviewed(ready.fix, ready.reviewed) and State.reviewed(ready.fix, ready.reviewed))
	local result = pressP(true, false) :: ReviewFix.Result
	assert(#calls == 1 and lease and not result.clear and result.card == "fix_ready")
	assert(remoteHead == "cccccccccccccccccccccccccccccccccccccccc" and result.remoteHeadOid == "cccccccccccccccccccccccccccccccccccccccc")
	assert(ready.reviewed["fonts-loader"] and ready.reviewed["fonts-cache"] and ready.reviewed["note-props"])
	assert(ReviewFix.plan("discard", ready, true) == nil, "a pushed fix cannot be discarded")
	result = pressP(true, true) :: ReviewFix.Result
	assert(#calls == 1 and not lease and result.clear and result.card == "refresh", "P retries lease return without another push")

	ready, remoteHead, lease = request(), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", true
	ready.reviewed = { ["fonts-loader"] = true, ["fonts-cache"] = true, ["note-props"] = true }
	local before = #calls
	result = pressP(false, true) :: ReviewFix.Result
	assert(#calls == before + 1 and not result.clear and ready.completion == nil and lease and remoteHead == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "push failure keeps the ready fix")
	ready.selectedKey = "acme/web#1802"
	assert(ReviewFix.plan("push", ready) == nil)
	ready.selectedKey, ready.routeKey = ready.key, "acme/web#1802"
	assert(ReviewFix.plan("push", ready) == nil)
	ready.routeKey, ready.headOid = ready.key, "dddddddddddddddddddddddddddddddddddddddd"
	assert(ReviewFix.plan("push", ready) == nil)
	ready.headOid, ready.verified = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false
	assert(ReviewFix.plan("push", ready) == nil)
	ready.verified = true
	local fork = ReviewFix.plan("push", ready, nil, "author/web") :: ReviewFix.Plan
	assert(fork.command and fork.command.argv[5] == "https://github.com/author/web.git")
	assert(ReviewFix.plan("push", ready, nil, "--bad") == nil)

	local malformed = table.clone(Fixture.fix)
	malformed.hunks = { Fixture.fix.hunks[1], Fixture.fix.hunks[1] }
	assert(not ReviewFix.allReviewed(malformed, ready.reviewed) and not State.reviewed(malformed, ready.reviewed))
	assert(not ReviewFix.build(malformed, Fixture.files, nil).verified)
	local missing: any = table.clone(Fixture.fix.hunks[1])
	missing.id = nil
	malformed.hunks = { missing }
	assert(not ReviewFix.allReviewed(malformed, ready.reviewed))
	local clean = table.clone(Fixture.fix)
	clean.hunks = {}
	assert(ReviewFix.allReviewed(clean, {}) and ReviewFix.build(clean, {}, nil).verified)
	ready.fix, ready.reviewed = clean, {}
	assert(ReviewFix.plan("push", ready) ~= nil, "a clean merge is already reviewed")
	ready.fix = table.clone(Fixture.fix)
	ready.reviewed = { ["fonts-loader"] = true, ["fonts-cache"] = true, ["note-props"] = true }
	ready.fix.branch = "topic:other"
	assert(ReviewFix.plan("push", ready) == nil)
	ready.fix = table.clone(Fixture.fix)
	ready.fix.commit = "--bad"
	ready.reviewed = { ["fonts-loader"] = true, ["fonts-cache"] = true, ["note-props"] = true }
	assert(ReviewFix.plan("push", ready) == nil and ReviewFix.readCommands(ready.fix) == nil)

	ready, remoteHead, lease = request(), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", true
	before = #calls
	assert(ReviewFix.plan("discard", ready, false) == nil)
	local discard = ReviewFix.plan("discard", ready, true) :: ReviewFix.Plan
	assert(discard.command == nil and discard.returnLease and discard.next == "needs_fixes")
	result = ReviewFix.result(discard, false, false)
	assert(not result.clear and result.card == "fix_ready" and lease)
	assert(result.remoteHeadOid == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and remoteHead == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	ready.completion = "discard"
	assert(ReviewFix.plan("push", ready) == nil)
	discard = ReviewFix.plan("discard", ready, true) :: ReviewFix.Plan
	lease = false
	result = ReviewFix.result(discard, false, true)
	assert(result.clear and result.card == "needs_fixes" and not lease and #calls == before)
	assert(result.remoteHeadOid == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and remoteHead == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

	local commands = ReviewFix.readCommands(Fixture.fix) :: { ReviewFix.Command }
	assert(#commands == 4)
	assert(commands[1].argv[5] == "diff" and commands[1].argv[11] == "src/fonts.ts" and commands[1].argv[12] == "src/note.ts")
	assert(commands[2].argv[7] == "cccccccccccccccccccccccccccccccccccccccc:src/fonts.ts")
	assert(commands[3].argv[7] == "cccccccccccccccccccccccccccccccccccccccc:src/note.ts")
	assert(commands[4].argv[4] == "rev-parse" and commands[4].argv[5] == "--absolute-git-dir")
	for _, command in commands do for _, word in command.argv do assert(word ~= "push") end end

	local s = State.new(Fixture.prs, 1791590400, nil)
	s.agents[Fixture.key] = { kind = "ready", fix = Fixture.fix, reviewed = {}, review = review }
	State.project(s)
	State.select(s, Fixture.key)
	key(s, "enter", "hub-open")
	assert(State.openReviewFix(s, Fixture.key) and s.mode == "review-fix")
	key(s, "j", "review-fix-move", "1")
	key(s, "up", "review-fix-move", "-1")
	key(s, "enter", "review-fix-reviewed")
	key(s, "b", "review-fix-original")
	State.reviewOriginal(s)
	assert((State.reviewPage(s) :: State.ReviewPage).lines[2].text == "branch range")
	State.reviewOriginal(s)
	State.reviewToggle(s)
	State.reviewSelect(s, 2)
	State.reviewToggle(s)
	assert(not (State.reviewPage(s) :: State.ReviewPage).all)
	State.reviewSelect(s, 3)
	State.reviewToggle(s)
	assert((State.reviewPage(s) :: State.ReviewPage).all)
	State.reviewToggle(s)
	assert(not (State.reviewPage(s) :: State.ReviewPage).all)
	key(s, "p", "review-fix-push")
	key(s, "d", "review-fix-discard")
	s.search = Fields.create("fonts")
	assert(Keys.hubAction(s, { name = "p" } :: any) == nil and Keys.hubAction(s, { name = "j" } :: any) == nil)
	s.search = Fields.create("")
	s.link = Fields.create("acme/web#1803")
	assert(Keys.hubAction(s, { name = "d" } :: any) == nil)
	s.link = Fields.create("")
	State.reviewAsk(s, true)
	key(s, "enter", "review-fix-discard-confirm", nil, "meta")
	key(s, "enter", "review-fix-discard-confirm", nil, "ctrl")
	key(s, "escape", "review-fix-discard-cancel")
	assert(Keys.hubAction(s, { name = "p" } :: any) == nil)
	State.reviewAsk(s, false)
	key(s, "escape", "review-fix-close")
	State.setBusy(s, Fixture.key, "Pushing fix…")
	assert(State.reviewRequest(s) == nil and Keys.hubAction(s, { name = "p" } :: any) == nil)
	assert(State.agentFlight(s, Fixture.key, { settled = true, starting = false, releasing = true, busy = true, worktree = "/pool/acme/web/wt-review" }) == "ready")
	State.setBusy(s, Fixture.key, nil)
	State.closeFixes(s)
	assert(s.mode == "board" and s.selected == "acme/web#1803" and s.agents[Fixture.key].kind == "ready")
	s.agents[Fixture.key] = nil
	State.project(s)
	assert((State.card(s, Fixture.key) :: State.Card).column == "needs_fixes")
	assert(State.openFixes(s, Fixture.key) and (s.route :: State.Route).kind == "fixes", "Needs fixes still opens the existing page")
end
