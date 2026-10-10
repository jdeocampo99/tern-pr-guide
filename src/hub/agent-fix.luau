--!strict
-- The agent fix's pure transitions and injected effect pipeline. No host, clock or I/O access.
export type LineTag = "base" | "ours" | "theirs" | "agent"
export type ResolvedLine = { tag: LineTag, text: string }
export type ConflictHunk = {
 id: string, path: string, start: number,
 base: { string }, ours: { string }, theirs: { string },
 context: { before: { string }, after: { string } },
 subjects: { ours: { string }, theirs: { string } },
 resolved: { by: "rule" | "agent", lines: { ResolvedLine } }?,
}
export type Stage = "worktree" | "merge" | "rules" | "agent" | "commit"
export type Run = { key: string, stage: Stage, since: number, worktree: string?, hunks: { ConflictHunk }, left: number }
export type Fix = {
 worktree: string, branch: string, base: string, headOid: string,
 commit: string, hunks: { ConflictHunk }, summary: string, usedAgent: boolean,
}
export type Event =
 { kind: "stage", stage: Stage } | { kind: "worktree", path: string }
 | { kind: "hunks", hunks: { ConflictHunk } }
 | { kind: "resolved", id: string, by: "rule" | "agent", lines: { ResolvedLine } }
 | { kind: "committed", commit: string, summary: string }
 | { kind: "failed", reason: string } | { kind: "stopped" }
export type Outcome =
 { kind: "running", run: Run } | { kind: "ready", fix: Fix }
 | { kind: "failed", reason: string, worktree: string? } | { kind: "stopped" }

-- Binding supplies the metadata omitted from Run and Event in the shared contract.
export type Spec = {
 key: string, clone: string, checkout: string, pool: string, branch: string, base: string,
 headOid: string, number: number, tool: string, omp: string, model: string, effort: string?,
 -- Generated files need a repository-specific, explicitly supplied regeneration command.
 regenerate: { [string]: { string } }?,
}
type BoundRun = Run & { spec: Spec?, usedAgent: boolean? }
export type Out = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Runner = (argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (Out) -> ()) -> ()
export type Lease = { path: string, id: string, holder: string }
export type Dependencies = {
 runner: Runner, decode: (string) -> any,
 samePath: (string, string, (boolean?, string?) -> ()) -> (),
 resolutions: (string, ({ { id: string, lines: { ResolvedLine } } }?, string?) -> ()) -> (),
}
export type Engine = {
 stop: () -> (),
 -- Called by the later Push or Discard action after its own operation completes. Never pushes.
 release: ((boolean?, string?) -> ()) -> (),
 begin: () -> (),
 held: () -> Lease?,
 busy: () -> boolean,
}

local M = {}
local LOCKFILES: { [string]: boolean } = {
 ["package-lock.json"] = true, ["npm-shrinkwrap.json"] = true, ["yarn.lock"] = true, ["pnpm-lock.yaml"] = true,
 ["bun.lock"] = true, ["bun.lockb"] = true, ["deno.lock"] = true, ["Cargo.lock"] = true, ["Gemfile.lock"] = true,
 ["poetry.lock"] = true, ["Pipfile.lock"] = true, ["uv.lock"] = true, ["composer.lock"] = true, ["go.sum"] = true,
 ["flake.lock"] = true, ["Package.resolved"] = true, ["mix.lock"] = true, ["pubspec.lock"] = true, ["packages.lock.json"] = true,
}
-- Version-dependent formats and files whose entrypoints cannot be inferred require an override:
-- yarn.lock, bun.lockb, deno.lock, Package.resolved, and arbitrary linguist-generated files.
local REGENERATE: { [string]: { string } } = {
 ["package-lock.json"] = { "npm", "install", "--package-lock-only", "--ignore-scripts" },
 ["npm-shrinkwrap.json"] = { "npm", "install", "--package-lock-only", "--ignore-scripts" },
 ["pnpm-lock.yaml"] = { "pnpm", "install", "--lockfile-only", "--ignore-scripts" },
 ["bun.lock"] = { "bun", "install", "--lockfile-only", "--ignore-scripts" },
 ["Cargo.lock"] = { "cargo", "generate-lockfile" },
 ["Gemfile.lock"] = { "bundle", "lock" }, ["poetry.lock"] = { "poetry", "lock" },
 ["Pipfile.lock"] = { "pipenv", "lock" }, ["uv.lock"] = { "uv", "lock" },
 ["composer.lock"] = { "composer", "update", "--no-install", "--no-scripts" },
 ["go.sum"] = { "go", "mod", "tidy" }, ["flake.lock"] = { "nix", "flake", "lock" },
 ["mix.lock"] = { "mix", "deps.get" },
 ["pubspec.lock"] = { "dart", "pub", "get" }, ["packages.lock.json"] = { "dotnet", "restore", "--use-lock-file" },
}

