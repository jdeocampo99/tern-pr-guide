--!strict
-- Frozen lifecycle projection, key/click actions and injected lease effects. No host or network.
local AgentFix = require("../src/hub/agent-fix")
local Fields = require("../src/text-field")
local Keys = require("../src/keys")
local State = require("../src/hub/state")
local Cards: any = require("../fixtures/hub/agent-cards")
local Tree: any = require("../fixtures/hub/agent/treehouse")

local function fresh(): State.State
	return State.new(Cards.prs, Cards.asOf, nil)
end

local function card(s: State.State, key: string): State.Card
	local found = State.card(s, key)
	assert(found, key)
	return found :: State.Card
end

local function main(s: State.State, key: string, label: string?, act: string?, shortcut: string?)
	local found = card(s, key)
	assert(found.agentSlot, "space must be reserved before a run")
	if not label then assert(found.main == nil, "#16 owns the ready actions"); return end
	assert(found.main and found.main.label == label and found.main.act == act and found.main.key == shortcut)
	State.select(s, key)
	local pressed = Keys.hubAction(s, { name = string.lower(shortcut :: string) } :: any)
	assert(pressed and pressed.act == act and pressed.value == key, "button and key must dispatch the same ACTIONS entry")
end

local function begin(s: State.State, key: string)
	assert(State.beginAgent(s, key, Cards.asOf))
	assert(State.agentOutcome(s, key, { kind = "running", run = Cards.run(key) }))
end

local function finish(s: State.State, key: string)
	for _, event in Cards.events() do assert(State.agentEvent(s, key, event)) end
end

local function serializable(value: any)
	local kind = type(value)
	assert(kind ~= "function" and kind ~= "userdata" and kind ~= "thread", "State contains an effect handle")
	if kind == "table" then for _, child in value do serializable(child) end end
end

