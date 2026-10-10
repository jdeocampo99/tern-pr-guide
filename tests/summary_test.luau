--!strict
-- Pure feedback/keys/state acceptance plus injected read-only calls and the actual bot engine.
local AgentFix = require("../src/hub/agent-fix")
local Fixes = require("../src/hub/fixes")
local Keys = require("../src/keys")
local ReviewFix = require("../src/hub/review-fix")
local State = require("../src/hub/state")
local Summary = require("../src/hub/summary")
local Fixture: any = require("../fixtures/hub/summary")

local HEAD, COMMIT, POOL_HEAD = string.rep("a", 40), string.rep("b", 40), string.rep("d", 40)
local WORKTREE = "/pool/acme/web/wt-1"

local function copy(value: any): any
	if type(value) ~= "table" then return value end
	local out = {}
	for key, item in value do out[key] = copy(item) end
	return out
end

local function fresh(): State.State
	local s = State.new(copy(Fixture.prs), Fixture.asOf, nil)
	for _, details in Fixture.details do State.setDetails(s, copy(details)) end
	return s
end

local function card(s: State.State, key: string): State.Card
	local found = State.card(s, key)
	assert(found, "missing card " .. key)
	return found
end

local function equal(actual: { string }, expected: { string })
	assert(#actual == #expected, "argv length: " .. table.concat(actual, " "))
	for i, value in expected do assert(actual[i] == value, "argv at " .. i) end
end

type Entry = { argv: { string }, stdout: string?, status: number?, cwd: string? }
local function git(args: { string }, stdout: string?, status: number?): Entry
	local argv = { "git", "--literal-pathspecs", "-C", WORKTREE }
	table.move(args, 1, #args, 5, argv)
	return { argv = argv, cwd = WORKTREE, stdout = stdout or "", status = status }
end

-- These are the engine's actual injected effects. Unexpected commands fail, including any push,
-- conflicts-tool call, merge or journal read on the bot path.
local SANDBOX = "/usr/bin/sandbox-exec"
local function botEngine(mode: "ready" | "stop" | "unsandboxed")
	local stopDuringAgent = mode == "stop"
	local s = fresh()
	local key = Fixture.details.bot.key
	local spec = Fixture.spec(key)
	if mode == "unsandboxed" then spec.sandbox = nil end
	local entries: { Entry } = {
		{ argv = { "treehouse", "--root", "/pool", "get", "--lease", "--lease-holder", "prguide", "--no-fetch", "--json" }, cwd = "/clone", stdout = "lease" },
		git({ "status", "--porcelain" }), git({ "rev-parse", "HEAD" }, POOL_HEAD .. "\n"),
		git({ "fetch", "--no-tags", "origin", "+refs/pull/1904/head:refs/prguide/agent/head", "+refs/heads/main:refs/remotes/origin/main" }),
		git({ "rev-parse", "refs/prguide/agent/head" }, HEAD .. "\n"),
		git({ "-c", "core.hooksPath=/dev/null", "switch", "--detach", HEAD }),
	}
	if mode ~= "unsandboxed" then table.insert(entries, { argv = { SANDBOX }, cwd = WORKTREE, stdout = Fixture.transcripts.bot.stdout }) end
	if mode == "ready" then
		for _, entry in {
			git({ "rev-parse", "HEAD" }, HEAD .. "\n"), git({ "diff", "--name-only", "--diff-filter=U" }),
			git({ "add", "--all" }),
			git({ "diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=3", "--src-prefix=a/", "--dst-prefix=b/", HEAD, "--" }, Fixture.botDiff),
			git({ "diff", "--cached", "--check" }),
			git({ "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--no-verify", "-m", "Address bot review comments" }),
			git({ "rev-parse", "HEAD" }, COMMIT .. "\n"),
		} do table.insert(entries, entry) end
	end
	for _, entry in {
		git({ "reset", "--hard", POOL_HEAD }), git({ "clean", "-fd" }),
		{ argv = { "treehouse", "--root", "/pool", "return", WORKTREE, "--if-lease-holder", "prguide", "--if-lease-id", "lease-19" }, cwd = "/clone", stdout = "" },
	} do table.insert(entries, entry) end
	local calls: { Entry } = {}
	local pending: (() -> ())? = nil
	local finished, released = 0, false
	local fix: AgentFix.Fix? = nil
	assert(State.beginAgent(s, key, Fixture.asOf))
	local engine = AgentFix.engine(spec, {
		runner = function(argv, opts, done)
			local entry = entries[#calls + 1]
			assert(entry, "unexpected call " .. table.concat(argv, " "))
			assert(opts.cwd == entry.cwd and opts.stdin == nil)
			if argv[1] == SANDBOX then
				-- The worker runs only inside the write sandbox, with the unchanged omp argv behind it.
				local profile = AgentFix.sandboxProfile(WORKTREE, "/home/prguide") :: string
				assert(argv[2] == "-p" and argv[3] == profile and opts.timeout_ms == 20 * 60_000)
				local inner = table.move(argv, 4, #argv, 1, {})
				equal(inner, Fixture.transcripts.bot.argv)
				equal(inner, { "/omp", "-p", "--no-session", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-title",
					"--tools", "read,edit,write,grep,glob", "--model", "provider/model", "--thinking", "high", AgentFix.botPrompt(Fixture.details.bot) })
			else
				assert(argv[1] ~= "/omp", "the bot worker must never run unwrapped")
				equal(argv, entry.argv)
			end
			for _, word in argv do assert(word ~= "push" and word ~= "--force" and word ~= "--force-with-lease") end
			table.insert(calls, { argv = argv, cwd = opts.cwd })
			local function resume()
				done({ status = entry.status or 0, stdout = entry.stdout or "", stderr = "", timed_out = false })
				-- Duplicate responses cannot start a second commit or return.
				done({ status = 0, stdout = entry.stdout or "", stderr = "", timed_out = false })
			end
			if argv[1] == SANDBOX and stopDuringAgent then pending = resume else resume() end
		end,
		decode = function(text)
			assert(text == "lease")
			return { path = WORKTREE, lease_id = "lease-19", lease_holder = "prguide" }
		end,
		samePath = function(a, b, done) assert(a == WORKTREE and b == "/reader"); done(false, nil) end,
		resolutions = function() error("a bot edit must not read the conflict journal") end,
	}, Fixture.asOf, function(outcome)
		assert(State.agentOutcome(s, key, outcome))
		assert(card(s, key).column == "in_review", "bot lifecycle must stay In review")
	end, function(result, err)
		finished += 1
		fix = result
		if mode == "unsandboxed" then assert(result == nil and err and string.find(err, "write sandbox", 1, true))
		else assert((err == "stopped") == stopDuringAgent) end
	end)
	assert(#calls == 0, "constructing an engine is lazy")
	engine.begin()
	if mode == "unsandboxed" then
		assert(finished == 1 and fix == nil and engine.held() == nil, "no sandbox: nothing runs and the lease returns")
	elseif stopDuringAgent then
		assert(#calls == 7 and pending ~= nil)
		engine.stop()
		assert(#calls == 7 and finished == 0 and engine.held() ~= nil, "Stop waits for the child before cleanup")
		local resume = pending :: () -> ()
		resume()
		assert(finished == 1 and fix == nil and engine.held() == nil)
	else
		assert(finished == 1 and fix ~= nil)
		local ready = fix :: AgentFix.Fix
		assert(ready.commit == COMMIT and ready.headOid == HEAD and ready.usedAgent and ready.branch == "topic")
		assert(card(s, key).chips[1].text == "Fix ready" and engine.held() ~= nil)
		assert(State.openReviewFix(s, key))
		local page = State.reviewPage(s); assert(page and page.bot)
		assert(not State.beginAgent(s, key, Fixture.asOf), "ready fix retains ownership")
		local review = ReviewFix.build(ready, { ["src/retry.luau"] = Fixture.botFile }, nil)
		assert(review.verified and #review.hunks == 1)
		assert(review.hunks[1].lines[2].text == "return value or 0" and review.hunks[1].lines[2].tag == "agent")
		assert(not ReviewFix.allReviewed(ready, {}) and ReviewFix.allReviewed(ready, { ["bot:1"] = true }))
		assert(not ReviewFix.build(ready, { ["src/retry.luau"] = "changed" }, nil).verified)
		engine.release(function(ok, err) assert(ok and not err); released = true end)
		assert(released and engine.held() == nil and not engine.busy())
	end
	assert(#calls == #entries, "missing bot pipeline calls")
end

return function()
	local d = Fixture.details
	local prompt = Summary.prompt(d.three)
	for _, text in { "maria-k", "devon", "review-bot[bot]", "Explain the retry limit.", "Use a clearer name.", "Guard the empty value." } do
		assert(string.find(prompt, text, 1, true), "missing feedback " .. text)
	end
	for _, text in { "SOURCE_PATH_SENTINEL", "DIFF_HUNK_SENTINEL", "URL_SENTINEL", "CHANGED_PATH_SENTINEL", "FILE_CONTENT_SENTINEL",
		"CHECK_NAME_SENTINEL", "CHECK_URL_SENTINEL", "CHECK_CONTENT_SENTINEL", "ANNOTATION_PATH_SENTINEL", "ANNOTATION_CONTENT_SENTINEL",
		"CONFLICT_PATH_SENTINEL", "CONFLICT_OURS_SENTINEL", "CONFLICT_THEIRS_SENTINEL", "CONFLICT_NOTE_SENTINEL", HEAD, d.three.key } do
		assert(not string.find(prompt, text, 1, true), "code/metadata leaked into feedback prompt: " .. text)
	end
	assert(string.find(Summary.prompt(d.requested), "Add the guard before retrying.", 1, true))
	assert(not Summary.onlyComments(d.three) and Summary.onlyComments(d.comments) and not Summary.onlyComments(d.requested))
	assert(not Summary.onlyComments(d.bot))
	local empty = copy(d.comments); empty.threads = {}; assert(not Summary.onlyComments(empty))
	local check = copy(d.comments); check.checks = copy(d.three.checks); assert(not Summary.onlyComments(check))
	local conflict = copy(d.comments); conflict.conflictNote = "Reading conflicts"; assert(not Summary.onlyComments(conflict))
	local requestedThread = copy(d.comments); requestedThread.threads[1].group = "requested"; assert(not Summary.onlyComments(requestedThread))

	local three = Summary.parse(Fixture.transcripts.three.stdout)
	assert(three and three.verdict == "Reply to @maria-k" and #three.comments == 3)
	assert(three.comments[1].author == "maria-k" and three.comments[1].text == "Needs an explanation of the retry limit.")
	assert(three.comments[2].author == "devon" and three.comments[2].text == "Suggests a clearer name.")
	assert(three.comments[3].author == "review-bot[bot]" and three.comments[3].text == "Requests a guard for an empty value.")
	local commentsAnswer = Summary.parse(Fixture.transcripts.comments.stdout)
	assert(commentsAnswer and commentsAnswer.verdict == "Reply to @maria-k" and #commentsAnswer.comments == 1)
	assert(commentsAnswer.comments[1].author == "maria-k" and commentsAnswer.comments[1].text == "Asks why retries stop at three.")
	local requestedAnswer = Summary.parse(Fixture.transcripts.requested.stdout)
	assert(requestedAnswer and requestedAnswer.verdict == "Address requested changes" and #requestedAnswer.comments == 1)
	assert(requestedAnswer.comments[1].author == "devon" and requestedAnswer.comments[1].text == "Requests a guard before retrying.")
	for _, name in { "three", "comments", "requested" } do
		local parsed = Summary.parse(Fixture.transcripts[name].stdout)
		assert(parsed and Summary.matches(d[name], parsed))
		equal(Summary.argv("/omp", "provider/model", "high", Summary.prompt(d[name])), Fixture.transcripts[name].argv)
	end
	for _, text in { "", "Reply to @maria-k", "PRGUIDE_SUMMARY_V1\nVerdict: Review feedback\nEnd", "PRGUIDE_SUMMARY_V1\nVerdict: \nComment: @devon\tHi\nEnd",
		"PRGUIDE_SUMMARY_V1\nVerdict: Review feedback\nComment: @devon\tHi\nComment: @devon\tAgain\nEnd",
		"PRGUIDE_SUMMARY_V1\nVerdict: Review feedback\nComment: @devon\t\nEnd", Fixture.transcripts.three.stdout .. "\nExtra text",
		string.gsub(Fixture.transcripts.three.stdout, "\nEnd$", ""), "```\n" .. Fixture.transcripts.three.stdout .. "\n```" } do assert(Summary.parse(text) == nil) end
	local incomplete = Summary.parse("PRGUIDE_SUMMARY_V1\nVerdict: Reply to @maria-k\nComment: @maria-k\tReply to the question.\nEnd")
	assert(incomplete and not Summary.matches(d.three, incomplete))
	local unknown = Summary.parse("PRGUIDE_SUMMARY_V1\nVerdict: Reply to @unknown\nComment: @maria-k\tReply to the question.\nEnd")
	assert(unknown and not Summary.matches(d.comments, unknown))

	local s = fresh()
	for _, name in { "comments", "requested", "three", "bot" } do
		local key = d[name].key
		State.select(s, key)
		local main = card(s, key).main
		assert(main and main.act == (if name == "comments" then "card-summarize" else "card-agent") and main.key == "A")
		local a = Keys.hubAction(s, { name = "a" } :: any)
		assert(a and a.act == main.act and a.value == key)
		local shift = Keys.hubAction(s, { name = "a", shift = true } :: any)
		assert(shift and shift.act == "card-summarize" and shift.value == key)
		assert(State.openFixes(s, key))
		local pageShift = Keys.hubAction(s, { name = "a", shift = true } :: any)
		assert(pageShift and pageShift.act == "card-summarize" and pageShift.value == key)
		State.closeFixes(s)
	end
	assert(State.installSummary(s, d.three, Fixture.transcripts.three.stdout))
	assert(card(s, d.three.key).detail == "Reply to @maria-k" and #card(s, d.three.key).chips == 1 and #card(s, d.three.key).reasons == 3)
	State.select(s, d.comments.key)
	s.search.text = "filter"; assert(Keys.hubAction(s, { name = "a" } :: any) == nil)
	s.search.text = ""; s.link.text = "link"; assert(Keys.hubAction(s, { name = "a", shift = true } :: any) == nil)
	s.link.text = ""

	-- A bot's body-only comment review at the current head is actionable (its body is in the details as a
	-- review-level thread); one on an older head is not. Bot threads and bot requested changes stay actionable.
	local quiet = fresh()
	local botPr = State.prOf(quiet, d.bot.key) :: any
	local function botCard(): State.Card
		State.project(quiet)
		return card(quiet, d.bot.key)
	end
	local live = botCard()
	assert(State.botActionable(botPr) and live.main and live.main.act == "card-agent")
	botPr.reviews.threads, botPr.reviews.unresolved = {}, 0
	local bodyOnly = botCard()
	assert(State.botActionable(botPr) and bodyOnly.column == "in_review" and bodyOnly.agentSlot)
	assert(bodyOnly.main and bodyOnly.main.act == "card-agent" and bodyOnly.main.label == "Fix bot comments")
	botPr.reviews.latest[1].oid = COMMIT
	assert(not State.botActionable(botPr) and botCard().main.act == "card-copy", "a bot review on an older head offers nothing")
	botPr.reviews.latest[1].oid = HEAD
	botPr.reviews.latest[1].verdict = "changes_requested"
	local requestedBot = botCard()
	assert(State.botActionable(botPr) and requestedBot.main and requestedBot.main.act == "card-agent")

	-- The review-level bot comment reaches both consumers once, as a bot comment.
	local review = copy(Fixture.reviewBot)
	assert(Summary.authors(review)[1] == "review-bot[bot]" and string.find(Summary.prompt(review), "Comment by @review-bot[bot] (bot) (22 bytes):\nGuard the empty value.", 1, true))
	assert(AgentFix.hasBotFeedback(review, nil))
	local reviewPrompt = AgentFix.botPrompt(review)
	assert(string.find(reviewPrompt, "Bot @review-bot[bot] review comment (22 bytes):\nGuard the empty value.", 1, true))
	assert(not string.find(reviewPrompt, " on  ", 1, true))

	-- Only feedback still live on the PR is read: a requested change the reviewer has since approved is a
	-- plain comment, not a request, and an active request is kept.
	local function livePr(verdict: string, oid: string?): any
		local pr = copy(State.prOf(fresh(), d.requested.key))
		pr.reviews.latest = { { author = "devon", bot = false, verdict = verdict, at = Fixture.asOfIso, oid = oid or HEAD } }
		return pr
	end
	local withComment = copy(d.requested)
	table.insert(withComment.threads, { id = "c2", author = "maria-k", body = "Why three retries?", bot = false, group = "comment",
		path = "src/retry.luau", line = 5, outdated = false, replies = 0, url = "", hunk = nil })
	local active = Summary.current(withComment, livePr("changes_requested"))
	assert(#active.reviews == 1 and active.threads[1].group == "requested" and not Summary.onlyComments(active))
	assert(string.find(Summary.prompt(active), "Requested changes by @devon", 1, true))
	local superseded = Summary.current(withComment, livePr("approved"))
	assert(#superseded.reviews == 0 and superseded.threads[1].group == "comment" and Summary.onlyComments(superseded))
	local supersededPrompt = Summary.prompt(superseded)
	assert(not string.find(supersededPrompt, "Requested change", 1, true) and not string.find(supersededPrompt, "Add the guard before retrying.", 1, true))
	assert(string.find(supersededPrompt, "Comment by @devon", 1, true) and string.find(supersededPrompt, "Why three retries?", 1, true))
	assert(#Summary.current(withComment, livePr("changes_requested", COMMIT)).reviews == 0, "a request on an older head is superseded")
	assert(#Summary.current(withComment, livePr("dismissed")).reviews == 0)
	local approvedState = fresh()
	local approvedPr = State.prOf(approvedState, d.requested.key) :: any
	approvedPr.reviews.latest[1].verdict = "approved"
	State.project(approvedState)
	-- The cached details still hold the review, but it is not current: A summarizes the comment instead.
	local comment = copy(d.requested)
	comment.threads = { { id = "c", author = "maria-k", body = "Why three retries?", bot = false, group = "comment",
		path = "src/retry.luau", line = 5, outdated = false, replies = 0, url = "", hunk = nil } }
	State.setDetails(approvedState, comment)
	approvedPr.reviews.threads = { { author = "maria-k", bot = false } }
	approvedPr.reviews.unresolved = 1
	State.project(approvedState)
	local approvedCard = card(approvedState, d.requested.key)
	assert(approvedCard.reasons[1] == "feedback" and approvedCard.main and approvedCard.main.act == "card-summarize")
	local bodyBot = livePr("commented")
	bodyBot.reviews.latest = { { author = "review-bot[bot]", bot = true, verdict = "commented", at = Fixture.asOfIso, oid = HEAD } }
	assert(#Summary.current(review, bodyBot).threads == 1)
	bodyBot.reviews.latest[1].verdict = "approved"
	assert(#Summary.current(review, bodyBot).threads == 0, "a bot that later approved has no live review comment")

	-- The summary command is built only from validated fields: an option, an @file attachment or a prompt that
	-- does not start with the fixed line never produces a command, so the runner is never reached.
	local goodPrompt = Summary.prompt(d.comments)
	assert(Summary.plan("/omp", "provider/model", "high", goodPrompt) ~= nil and Summary.plan("omp", "provider/model:high", nil, goodPrompt) ~= nil)
	for _, bad in {
		{ "/omp", "provider/model", "high", "@/etc/passwd" }, { "/omp", "provider/model", "high", "--tools=bash" },
		{ "/omp", "provider/model", "high", "-p" }, { "/omp", "provider/model", "high", "\n" .. goodPrompt },
		{ "/omp", "provider/model", "high", " " .. goodPrompt }, { "/omp", "provider/model", "high", "@" .. goodPrompt },
		{ "/omp", "provider/model", "high", goodPrompt .. "\0" }, { "/omp", "--tools=bash", "high", goodPrompt },
		{ "/omp", "@/etc/passwd", "high", goodPrompt }, { "/omp", "provider/model", "--tools", goodPrompt },
		{ "/omp", "provider/model", "high;rm", goodPrompt }, { "--version", "provider/model", "high", goodPrompt },
		{ "/bin/sh", "provider/model", "high", goodPrompt }, { "/omp\n", "provider/model", "high", goodPrompt },
		{ "relative/omp", "provider/model", "high", goodPrompt },
	} do assert(Summary.plan(bad[1], bad[2], bad[3], bad[4]) == nil, table.concat(bad, " | ")) end
	local planned = Summary.plan("/omp", "provider/model", "high", goodPrompt) :: { string }
	assert(planned[#planned] == goodPrompt and string.sub(planned[#planned], 1, 1) ~= "@" and string.sub(planned[#planned], 1, 1) ~= "-")

	-- The bot worker's profile: writes only under the worktree (not its .git pointer), OMP state and temp.
	local profile = AgentFix.sandboxProfile(WORKTREE, "/home/prguide") :: string
	assert(string.find(profile, "(deny file-write*)", 1, true) and string.find(profile, '(subpath "' .. WORKTREE .. '")', 1, true))
	assert(string.find(profile, '(subpath "' .. WORKTREE .. '/.git")', 1, true) and string.find(profile, '(subpath "/home/prguide/.omp")', 1, true))
	assert(not string.find(profile, '"/clone', 1, true) and not string.find(profile, '(subpath "/")', 1, true) and not string.find(profile, "(allow file-write*)", 1, true))
	assert(string.find(AgentFix.sandboxProfile("/tmp/pool/wt", "/home/prguide") :: string, '(subpath "/private/tmp/pool/wt")', 1, true))
	for _, bad in { "relative", '/pool/"quote', "/pool/back\\slash", "/pool/new\nline", "/pool/../outside", "/pool/.." } do
		assert(AgentFix.sandboxProfile(bad, "/home/prguide") == nil, bad)
	end

	-- GitHub feedback can change with no new head: a refresh with different review metadata drops the summary
	-- and the details, and a read that was out while that happened is rejected by its signature.
	local refreshed = fresh()
	State.installSummary(refreshed, d.comments, Fixture.transcripts.comments.stdout)
	assert(refreshed.summaries[d.comments.key] ~= nil and refreshed.details[d.comments.key] ~= nil)
	local before = State.feedbackSignature(State.prOf(refreshed, d.comments.key) :: any)
	local same = copy(refreshed.prs)
	State.replace(refreshed, same, Fixture.asOf, nil)
	assert(refreshed.summaries[d.comments.key] ~= nil and refreshed.details[d.comments.key] ~= nil, "identical feedback keeps both")
	local resolved = copy(refreshed.prs)
	for _, pr in resolved do
		if pr.key == d.comments.key then pr.reviews.threads, pr.reviews.unresolved = {}, 0 end
	end
	State.replace(refreshed, resolved, Fixture.asOf, nil)
	assert(refreshed.summaries[d.comments.key] == nil and refreshed.details[d.comments.key] == nil)
	assert(State.feedbackSignature(State.prOf(refreshed, d.comments.key) :: any) ~= before)

	-- fixture=cases: the comments-only boards keep Summarize with the details that load for them.
	for _, key in { "acme/api#118", "acme/api#119" } do
		local recorded = Fixture.cases[key]
		assert(recorded and Summary.onlyComments(recorded) and #recorded.threads == 1 and not recorded.threads[1].bot)
		local parsed = Summary.parse(Fixture.answer(recorded))
		assert(parsed and Summary.matches(recorded, parsed) and string.find(parsed.verdict, "^Reply to @"))
	end

	-- The pure plan is the same argv Block gives Fetch. The injected adapter runs only an
	-- explicit action. Host Block/Fetch execution remains a parent integration check.
	local calls: { { string } } = {}
	local function clicked(action: Keys.Action)
		assert(action.act == "card-summarize" and action.value == d.comments.key)
		local argv = Summary.argv("/omp", "provider/model", "high", Summary.prompt(d.comments))
		table.insert(calls, argv)
		assert(State.installSummary(s, s.details[d.comments.key], Fixture.transcripts.comments.stdout))
	end
	State.project(s)
	State.openFixes(s, d.comments.key)
	assert(#calls == 0 and s.summaries[d.comments.key] == nil, "drawing/preparing details must not run a model")
	local pressed = Keys.hubAction(s, { name = "a" } :: any)
	assert(pressed); clicked(pressed)
	assert(#calls == 1)
	local argv = calls[1]
	equal(argv, { "/omp", "-p", "--no-tools", "--no-session", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-title",
		"--system-prompt", "Summarize supplied feedback only. Use no tools and return only the requested summary envelope.",
		"--model", "provider/model", "--thinking", "high", Summary.prompt(d.comments) })
	for _, word in argv do assert(word ~= "git" and word ~= "treehouse" and word ~= "get" and word ~= "write" and word ~= "push") end
	assert(card(s, d.comments.key).detail == "Reply to @maria-k")
	assert((State.saved(s) :: any).summaries == nil and (State.saved(s) :: any).details == nil)
	assert(State.new(copy(Fixture.prs), Fixture.asOf, State.saved(s)).summaries[d.comments.key] == nil)
	assert(not State.installSummary(s, d.comments, "bad output"))
	assert(s.summaries[d.comments.key].verdict == "Reply to @maria-k", "bad output preserves the previous summary")
	local changed = copy(d.comments); changed.threads[1].body = "Different feedback"; State.setDetails(s, changed)
	assert(s.summaries[d.comments.key] == nil and not State.installSummary(s, d.comments, Fixture.transcripts.comments.stdout))
	local moved = fresh(); local pr = State.prOf(moved, d.comments.key); assert(pr); pr.headOid = COMMIT
	assert(not State.installSummary(moved, d.comments, Fixture.transcripts.comments.stdout))

	local hunks = AgentFix.botHunks(Fixture.botDiff)
	assert(hunks and #hunks == 1 and hunks[1].id == "bot:1" and hunks[1].path == "src/retry.luau" and hunks[1].start == 1)
	assert(table.concat(hunks[1].ours, "\n") == "local function valueOrZero(value)\nreturn value\nend")
	assert(hunks[1].resolved and hunks[1].resolved.lines[2].text == "return value or 0")
	for _, diff in { "", string.gsub(Fixture.botDiff, "%+%+%+ b/src/retry.luau", "+++ /dev/null"),
		Fixture.botDiff .. "diff --git a/empty b/empty\nnew file mode 100644\nindex 0000000..1111111\n",
		string.gsub(Fixture.botDiff, "100644", "120000"), string.gsub(Fixture.botDiff, "@@ %-1,3 %+1,3 @@", "@@ -1,4 +1,3 @@"),
		Fixture.botDiff .. "\\ No newline at end of file\n", Fixture.botDiff .. "Binary files a/image and b/image differ\n" } do assert(AgentFix.botHunks(diff) == nil) end
	local reviewOnly = copy(d.bot)
	reviewOnly.threads = {}
	reviewOnly.reviews = { { author = "review-bot[bot]", body = "Guard the empty value.", at = Fixture.asOfIso, url = "" } }
	assert(not AgentFix.hasBotFeedback(reviewOnly, nil))
	assert(AgentFix.hasBotFeedback(reviewOnly, { "review-bot[bot]" }))
	assert(string.find(AgentFix.botPrompt(reviewOnly, { "review-bot[bot]" }), "Guard the empty value.", 1, true))
	assert(not AgentFix.hasBotFeedback(d.requested, nil), "human requested changes never become bot input")
	local botPrompt = AgentFix.botPrompt(d.three)
	assert(string.find(botPrompt, "Guard the empty value.", 1, true) and not string.find(botPrompt, "Explain the retry limit.", 1, true))
	assert(not string.find(botPrompt, "DIFF_HUNK_SENTINEL", 1, true))
	botEngine("ready")
	botEngine("stop")
	botEngine("unsandboxed")
end