function M.isLockfile(path: string): boolean
 return LOCKFILES[string.match(path, "[^/]+$") or ""] == true
end

function M.regeneration(path: string): { string }?
 local argv = REGENERATE[string.match(path, "[^/]+$") or ""]
 return if argv then table.clone(argv) else nil
end

function M.start(key: string, now: number): Run
 return { key = key, stage = "worktree", since = now, hunks = {}, left = 0 }
end

function M.bind(run: Run, spec: Spec): Run
 local next: BoundRun = table.clone(run) :: BoundRun
 next.spec = table.clone(spec)
 return next
end

function M.step(run: Run, event: Event): Outcome
 if event.kind == "failed" then return { kind = "failed", reason = event.reason, worktree = run.worktree } end
 if event.kind == "stopped" then return { kind = "stopped" } end
 local next: BoundRun = table.clone(run) :: BoundRun
 next.hunks = table.clone(run.hunks)
 if event.kind == "stage" then
  next.stage = event.stage
  if event.stage == "agent" then next.usedAgent = true end
 elseif event.kind == "worktree" then
  next.worktree, next.stage = event.path, "merge"
 elseif event.kind == "hunks" then
  next.hunks = {}
  next.left = 0
  for _, hunk in event.hunks do
   table.insert(next.hunks, table.clone(hunk))
   if not hunk.resolved then next.left += 1 end
  end
 elseif event.kind == "resolved" then
  for i, hunk in next.hunks do
   if hunk.id == event.id and not hunk.resolved then
    local resolved = table.clone(hunk)
    local lines = {}
    for _, line in event.lines do table.insert(lines, table.clone(line)) end
    resolved.resolved = { by = event.by, lines = lines }
    next.hunks[i] = resolved
    next.left -= 1
    if event.by == "agent" then next.usedAgent = true end
    break
   end
  end
 elseif event.kind == "committed" then
  local spec = next.spec
  if not next.worktree or not spec or next.left ~= 0 or next.stage ~= "commit" then
   return { kind = "failed", reason = "Fix metadata or resolved hunks are missing", worktree = next.worktree }
  end
  return { kind = "ready", fix = {
   worktree = next.worktree, branch = spec.branch, base = spec.base, headOid = spec.headOid,
   commit = event.commit, hunks = next.hunks, summary = event.summary, usedAgent = next.usedAgent == true,
  } }
 end
 return { kind = "running", run = next }
end

function M.acquire(pool: string): { string }
 return { "treehouse", "--root", pool, "get", "--lease", "--lease-holder", "prguide", "--no-fetch", "--json" }
end

function M.returnLease(pool: string, lease: Lease): { string }
 return { "treehouse", "--root", pool, "return", lease.path, "--if-lease-holder", "prguide", "--if-lease-id", lease.id }
end

function M.clone(slug: string, destination: string): { string }
 return { "gh", "repo", "clone", slug, destination, "--", "--filter=blob:none", "--no-checkout" }
end

