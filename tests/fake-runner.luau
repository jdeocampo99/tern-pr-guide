--!strict
-- A scripted `Github.Runner`. Each entry matches an argv prefix (and, optionally, text anywhere in
-- the argv) and returns a canned `Out`. Every call's argv, stdin and cwd is recorded. A call no
-- entry matches is recorded in `unmatched` and throws, so a test that must run nothing else ends
-- with `expectOnly`.
local Github = require("../src/github")

export type Reply = { status: number?, stdout: string?, stderr: string?, timed_out: boolean? }
export type Entry = { prefix: { string }, contains: string?, reply: Reply }
export type Call = { argv: { string }, stdin: string?, cwd: string?, timeout_ms: number? }
export type Fake = {
	run: Github.Runner,
	calls: { Call },
	unmatched: { { string } },
	-- Asserts that exactly `count` calls ran and every one matched an entry.
	expectOnly: (count: number) -> (),
}

local M = {}

local function matches(entry: Entry, argv: { string }): boolean
	for i, word in entry.prefix do
		if argv[i] ~= word then return false end
	end
	return entry.contains == nil or string.find(table.concat(argv, " "), entry.contains, 1, true) ~= nil
end

function M.new(script: { Entry }): Fake
	local calls: { Call } = {}
	local unmatched: { { string } } = {}
	local function run(argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Github.Out) -> ())
		table.insert(calls, { argv = table.clone(argv), stdin = opts.stdin, cwd = opts.cwd, timeout_ms = opts.timeout_ms })
		for _, entry in script do
			if matches(entry, argv) then
				local reply = entry.reply
				done({
					status = reply.status or 0, stdout = reply.stdout or "", stderr = reply.stderr or "",
					timed_out = reply.timed_out or false,
				})
				return
			end
		end
		table.insert(unmatched, table.clone(argv))
		error("fake runner: no script entry for: " .. table.concat(argv, " "), 0)
	end
	local function expectOnly(count: number)
		assert(#unmatched == 0, "fake runner: unmatched call: " .. table.concat(unmatched[1] or {}, " "))
		assert(#calls == count, "fake runner: expected " .. count .. " call(s), got " .. #calls)
	end
	return { run = run, calls = calls, unmatched = unmatched, expectOnly = expectOnly }
end

return M