-- The real #15 engine, stopped while acquisition is pending, must capture and return the
-- exact lease. The close decision is State's; the engine and its stop hook stay outside State.
local function closingReturnsLease()
	local s, key = fresh(), Cards.keys.idle
	begin(s, key)
	local calls: { { string } } = {}
	local acquisition: ((AgentFix.Out) -> ())? = nil
	local completed, stopped = 0, 0
	local engine = AgentFix.engine(Cards.spec(key), {
		runner = function(argv, _, done)
			table.insert(calls, argv)
			if #calls == 1 then acquisition = done; return end
			assert(#calls == 2, "close must not begin Git or agent work")
			assert(#argv == #Tree["return"].argv)
			for i, word in argv do assert(word == Tree["return"].argv[i], "lease ownership guards changed") end
			done({ status = 0, stdout = "returned", stderr = "", timed_out = false })
		end,
		decode = function(text) assert(text == "acquired"); return Tree.get.reply end,
		samePath = function(_, _, done) done(false, nil) end,
		resolutions = function() error("no agent work after close") end,
	}, Cards.asOf, function(outcome)
		-- No late callback can put the closed card back into running.
		assert(not State.agentOutcome(s, key, outcome))
	end, function(fix, err)
		completed += 1
		assert(not fix and err == "stopped")
	end)
	engine.begin()
	assert(#calls == 1 and acquisition ~= nil)
	if State.closeAgent(s) == key then stopped += 1; engine.stop() end
	assert(State.closeAgent(s) == nil and stopped == 1)
	local reply = acquisition :: (AgentFix.Out) -> ()
	reply({ status = 0, stdout = "acquired", stderr = "", timed_out = false })
	assert(#calls == 2 and completed == 1 and not engine.busy() and engine.held() == nil)
	assert(s.agents[key] == nil)
end

local function cloneFromNoClone()
	local s, key = fresh(), Cards.keys.no_clone
	State.noAgentClone(s, key, "acme/web")
	main(s, key, "Clone repo", "card-agent-clone", "A")
	local alternatives = card(s, key).more
	assert(#alternatives == 1 and alternatives[1].label == "Choose folder…" and alternatives[1].key == "O")
	local o = Keys.hubAction(s, { name = "o" } :: any)
	assert(o and o.act == alternatives[1].act and o.value == key)
	local clones, starts, remembered = 0, 0, 0
	local function lookup(cancel: boolean): AgentFix.CloneLookup
		return {
			existing = function(_, done) done(nil) end,
			tandem = function(_, done) done(nil) end,
			saved = function() return nil end,
			validate = function(path, slug, done) assert(path == "/parent/web" and slug == "acme/web"); done(true) end,
			ask = function(slug, done) assert(slug == "acme/web"); done(if cancel then nil else "/parent/web") end,
			remember = function(slug, path) assert(slug == "acme/web" and path == "/parent/web"); remembered += 1; return nil end,
			runner = function(argv, _, done)
				clones += 1
				assert(table.concat(argv, " ") == "gh repo clone acme/web /parent/web -- --filter=blob:none --no-checkout")
				done({ status = 0, stdout = "", stderr = "", timed_out = false })
			end,
		}
	end
	AgentFix.locateClone("acme/web", lookup(true), function(path)
		assert(path == nil)
		State.noAgentClone(s, key, "acme/web")
	end)
	assert(clones == 0 and remembered == 0 and s.agents[key].kind == "no_clone")
	AgentFix.locateClone("acme/web", lookup(false), function(path, err)
		assert(path == "/parent/web" and err == nil)
		if State.beginAgent(s, key, Cards.asOf) then starts += 1 end
	end)
	assert(clones == 1 and remembered == 1 and starts == 1)
	main(s, key, "Stop", "card-agent-stop", "A")
end

return function()
	local s, key = fresh(), Cards.keys.idle
	main(s, key, "Fix with agent", "card-agent", "A")
	assert(not State.beginAgent(s, "missing/repo#1", Cards.asOf))
	begin(s, key)
	main(s, key, "Stop", "card-agent-stop", "A")
	assert(card(s, key).agentMessage == "Preparing worktree…")
	-- A different card still dispatches Fix, but the pure start guard calls no second hook.
	local starts = 1
	main(s, Cards.keys.failed, "Fix with agent", "card-agent", "A")
	if State.beginAgent(s, Cards.keys.failed, Cards.asOf) then starts += 1 end
	assert(starts == 1 and s.agents[Cards.keys.failed] == nil and State.agentRunning(s) == key)
	assert(not State.beginAgent(s, key, Cards.asOf))
	finish(s, key)
	main(s, key, nil, nil, nil)
	local ready = s.agents[key]
	assert(ready and ready.kind == "ready")
	if ready and ready.kind == "ready" then
		assert(ready.fix.commit == string.rep("b", 40) and ready.fix.worktree == "/pool/acme/web/wt-1")
		assert(#ready.fix.hunks == 2 and ready.fix.hunks[1].resolved and ready.fix.hunks[2].resolved)
		assert(not State.reviewed(ready.fix, {}) and not State.reviewed(ready.fix, { h1 = true }))
		assert(State.reviewed(ready.fix, { h1 = true, h2 = true }))
		local clean = table.clone(ready.fix)
		clean.hunks = {}
		assert(State.reviewed(clean, {}), "a clean merge needs no conflict review")
	end
	assert(card(s, key).agentCommit == "bbbbbbb" and card(s, key).agentPath == "/pool/acme/web/wt-1")
	assert(string.find(card(s, key).agentMessage :: string, "bbbbbbb", 1, true))
	assert(card(s, key).chips[1].text == "Fix ready" and card(s, key).chips[1].kind == "done")
	assert(not State.agentEvent(s, key, { kind = "failed", reason = "late failure" }))
	assert(not State.beginAgent(s, key, Cards.asOf) and State.closeAgent(s) == nil)
	assert(s.agents[key] == ready, "close must keep the ready fix and reviewed set")
	serializable(s.agents)

	s = fresh()
	begin(s, key)
	assert(State.agentEvent(s, key, Cards.events()[2]))
	assert(card(s, key).agentMessage == "Merging base branch…" and card(s, key).agentPath == "/pool/acme/web/wt-1")
	assert(State.agentEvent(s, key, { kind = "failed", reason = "Couldn't run agent: model unavailable\nsecond line" }))
	main(s, key, "Try again", "card-agent-retry", "A")
	assert(card(s, key).agentMessage == "Couldn't fix pull request: model unavailable")
	assert(card(s, key).more[1].label == "Open worktree" and card(s, key).more[1].key == "O")
	local open = Keys.hubAction(s, { name = "o" } :: any)
	assert(open and open.act == "card-agent-worktree" and open.value == key)
	assert(not State.agentEvent(s, key, { kind = "stopped" }), "duplicate completion must not erase a failure")
	begin(s, key)
	main(s, key, "Stop", "card-agent-stop", "A")
	finish(s, key)
	main(s, key, nil, nil, nil)
	s = fresh()
	begin(s, key)
	assert(State.agentEvent(s, key, { kind = "stopped" }))
	main(s, key, "Fix with agent", "card-agent", "A")
	assert(not State.agentEvent(s, key, Cards.events()[2]), "late worktree event must not resurrect Stop")
	State.agentFailed(s, key, "No worktree was available", nil)
	main(s, key, "Try again", "card-agent-retry", "A")
	assert(#card(s, key).more == 0 and Keys.hubAction(s, { name = "o" } :: any) == nil)
	s.search = Fields.create("web")
	assert(Keys.hubAction(s, { name = "a" } :: any) == nil and Keys.hubAction(s, { name = "j" } :: any) == nil)
	s.search = Fields.create("")
	s.link = Fields.create("acme/web#1801")
	assert(Keys.hubAction(s, { name = "a" } :: any) == nil and Keys.hubAction(s, { name = "o" } :: any) == nil)
	s.link = Fields.create("")
	State.noAgentClone(s, key, "acme/web")
	State.openFixes(s, key)
	local folder = Keys.hubAction(s, { name = "o" } :: any)
	-- The fixes page offers the same card alternatives as the board.
	assert(folder and folder.act == "card-agent-folder" and folder.value == key)
	State.closeFixes(s)
	cloneFromNoClone()
	closingReturnsLease()

	local fixture = fresh()
	for fixtureKey, agent in Cards.agents do fixture.agents[fixtureKey] = agent end
	State.project(fixture)
	main(fixture, Cards.keys.running, "Stop", "card-agent-stop", "A")
	assert(card(fixture, Cards.keys.running).agentMessage == "Resolving conflicts…" and card(fixture, Cards.keys.running).chips[1].kind == "agent")
	main(fixture, Cards.keys.ready, nil, nil, nil)
	main(fixture, Cards.keys.failed, "Try again", "card-agent-retry", "A")
	main(fixture, Cards.keys.no_clone, "Clone repo", "card-agent-clone", "A")
	serializable(fixture.agents)
end