function M.prompt(tool: string): string
 return "Resolve the remaining merge conflicts in this worktree. Use only " .. tool ..
  " list, show <id>, take <id> ours|theirs|both, write <id> (stdin), and check for conflict content. " ..
  "Read hunks only through show, never read a whole file. Preserve the branch's intent and base changes. " ..
  "Do not fetch, commit, push, reset, switch branches, abort the merge, or start other agents. " ..
  "Do not change files except through this tool. Stop after check reports remaining=0. " ..
  "Output a short plain summary. The host validates and commits the result."
end

-- A caller supplies all effects. Stop waits for the current process to finish before returning
-- the lease, so no worker can write into a newly re-leased tree. Failed returns retain the lease
-- and release can retry. A ready fix retains its lease until the later Push/Discard calls release.
function M.engine(spec: Spec, deps: Dependencies, now: number, changed: (Outcome) -> (), done: (Fix?, string?) -> ()): Engine
 spec = table.clone(spec)
 local state = M.bind(M.start(spec.key, now), spec)
 local lease: Lease? = nil
 local begun, stopped, finished, pending, releasing = false, false, false, false, false
 local ready: Fix? = nil
 local agentSummary: string? = nil
 local reconciling, terminating = false, false
 local originalHead: string? = nil
 local touched = false
 local returnWaiters: { (boolean?, string?) -> () } = {}
 local finish: (Fix?, string?) -> ()
 local fail: (string) -> ()
 local release: ((boolean?, string?) -> ()) -> ()
 finish = function(fix, err)
  if finished then return end
  finished = true
  done(fix, err)
 end
 release = function(callback)
  if pending or (begun and not finished and not terminating) then return callback(nil, "The agent process is still running") end
  if reconciling then return callback(nil, "The worktree lease needs reconciliation") end
  if not lease then return callback(true, nil) end
  table.insert(returnWaiters, callback)
  if releasing then return end
  releasing = true
  local held = lease :: Lease
  local called = false
  local function settled(out: Out)
   if called then return end
   called = true
   releasing = false
   local err = if out.status == 0 and not out.timed_out then nil else "Couldn't return the worktree lease: " .. string.sub(out.stderr, 1, 240)
   if not err then lease = nil end
   local waiting = returnWaiters
   returnWaiters = {}
   for _, waiter in waiting do waiter(if err then nil else true, err) end
  end
  local function effect(argv: { string }, cwd: string, nextEffect: () -> ())
   local replied = false
   local function reply(out: Out)
    if replied then return end
    replied = true
    if out.status ~= 0 or out.timed_out then return settled(out) end
    nextEffect()
   end
   local ok, err = pcall(deps.runner, argv, { cwd = cwd, timeout_ms = 60_000 }, reply)
   if not ok then reply({ status = -1, stdout = "", stderr = tostring(err), timed_out = false }) end
  end
  local function giveBack()
   effect(M.returnLease(spec.pool, held), spec.clone, function()
    settled({ status = 0, stdout = "", stderr = "", timed_out = false })
   end)
  end
  if touched and originalHead then
   -- Only a proven-clean, acquired worktree is cleaned, after its child has stopped. Ready
   -- callers release after Push or confirmed Discard; the fix commit is no longer needed here.
   effect({ "git", "--literal-pathspecs", "-C", held.path, "reset", "--hard", originalHead }, held.path, function()
    effect({ "git", "--literal-pathspecs", "-C", held.path, "clean", "-fd" }, held.path, giveBack)
   end)
  else
   giveBack()
  end
 end
 local function emit(event: Event)
  local outcome = M.step(state, event)
  if outcome.kind == "running" then state = outcome.run end
  changed(outcome)
 end
 local function stopNow()
  terminating = true
  release(function(_, err)
   if err then emit({ kind = "failed", reason = err }) else emit({ kind = "stopped" }) end
   finish(nil, err or "stopped")
  end)
 end
 fail = function(reason)
  terminating = true
  release(function(_, err)
   local why = reason .. (if err then "; " .. err else "")
   emit({ kind = "failed", reason = why })
   finish(nil, why)
  end)
 end
 local function command(argv: { string }, cwd: string, acceptConflict: boolean, ok: (Out) -> (), captureAfterStop: boolean?)
  if finished then return end
  if stopped then return stopNow() end
  pending = true
  local called = false
  local function settle(out: Out)
   if called then return end
   called = true
   pending = false
   if stopped and not captureAfterStop then return stopNow() end
   if captureAfterStop and (out.timed_out or out.status ~= 0) then reconciling = true end
   if out.timed_out or (out.status ~= 0 and not (acceptConflict and out.status == 1)) then
    return fail(argv[1] .. ": " .. string.sub(out.stderr, 1, 240))
   end
   local handled, problem = pcall(ok, out)
   if not handled then fail(tostring(problem)) end
  end
  local ran, problem = pcall(deps.runner, argv, { cwd = cwd, timeout_ms = if argv[1] == spec.omp then 20 * 60_000 else 60_000 }, settle)
  if not ran then settle({ status = -1, stdout = "", stderr = tostring(problem), timed_out = false }) end
 end
 local function git(args: { string }, ok: (Out) -> (), acceptConflict: boolean?)
  local argv = { "git", "--literal-pathspecs", "-C", state.worktree :: string }
  table.move(args, 1, #args, #argv + 1, argv)
  command(argv, state.worktree :: string, acceptConflict == true, ok)
 end
 local function tool(args: { string }, ok: (any) -> (), acceptConflict: boolean?)
  local argv = { spec.tool }
  table.move(args, 1, #args, 2, argv)
  command(argv, state.worktree :: string, acceptConflict == true, function(out) ok(deps.decode(out.stdout)) end)
 end
 local regenerations: { { path: string, argv: { string } } } = {}
 local function regenerate(doneRules: () -> ())
  local index = 0
  local function nextRule()
   index += 1
   local rule = regenerations[index]
   if not rule then return doneRules() end
   local folder = string.match(rule.path, "^(.*)/[^/]+$")
   local cwd = (state.worktree :: string) .. (if folder then "/" .. folder else "")
   command(rule.argv, cwd, false, function()
    git({ "add", "--", rule.path }, function() nextRule() end)
   end)
  end
  nextRule()
 end
 local function commit()
  -- Resolve source hunks before regeneration: package manifests can themselves conflict.
  regenerate(function()
  tool({ "check" }, function(check)
   if check.remaining ~= 0 then return fail("Conflicts remain after the agent finished") end
   emit({ kind = "stage", stage = "commit" })
   git({ "diff", "--name-only", "--diff-filter=U" }, function(unmerged)
    if string.find(unmerged.stdout, "%S") then return fail("The Git index still has unresolved files") end
    git({ "add", "-u" }, function()
     git({ "rev-parse", "-q", "--verify", "MERGE_HEAD" }, function(merge)
      local function committed()
       git({ "rev-parse", "HEAD" }, function(head)
        git({ "log", "-1", "--format=%s" }, function(summary)
         local outcome = M.step(state, { kind = "committed", commit = string.gsub(head.stdout, "%s+$", ""), summary = agentSummary or string.sub(string.gsub(summary.stdout, "%s+$", ""), 1, 240) })
         changed(outcome)
         if outcome.kind ~= "ready" then return fail("The fix could not be committed") end
         ready = outcome.fix
         finish(ready, nil)
        end)
       end)
      end
      if merge.status == 1 then return committed() end
      git({ "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--no-verify", "-m", "Merge " .. spec.base .. " and resolve conflicts" }, committed)
     end, true)
    end)
   end)
  end, true)
  end)
 end
 local function journal(by: "rule" | "agent", after: () -> ())
  pending = true
  local called = false
  local function resolved(rows: { { id: string, lines: { ResolvedLine } } }?, err: string?)
   if called then return end
   called = true
   pending = false
   if stopped then return stopNow() end
   if not rows then return fail(err or "Couldn't read the conflict resolutions") end
   for _, row in rows do emit({ kind = "resolved", id = row.id, by = by, lines = row.lines }) end
   after()
  end
  local ok, err = pcall(deps.resolutions, state.worktree :: string, resolved)
  if not ok then resolved(nil, tostring(err)) end
 end
 local function agent()
  tool({ "list" }, function(list)
   if #list.hunks == 0 then return commit() end
   emit({ kind = "stage", stage = "agent" })
   local argv = { spec.omp, "-p", "--model", spec.model }
   if spec.effort then table.insert(argv, "--thinking"); table.insert(argv, spec.effort) end
   table.insert(argv, M.prompt(spec.tool))
   command(argv, state.worktree :: string, false, function(out)
    agentSummary = string.sub(string.match(out.stdout, "%S[^\r\n]*") or "Resolve merge conflicts", 1, 240)
    journal("agent", commit)
   end)
  end)
 end
 local function rules(generated: { string })
  emit({ kind = "stage", stage = "rules" })
  local index = 0
  local function nextFile()
   index += 1
   local path = generated[index]
   if not path then
    if #generated > 0 then return journal("rule", agent) end
    return agent()
   end
   local argv = if spec.regenerate and spec.regenerate[path] then spec.regenerate[path] else M.regeneration(path)
   if not argv then return fail("No regeneration command is configured for " .. path) end
   table.insert(regenerations, { path = path, argv = argv })
   local hunkIndex = 0
   local function take()
    hunkIndex += 1
    local hunk = state.hunks[hunkIndex]
    if hunk then
     if hunk.path ~= path then return take() end
     return tool({ "take", hunk.id, "theirs" }, function() take() end)
    end
    -- Whole generated files take the base side, including binary lockfiles. The journal keeps
    -- full selected hunk lines, while show stays bounded. Regeneration follows source resolution.
    git({ "-c", "core.hooksPath=/dev/null", "checkout", "--theirs", "--", path }, function()
     git({ "add", "--", path }, function() nextFile() end)
    end)
   end
   take()
  end
  nextFile()
 end
 local function merged()
  tool({ "list" }, function(list)
   local hunks: { ConflictHunk } = {}
   local index = 0
   local function show()
    index += 1
    local row = list.hunks[index]
    if not row then emit({ kind = "hunks", hunks = hunks }); return rules(list.generated) end
    tool({ "show", row.id }, function(hunk)
     table.insert(hunks, hunk)
     show()
    end)
   end
   show()
  end)
 end
 local function merge()
  git({ "status", "--porcelain" }, function(status)
   if string.find(status.stdout, "%S") then return fail("The acquired worktree is not clean") end
   git({ "rev-parse", "HEAD" }, function(initial)
    originalHead = string.gsub(initial.stdout, "%s+$", "")
    if not string.match(originalHead, "^%x+$") then return fail("The acquired worktree has no starting commit") end
   git({ "fetch", "--no-tags", "origin", "+refs/pull/" .. spec.number .. "/head:refs/prguide/agent/head", "+refs/heads/" .. spec.base .. ":refs/remotes/origin/" .. spec.base }, function()
    git({ "rev-parse", "refs/prguide/agent/head" }, function(head)
     if string.gsub(head.stdout, "%s+$", "") ~= spec.headOid then return fail("The PR head moved before the fix started") end
     touched = true
     git({ "-c", "core.hooksPath=/dev/null", "switch", "--detach", spec.headOid }, function()
      emit({ kind = "stage", stage = "merge" })
      git({ "-c", "core.hooksPath=/dev/null", "-c", "rerere.enabled=true", "-c", "rerere.autoupdate=true", "-c", "merge.conflictStyle=diff3", "merge", "--no-commit", "--no-ff", "origin/" .. spec.base }, function(out)
       if out.status == 0 then return merged() end
       git({ "rev-parse", "-q", "--verify", "MERGE_HEAD" }, function(merging)
        if merging.status ~= 0 then return fail("Git failed before starting a merge") end
        merged()
       end, true)
      end, true)
     end)
    end)
   end)
   end)
  end)
 end
 local function begin()
  if begun then return end
  begun = true
  if stopped then return stopNow() end
  command(M.acquire(spec.pool), spec.clone, false, function(out)
   reconciling = true
   local raw = deps.decode(out.stdout)
   if type(raw) ~= "table" or type(raw.path) ~= "string" or string.sub(raw.path, 1, 1) ~= "/" or type(raw.lease_id) ~= "string" or raw.lease_id == "" or raw.lease_holder ~= "prguide" then
    return fail("Treehouse returned invalid lease metadata; the lease needs reconciliation")
   end
   lease = { path = raw.path, id = raw.lease_id, holder = raw.lease_holder }
   -- Even an acquisition that completes after Stop must first capture its lease.
   pending = true
   local checked = false
   local function identity(same: boolean?, err: string?)
    if checked then return end
    checked = true
    pending = false
    if same ~= false then
     -- Never return a path that might be the reader's checkout. Preserve it for reconciliation.
     lease = nil
     emit({ kind = "failed", reason = err or "Treehouse returned the reader's checkout" })
     return finish(nil, err or "Treehouse returned the reader's checkout; lease needs reconciliation")
    end
    reconciling = false
    emit({ kind = "worktree", path = raw.path })
    if stopped then return stopNow() end
    merge()
   end
   local ok, err = pcall(deps.samePath, raw.path, spec.checkout, identity)
   if not ok then identity(nil, tostring(err)) end
  end, true)
 end
 return {
  begin = begin,
  held = function() return if lease then table.clone(lease) else nil end,
  busy = function() return not finished or lease ~= nil or reconciling or pending or releasing end,
  release = release,
  stop = function()
   stopped = true
   if not pending and not releasing then
    if ready then release(function(_, err) if err then changed({ kind = "failed", reason = err, worktree = ready.worktree }) end end)
    elseif not finished then stopNow() end
   end
  end,
 }
end

export type CloneLookup = {
 existing: (string, (string?) -> ()) -> (),
 tandem: (string, (string?) -> ()) -> (),
 saved: (string) -> string?,
 validate: (string, string, (boolean) -> ()) -> (),
 ask: (string, (string?) -> ()) -> (),
 remember: (string, string) -> string?,
 runner: Runner,
}

-- Existing checkout or ready saved copy, then Tandem, then hub.clones. The injected question
-- selects an absent clone destination, or cancels; no dialog or kv access belongs in this module.
function M.locateClone(slug: string, lookup: CloneLookup, done: (string?, string?) -> ())
 local completed = false
 local function finish(path: string?, err: string?)
  if completed then return end
  completed = true
  done(path, err)
 end
 if not string.match(slug, "^%w[%w._-]*/%w[%w._-]*$") then return finish(nil, "Invalid repository name") end
 local function clone()
  local answered = false
  lookup.ask(slug, function(destination)
   if answered then return end
   answered = true
   if not destination or destination == "" then return finish(nil, "No clone folder was selected") end
   local called = false
   local function cloned(out: Out)
    if called then return end
    called = true
    if out.status ~= 0 or out.timed_out then return finish(nil, "Couldn't clone " .. slug .. ": " .. string.sub(out.stderr, 1, 240)) end
    lookup.validate(destination, slug, function(valid)
     if not valid then return finish(nil, "The new clone's origin does not match " .. slug) end
     local err = lookup.remember(slug, destination)
     if err then return finish(nil, err) end
     finish(destination, nil)
    end)
   end
   local ok, err = pcall(lookup.runner, M.clone(slug, destination), { timeout_ms = 20 * 60_000 }, cloned)
   if not ok then cloned({ status = -1, stdout = "", stderr = tostring(err), timed_out = false }) end
  end)
 end
 local function saved()
  local path = lookup.saved(slug)
  if not path then return clone() end
  lookup.validate(path, slug, function(valid)
   if valid then finish(path, nil) else clone() end
  end)
 end
 lookup.existing(slug, function(path)
  if path then return finish(path, nil) end
  lookup.tandem(slug, function(found)
   if not found then return saved() end
   lookup.validate(found, slug, function(valid)
    if valid then finish(found, nil) else saved() end
   end)
  end)
 end)
end

return M
