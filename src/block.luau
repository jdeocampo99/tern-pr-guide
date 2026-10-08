--!strict
-- The review page block: lets the reader pick a PR from a checkout, opens the PR its arguments name
-- (or the bundled sample), draws the page, and turns clicks and keys into state changes plus the
-- scrolling, focusing and animation timing only a live window can do.
local Agent = require("./agent")
local Diff = require("./diff")
local Fetch = require("./fetch")
local Fields = require("./text-field")
local Guide = require("./guide")
local Keys = require("./keys")
local Notice = require("./view/notice")
local Page = require("./view/page")
local Picker = require("./picker")
local PickerView = require("./view/picker")
local Pr = require("./pr")
local Review = require("./review")
local State = require("./state")

type State = State.State
type Handler = (s: State, cx: BlockCx, value: string) -> ()

-- How the block was opened: a PR and its checkout, a directory to pick a PR from (empty when the
-- palette command knew none), or neither for the bundled sample.
type Options = { pr: string?, repo: string?, guide: string?, post: boolean }

-- The review page once its PR has loaded; before that, the PR picker or what loading is doing.
type Block = {
 opts: Options,
 -- The PR as the reader named it ("#350"), for the title and the loading page.
 name: string,
 repo: Fetch.Repo?,
 picker: Picker.Picker?,
 notice: Notice.Notice,
 page: State?,
 -- The page shows a guide file rather than the default walkthrough.
 guided: boolean,
 -- The reader's AI agent, once found, and its run writing a guide.
 ai: Agent.Run?,
}

local ARGS = "repo=<directory> to pick a PR, or pr=<number or URL> with repo=<checkout path>, optionally guide=<file> and post=true"
local SAMPLE_GUIDE = "fixtures/guide-350.json"

-- How long a fresh tick shows on still-open code before the code folds.
local TICK_HOLD_MS = 380
-- The closing animations in guide.css last 180-200 ms.
local CLOSE_MS = 190

-- Sends frame ops after the render that draws their targets. A target the render dropped makes
-- the frame fail, which leaves nothing to do.
local function frameLater(cx: BlockCx, ops: { any })
 tern.timer(1, function()
  pcall(function() cx:frame(ops) end)
 end)
end

-- Moves straight to `path` and flashes the block `flashKey`, so the jump reads as intended. Tern's
-- reveal cannot animate and a glide faked from line scrolls stuttered.
local function jump(s: State, cx: BlockCx, path: string, align: string, flashKey: string?)
 s.flash, s.flashCount = flashKey, s.flashCount + 1
 frameLater(cx, { { "reveal", path, align } })
end

-- Explicit jumps (clicking a step, file, or diagram box) land the block at the top; j/k only scroll
-- when the next block is off screen, and only as far as needed. Both flash the block landed on.
local function follow(s: State, cx: BlockCx, explicit: boolean)
 local key = State.currentStep(s).key
 jump(s, cx, Page.blockPath(key), if explicit then "start" else "nearest", key)
end

-- Plays the closing animation of `ids`, then applies the change that removes them.
local function closeAfter(s: State, cx: BlockCx, ids: { string }, apply: () -> ())
 for _, id in ids do s.closing[id] = true end
 cx:render()
 tern.timer(CLOSE_MS, function()
  for _, id in ids do s.closing[id] = nil end
  apply()
  cx:render()
 end)
end

-- Marks the steps `keys` reviewed or, when all already are, unmarks them. Marking plays out in
-- order so the move is legible: the tick lands with the code still open, then the code folds, the
-- next step slides up into its place, and the change card points at the next unreviewed step.
local function markSteps(s: State, cx: BlockCx, keys: { string })
 if s.marking then return end
 local r = s.review
 if Review.allReviewed(r, keys) then
  Review.unmark(r, keys)
  for _, key in keys do s.peek[key] = nil end
  return
 end
 local last = Review.lastStep(r, keys)
 local fresh = Review.mark(r, keys)
 local ids = {}
 for _, key in fresh do
  s.peek[key] = true
  table.insert(ids, "block:" .. key)
 end
 s.marking = true
 cx:render()
 tern.timer(TICK_HOLD_MS, function()
  closeAfter(s, cx, ids, function()
   for _, key in fresh do State.setOpen(s, key, false) end
   s.marking = false
   if last > 0 then Review.advance(r, last) end
  end)
 end)
