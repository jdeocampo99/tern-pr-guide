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
local function botEngine(stopDuringAgent: boolean)
	local s = fresh()
	local key = Fixture.details.bot.key
	local spec = Fixture.spec(key)
	local entries: { Entry } = {
		{ argv = { "treehouse", "--root", "/pool", "get", "--lease", "--lease-holder", "prguide", "--no-fetch", "--json" }, cwd = "/clone", stdout = "lease" },
		git({ "status", "--porcelain" }), git({ "rev-parse", "HEAD" }, POOL_HEAD .. "\n"),
		git({ "fetch", "--no-tags", "origin", "+refs/pull/1904/head:refs/prguide/agent/head", "+refs/heads/main:refs/remotes/origin/main" }),
		git({ "rev-parse", "refs/prguide/agent/head" }, HEAD .. "\n"),
		git({ "-c", "core.hooksPath=/dev/null", "switch", "--detach", HEAD }),
		{ argv = { "/omp" }, cwd = WORKTREE, stdout = Fixture.transcripts.bot.stdout },
	}
	if not stopDuringAgent then
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
			if argv[1] == "/omp" then
				equal(argv, Fixture.transcripts.bot.argv)
				equal(argv, { "/omp", "-p", "--no-session", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-title",
					"--tools", "read,edit,write,grep,glob", "--model", "provider/model", "--thinking", "high", AgentFix.botPrompt(Fixture.details.bot) })
			else equal(argv, entry.argv) end
			for _, word in argv do assert(word ~= "push" and word ~= "--force" and word ~= "--force-with-lease") end
			table.insert(calls, { argv = argv, cwd = opts.cwd })
			local function resume()
				done({ status = entry.status or 0, stdout = entry.stdout or "", stderr = "", timed_out = false })
				-- Duplicate responses cannot start a second commit or return.
				done({ status = 0, stdout = entry.stdout or "", stderr = "", timed_out = false })
			end
			if argv[1] == "/omp" and stopDuringAgent then pending = resume else resume() end
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
		assert((err == "stopped") == stopDuringAgent)
	end)
	assert(#calls == 0, "constructing an engine is lazy")
	engine.begin()
	if stopDuringAgent then
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

	-- The details read bodies only for requested changes, so a body-only bot comment review has nothing
	-- to fix or summarize: no bot action is offered. Bot threads and bot requested changes stay actionable.
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
	assert(not State.botActionable(botPr) and bodyOnly.column == "in_review" and not bodyOnly.agentSlot)
	assert(bodyOnly.main and bodyOnly.main.act == "card-copy" and #bodyOnly.more == 0)
	botPr.reviews.latest[1].verdict = "changes_requested"
	local requestedBot = botCard()
	assert(State.botActionable(botPr) and requestedBot.main and requestedBot.main.act == "card-agent")

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
	botEngine(false)
	botEngine(true)
end