end

local function markFile(s: State, cx: BlockCx, path: string)
 local r = s.review
 local keys = Review.keysOfFile(r, path)
 if #keys > 0 then
  markSteps(s, cx, keys)
 elseif r.filesViewed[path] then
  r.filesViewed[path] = nil
 elseif s.fileOpen[path] then
  closeAfter(s, cx, { "file:" .. path }, function()
   State.setOpen(s, State.supportingBlock(path), false)
   r.filesViewed[path] = true
  end)
 else
  r.filesViewed[path] = true
 end
end

-- Marks every supporting file reviewed, folding the open ones, or unmarks them all when all are.
local function markSupporting(s: State, cx: BlockCx)
 local r = s.review
 local files = Review.supportingFiles(r)
 local all = true
 for _, file in files do
  if not r.filesViewed[file.path] then all = false end
 end
 if all then
  for _, file in files do r.filesViewed[file.path] = nil end
  return
 end
 local ids = {}
 for _, file in files do
  if s.supportingOpen and s.fileOpen[file.path] then table.insert(ids, "file:" .. file.path) end
 end
 closeAfter(s, cx, ids, function()
  for _, file in files do
   r.filesViewed[file.path] = true
   State.setOpen(s, State.supportingBlock(file.path), false)
  end
 end)
end

local function toggleHelp(s: State, cx: BlockCx)
 if s.helpOpen then closeAfter(s, cx, { "help" }, function() s.helpOpen = false end) else s.helpOpen = true end
end

local function closeReview(s: State, cx: BlockCx)
 closeAfter(s, cx, { "review" }, function() s.reviewOpen = false end)
end

local function gotoSuggestion(s: State, cx: BlockCx, id: string)
 local r = s.review
 local comment = Review.suggestion(r, id)
 local i = if comment then Review.stepShowing(r, comment.file, comment.line) else nil
 if not i then return end
 State.visitStep(s, i)
 r.focus = id
 jump(s, cx, Page.suggestionPath(r.steps[i].key, id), "start", nil)
end

local function gotoOwn(s: State, cx: BlockCx, n: number)
 local r = s.review
 local own = r.own[n]
 local i = if own then Review.stepShowing(r, own.file, own.to) else nil
 if not i then return end
 r.cur = i
 follow(s, cx, true)
end

local function stepSuggestion(s: State, cx: BlockCx, delta: number)
 local r = s.review
 local order = Review.suggestionOrder(r)
 if #order == 0 then return end
 local at = (if r.focus then table.find(order, r.focus) else nil) or (if delta > 0 then 0 else #order + 1)
 gotoSuggestion(s, cx, order[math.clamp(at + delta, 1, #order)])
end

-- Takes you to a search result: a step, a comment, a file's first block, or one changed line,
-- opening whatever hides it and marking the line.
local function searchGo(s: State, cx: BlockCx, n: number)
 local result = (s.search :: State.SearchBox).results[n]
 if not result then return end
 s.search = nil
 local go = result.go
 if go.step then
  s.review.cur = go.step
  follow(s, cx, true)
 elseif go.suggestion then
  gotoSuggestion(s, cx, go.suggestion)
 elseif go.own then
  gotoOwn(s, cx, go.own)
 elseif go.file then
  local blockId, isStep = State.showFile(s, go.file, go.entry)
  local path = if go.entry then Page.linePath(blockId, go.entry) else Page.blockPath(blockId)
  jump(s, cx, path, "start", if isStep then blockId else nil)
 end
end

local function openComposer(s: State, cx: BlockCx, file: string, from: number, to: number)
 local blockId = State.openComposer(s, file, from, to)
 cx:render()
 frameLater(cx, { { "reveal", Page.composerPath(blockId), "nearest" }, { "focus", Page.composerFieldPath(blockId) } })
end

local function commentClick(s: State, cx: BlockCx, file: string, line: number)
 local from, to, extends = State.commentRange(s, file, line)
 if not extends then s.composer = nil end
 if from and to then openComposer(s, cx, file, from, to) end
end

local function editSummary(s: State, cx: BlockCx)
 s.editingSummary = true
 frameLater(cx, { { "focus", Page.summaryFieldPath } })
end

local function toggleStepBlock(s: State, cx: BlockCx, key: string)
 if State.plan(s).open[key] then
  closeAfter(s, cx, { "peek:" .. key }, function() State.setOpen(s, key, false) end)
 else
  State.setOpen(s, key, true)
 end
end

local function gotoStep(s: State, cx: BlockCx, i: number, explicit: boolean)
 s.review.cur, s.review.focus = math.clamp(i, 1, #s.review.steps), nil
 follow(s, cx, explicit)
end

-- Sends the review once: the page shows it sending, then where it went or why it didn't.
local function submit(s: State, cx: BlockCx)
 local r, out = s.review, s.submit
 s.editingSummary = false
 if r.posted or out.sending then return end
 local verdict, payload = r.verdict, Review.reviewPayload(r)
 out.sending, out.error = true, nil
 Fetch.submitReview(r.pr, payload, out, function(delivery, err)
  out.sending, out.error = false, err
  if delivery then r.posted = { verdict = verdict, payload = payload, delivery = delivery } end
  cx:render()
 end)
end

local ACTIONS: { [string]: Handler } = {
 -- reading
 ["step"] = function(s, cx, delta) gotoStep(s, cx, s.review.cur + (tonumber(delta) :: number), false) end,
 ["goto-step"] = function(s, cx, n) gotoStep(s, cx, tonumber(n) :: number, true) end,
 ["next-suggestion"] = function(s, cx, delta) stepSuggestion(s, cx, tonumber(delta) :: number) end,
 ["peek"] = toggleStepBlock,
 ["reveal"] = function(s, _, value)
  local blockId, first, last = string.match(value, "^(.*)|(%d+)|(%d+)$")
  State.reveal(s, blockId :: string, tonumber(first) :: number, tonumber(last) :: number)
 end,
 ["whole"] = function(s, _, blockId) State.toggleWhole(s, blockId) end,
 ["toggle-flow"] = function(s, cx)
  if s.flowOpen then closeAfter(s, cx, { "flow" }, function() s.flowOpen = false end) else s.flowOpen = true end
 end,
 ["toggle-group"] = function(s, cx)
  if s.supportingOpen then closeAfter(s, cx, { "group" }, function() s.supportingOpen = false end) else s.supportingOpen = true end
 end,
 ["toggle-file"] = function(s, cx, path)
  local blockId = State.supportingBlock(path)
  if State.plan(s).open[blockId] then
   closeAfter(s, cx, { "file:" .. path }, function() State.setOpen(s, blockId, false) end)
  else
   State.setOpen(s, blockId, true)
  end
 end,
 ["open-all-supporting"] = function(s) State.toggleAllSupporting(s) end,
 ["toggle-help"] = toggleHelp,
 ["dismiss"] = function(s, cx)
  s.review.focus = nil
  if s.helpOpen then toggleHelp(s, cx) end
 end,
 ["scroll"] = function(_, cx, how) cx:frame({ { "scroll", "main", how } }) end,
 ["open-github"] = function(s, cx) cx:open(s.review.pr.url) end,

 -- marking
 ["review-step"] = function(s, cx, key) markSteps(s, cx, { key }) end,
 ["mark-change"] = function(s, cx, n) markSteps(s, cx, Review.keysOfChange(s.review, tonumber(n) :: number)) end,
 ["mark-file"] = markFile,
 ["mark-supporting"] = markSupporting,

 -- suggestions and comments
 ["decide"] = function(s, _, value)
  local id, decision = string.match(value, "^(.-)|(.*)$")
  Review.decide(s.review, id :: string, if decision == "undo" then nil else decision :: Review.Decision)
 end,
 ["decide-current"] = function(s, _, decision)
  local comment = Review.currentSuggestion(s.review)
  if comment then Review.decide(s.review, comment.id, decision :: Review.Decision) end
 end,
 ["goto-suggestion"] = function(s, cx, id)
  s.reviewOpen = false
  gotoSuggestion(s, cx, id)
 end,
 ["goto-own"] = function(s, cx, n)
  s.reviewOpen = false
  gotoOwn(s, cx, tonumber(n) :: number)
 end,
 ["comment"] = function(s, cx, value)
  local file, line = string.match(value, "^(.*)|(%d+)$")
  commentClick(s, cx, file :: string, tonumber(line) :: number)
 end,
 ["comment-step"] = function(s, cx)
  local step = State.currentStep(s)
  local from, to = Diff.commentableRange(s.diffs[step.file], step.from, step.to)
  if from and to then openComposer(s, cx, step.file, from, to) end
 end,
 ["comment-save"] = function(s) State.saveComposer(s) end,
 ["comment-cancel"] = function(s) s.composer = nil end,

 -- search
 ["open-search"] = function(s, cx)
  State.openSearch(s)
  frameLater(cx, { { "focus", Page.searchFieldPath } })
 end,
 ["search-run"] = function(s) State.runSearch(s, s.search :: State.SearchBox) end,
 ["search-move"] = function(s, _, delta) State.moveSearch(s.search :: State.SearchBox, tonumber(delta) :: number) end,
 ["search-pick"] = function(s, cx) searchGo(s, cx, (s.search :: State.SearchBox).selected) end,
 ["search-go"] = function(s, cx, n) searchGo(s, cx, tonumber(n) :: number) end,
 ["search-close"] = function(s) s.search = nil end,

 -- the review
 ["open-review"] = function(s) State.openReview(s) end,
 ["toggle-review"] = function(s, cx)
  s.editingSummary = false
  if s.reviewOpen then closeReview(s, cx) else State.openReview(s) end
 end,
 ["review-move"] = function(s, cx, delta)
  local item = State.moveReviewCursor(s, tonumber(delta) :: number)
  if item then frameLater(cx, { { "reveal", Page.reviewRowPath(item), "nearest" } }) end
 end,
 ["toggle-item"] = function(s, _, n) State.toggleItem(s, tonumber(n) :: number) end,
 ["toggle-all"] = function(s) Review.toggleAll(s.review) end,
 ["verdict"] = function(s, _, id) Review.setVerdict(s.review, id) end,
 ["edit-summary"] = editSummary,
 ["done-summary"] = function(s) s.editingSummary = false end,
 ["submit-review"] = submit,
 ["open-posted"] = function(s, cx)
  local posted = s.review.posted
  if posted and posted.delivery.kind == "posted" then cx:open(posted.delivery.url) end
 end,
}

local function dispatch(s: State, cx: BlockCx, action: Keys.Action)
 local handler = ACTIONS[action.act]
 if handler then handler(s, cx, action.value or "") end
end

-- Reads `name=value` block arguments; none at all opens the bundled sample.
local function options(args: { string }): (Options?, string?)
 local given: { [string]: string } = {}
 for _, arg in args do
  local name, value = string.match(arg, "^(%a+)=(.*)$")
  if name ~= "pr" and name ~= "repo" and name ~= "guide" and name ~= "post" then
   return nil, "Unknown argument \"" .. arg .. "\". The block takes " .. ARGS .. "."
  end
  given[name :: string] = value :: string
 end
 local pr, repo = given.pr, given.repo
 if not pr and not repo then return { guide = given.guide or SAMPLE_GUIDE, post = false }, nil end
 if pr and (repo or "") == "" then return nil, "pr= needs repo=. The block takes " .. ARGS .. "." end
 return { pr = pr, repo = repo, guide = given.guide, post = given.post == "true" }, nil
end

local function nameOf(pr: string?): string
 if not pr then return "" end
 local number = string.match(pr, "^#?(%d+)$") or string.match(pr, "/pull/(%d+)")
 return if number then "#" .. number else pr
end

-- Offers the reader's agent while the page shows the default walkthrough.
local function offerAgent(b: Block)
 if b.page then b.page.ai = if b.guided then nil else b.ai end
end

-- Shows `pr` with `guide`, from a guide file when `guided`. Unless real posting was asked for,
-- submitting is a dry run.
local function showGuide(b: Block, pr: Pr.PR, guide: Guide.Guide, guided: boolean)
 local repo = if b.repo then b.repo.root else nil
 local dryRunPath = if b.opts.post and repo then nil else Fetch.dryRunPath(pr.number)
 b.page, b.guided = State.new(pr, guide, { repo = repo, dryRunPath = dryRunPath }), guided
 offerAgent(b)
end

-- Shows `pr` with the guide the options name, else the checkout's guide for it, else the default
-- walkthrough.
local function showPr(b: Block, pr: Pr.PR)
 local path = b.opts.guide
 if not path and b.repo and tern.fs.exists(Fetch.guidePath(b.repo, pr.number)) then path = Fetch.guidePath(b.repo, pr.number) end
 local guide, problem = Guide.defaultGuide(pr), nil
 if path then guide, problem = Guide.read(path, pr) end
 if not guide then
  b.notice = Notice.failed(b.name, "Couldn't use the guide " .. (path :: string) .. ": " .. (problem :: string))
  return
 end
 showGuide(b, pr, guide, path ~= nil)
end

-- Has the reader's agent write a guide for the page's PR, counting the seconds it takes, then
-- shows the PR with it, keeping the reader's own comments. One run at a time.
local function generate(b: Block, cx: BlockCx)
 local run, s, repo = b.ai, b.page, b.repo
 if not run or run.running or not s or not repo then return end
 local pr, own = s.review.pr, s.review.own
 local started = tern.now()
 local ticker: TimerHandle
 local function tick()
  run.seconds = math.floor((tern.now() - started) / 1000)
  cx:render()
  ticker = tern.timer(1000, tick)
 end
 run.running, run.seconds, run.error = true, 0, nil
 ticker = tern.timer(1000, tick)
 Fetch.generateGuide(run.agent, repo, pr, function(guide, err)
  ticker:cancel()
  run.running, run.error = false, err
  if guide then
   showGuide(b, pr, guide, true)
   local page = b.page :: State
   page.review.own = own
   cx:toast("success", "AI guided review ready")
  end
  cx:render()
 end)
end

-- Loads `pr` from the block's checkout, showing each stage, then shows it.
local function openPr(b: Block, cx: BlockCx, pr: string)
 b.picker, b.name = nil, nameOf(pr)
 Fetch.openPr({ pr = pr, repo = (b.repo :: Fetch.Repo).root }, function(stage)
  b.notice = Notice.loading(b.name, stage)
  cx:render()
 end, function(loaded, err)
  if loaded then showPr(b, loaded) else b.notice = Notice.failed(b.name, err :: string) end
  cx:render()
 end)
end

-- Shows the checkout's open PRs to pick from, with the filter field focused.
local function openPicker(b: Block, cx: BlockCx)
 local repo = b.repo :: Fetch.Repo
 local p = Picker.new(Fetch.guidedPrs(repo))
 b.picker = p
 Fetch.listPrs(repo.root, function(prs, current, err)
  p.prs, p.current, p.error, p.loadedAt = prs, current, err, os.time()
  cx:render()
 end)
 frameLater(cx, { { "focus", PickerView.fieldPath } })
end

type PickerHandler = (b: Block, p: Picker.Picker, cx: BlockCx, value: string) -> ()

local PICKER_ACTIONS: { [string]: PickerHandler } = {
 ["picker-move"] = function(_, p, cx, delta)
  Picker.move(p, tonumber(delta) :: number)
  local row = Picker.rows(p)[p.selected]
  if row then frameLater(cx, { { "reveal", PickerView.rowPath(row.pr.number), "nearest" } }) end
 end,
 ["picker-open"] = function(b, p, cx)
  local number = Picker.choice(p)
  if number then openPr(b, cx, tostring(number)) end
 end,
 ["picker-clear"] = function(_, p) p.field, p.selected = Fields.create(), 1 end,
 ["pick-pr"] = function(b, _, cx, number) openPr(b, cx, number) end,
}

local function pickerDispatch(b: Block, p: Picker.Picker, cx: BlockCx, action: Keys.Action)
 local handler = PICKER_ACTIONS[action.act]
 if handler then handler(b, p, cx, action.value or "") end
end

local function pickerKey(b: Block, p: Picker.Picker, key: Key, cx: BlockCx): boolean
 local action = Keys.pickerAction(p, key)
 if action then
  pickerDispatch(b, p, cx, action)
  return true
 end
 local before = p.field.text
 if Fields.key(p.field, key) == "ignored" then return false end
 if p.field.text ~= before then p.selected = 1 end
 return true
end

local block: BlockDef<Block> = {
 init = function(cx: BlockCx, args: { string }): Block
  local opts, problem = options(args)
  if not opts then return { opts = { post = false }, name = "", notice = Notice.failed("", problem :: string), guided = false } end
  local pr, dir = opts.pr, opts.repo
  local b: Block = { opts = opts, name = nameOf(pr), notice = if pr then Notice.loading(nameOf(pr), "") else Notice.findingRepo(), guided = false }
  if not dir then
   showPr(b, Pr.sample())
   return b
  end
  if dir == "" then
   b.notice = Notice.noRepo()
   return b
  end
  -- Starts after init returns, so each stage renders over a block that exists.
  tern.timer(0, function()
   Fetch.findAgent(function(agent)
    if not agent then return end
    b.ai = { agent = agent, running = false, seconds = 0, error = nil }
    offerAgent(b)
    cx:render()
   end)
   Fetch.findRepo(dir, function(repo, err)
    if not repo then
     b.notice = if pr then Notice.failed(b.name, err :: string) else Notice.noRepo()
    else
     b.repo = repo
     if pr then openPr(b, cx, pr) else openPicker(b, cx) end
    end
    cx:render()
   end)
  end)
  return b
 end,
 title = function(b: Block): string?
  if b.page then return "Review · #" .. b.page.review.pr.number end
  if b.picker then return "Pull requests" end
  return if b.name ~= "" then "PR " .. b.name else "PR Guide"
 end,
 view = function(b: Block): BlockView
  local s = b.page
  if not s then
   if b.picker then return { main = PickerView.view(b.picker, (b.repo :: Fetch.Repo).root) } end
   return { main = Notice.view(b.notice) }
  end
  local motion = { born = s.born, next = {}, booted = s.booted }
  local main = Page.view(s, motion)
  s.born, s.booted = motion.next, true
  return { main = main }
 end,
 event = function(b: Block, ev: UiEvent, cx: BlockCx)
  if ev.ev ~= "action" then return end
  local action = { act = ev.act, value = ev.value }
  if action.act == "generate-guide" then
   generate(b, cx)
  elseif b.page then
   dispatch(b.page, cx, action)
  elseif b.picker then
   pickerDispatch(b, b.picker, cx, action)
  end
 end,
 key = function(b: Block, key: Key, cx: BlockCx): boolean?
  if b.picker then return pickerKey(b, b.picker, key, cx) end
  local s = b.page
  if not s then return false end
  local action = Keys.action(s, key)
  if action then
   dispatch(s, cx, action)
   return true
  end
  local field = State.field(s)
  if field then
   local next = Keys.afterTyping(State.mode(s), Fields.key(field, key))
   if next then dispatch(s, cx, next) end
   return true
  end
  -- Panels swallow the keys they don't use.
  return State.mode(s) ~= "reading"
 end,
}

return block
