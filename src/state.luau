--!strict
-- What the page shows on top of the review itself, and the changes to it that need no window.
local Agent = require("./agent")
local Diff = require("./diff")
local FileTree = require("./file-tree")
local Fields = require("./text-field")
local Guide = require("./guide")
local Lens = require("./lens")
local Pr = require("./pr")
local Review = require("./review")
local Search = require("./search")

-- Which keys the page listens for: the open text field or panel, else reading.
export type Mode = "search" | "models" | "composer" | "summary" | "review" | "reading"

-- A comment being written on lines from..to of `file`, hung under `to` in the step block keyed
-- `step`, or in the file's own block when no step shows the line.
export type Composer = { file: string, from: number, to: number, step: string?, field: Fields.Field }

export type SearchBox = { field: Fields.Field, results: { Search.Result }, selected: number }

-- The model dropdown: its filter and the text the list was last filtered by, the highlighted model
-- (an index into the models matching the filter), the effort the next pick gets, and the first
-- match its list shows.
export type ModelBox = { field: Fields.Field, query: string, selected: number, effort: string?, top: number }

-- The changed line a search jumped to, marked until the next jump.
export type Hit = { file: string, entry: number }

-- Where submitting sends the review and how far it got: in a dry run the review is saved to
-- `dryRunPath`, else posted after the reader confirms (`confirming`: the first submit has been
-- pressed and the next one posts); `repo` is the checkout `gh` runs in, nil for the bundled sample.
export type Submit = { repo: string?, dryRunPath: string?, confirming: boolean, sending: boolean, error: string? }

-- Which code blocks a render draws open. The page redraws whole on every key and Tern stops a view
-- that takes over 2 s, so open blocks share a budget of rows; blocks past it draw as their header.
export type Plan = {
 -- Blocks drawn open, by block id.
 open: { [string]: boolean },
 -- Open blocks whose rows draw uncolored.
 plain: { [string]: boolean },
 -- Supporting files the reader opened that the budget left folded.
 supportingFolded: number,
}

-- A page with a guide shows it as the guided walkthrough or as the plain file view, one at a time.
export type ViewId = "guided" | "files"

-- What each view keeps of its own, so flipping back finds the reader where they were: how it
-- reads the review (its steps, the step it is on, its ticks), what it has open and folded.
-- Block ids repeat between views, which is why none of this is shared.
export type Place = {
 reading: Review.Reading,
 peek: { [string]: boolean },
 folded: { [string]: boolean },
 reveals: { [string]: { Diff.Interval } },
 whole: { [string]: boolean },
 pinned: { [string]: boolean },
 descriptionOpen: boolean,
 foldedFolders: { [string]: boolean },
 supportingOpen: boolean,
 fileOpen: { [string]: boolean },
}

-- Code blocks are keyed by block id: a step's key, or "f:<path>" for a supporting file. What
-- `Place` lists belongs to the view shown; the other view's is parked in `other`.
export type State = {
 review: Review.Review,
 view: ViewId,
 -- The view not shown, for a page with a guide; nil for one without.
 other: Place?,
 diffs: { [string]: Diff.FileDiff },
 -- Reviewed step blocks start folded and open on demand; unreviewed ones start open and fold on demand.
 peek: { [string]: boolean },
 folded: { [string]: boolean },
 -- Unchanged lines the reader opened, by block id.
 reveals: { [string]: { Diff.Interval } },
 -- Blocks showing their whole file.
 whole: { [string]: boolean },
 -- Bodies and panels playing their closing animation.
 closing: { [string]: boolean },
 flowOpen: boolean,
 -- The PR description; it starts open when no guide's overview stands in for it.
 descriptionOpen: boolean,
 -- Folders of the file tree the reader folded, by path.
 foldedFolders: { [string]: boolean },
 supportingOpen: boolean,
 fileOpen: { [string]: boolean },
 -- Blocks the reader opened by hand, by block id; the budget never folds them.
 pinned: { [string]: boolean },
 -- The block that flashes after a jump; the count alternates the animation so it replays.
 flash: string?,
 flashCount: number,
 composer: Composer?,
 search: SearchBox?,
 hit: Hit?,
 helpOpen: boolean,
 models: ModelBox?,
 reviewOpen: boolean,
 -- The review panel's selected comment, an index into Review.items.
 reviewCursor: number,
 editingSummary: boolean,
 -- The change being drawn came from a key press, so it shows at once instead of animating.
 keyed: boolean,
 submit: Submit,
 -- The reader's AI agent writing a guide, offered while the page has none.
 ai: Agent.Run?,
 born: { [string]: string },
 booted: boolean,
 -- How the page came to be: opened as a PR ("load"), or written by the AI over the default
 -- walkthrough ("guide"). The page's blocks arrive with a matching motion. After the reader
 -- switches view nothing arrives ("still"): a switch is instant.
 arrival: "load" | "guide" | "still",
}

local SUPPORTING_PREFIX = "f:"

-- Code rows the open blocks of the guided steps may draw, and again those of the supporting files.
-- A colored row is about 15 nodes and a render costs about 4 µs a node: at 600 rows a key redraws
-- the page in about 40 ms (1000 rows took 60-100 ms, which typing a comment feels).
local ROW_BUDGET = 600
-- A block with more rows than this draws them uncolored, at about a third of the cost.
local PLAIN_OVER = 300
local PLAIN_COST = 0.4

local M = {}

function M.new(pr: Pr.PR, guide: Guide.Guide, to: { repo: string?, dryRunPath: string? }): State
 local diffs = {}
 for _, file in pr.files do diffs[file.path] = Diff.analyze(file) end
 local review = Review.new(pr, guide)
 local other: Place? = nil
 if guide.guided then
  other = {
   reading = Review.filesReading(review),
   peek = {}, folded = {}, reveals = {}, whole = {}, pinned = {},
   descriptionOpen = true, foldedFolders = {}, supportingOpen = false, fileOpen = {},
  }
 end
 return {
  review = review, view = "guided", other = other, diffs = diffs,
  peek = {}, folded = {}, reveals = {}, whole = {}, closing = {},
  flowOpen = true, descriptionOpen = not guide.guided, foldedFolders = {}, supportingOpen = false, fileOpen = {}, pinned = {},
  flash = nil, flashCount = 0,
  composer = nil, search = nil, hit = nil,
  helpOpen = false, models = nil, reviewOpen = false, reviewCursor = 1, editingSummary = false,
  keyed = false, submit = { repo = to.repo, dryRunPath = to.dryRunPath, confirming = false, sending = false, error = nil }, ai = nil,
  born = {}, booted = false, arrival = "load",
 }
end

function M.mode(s: State): Mode
 if s.search then return "search" end
 if s.models then return "models" end
 if s.composer then return "composer" end
 if s.editingSummary then return "summary" end
 if s.reviewOpen then return "review" end
 return "reading"
end

-- The text field keys type into in the current mode.
function M.field(s: State): Fields.Field?
 local mode = M.mode(s)
 if mode == "search" then return (s.search :: SearchBox).field end
 if mode == "models" then return (s.models :: ModelBox).field end
 if mode == "composer" then return (s.composer :: Composer).field end
 if mode == "summary" then return s.review.summary end
 return nil
end

function M.supportingBlock(path: string): string
 return SUPPORTING_PREFIX .. path
end

-- The supporting file a block id names, or nil for a step block.
function M.supportingPath(blockId: string): string?
 return if string.sub(blockId, 1, #SUPPORTING_PREFIX) == SUPPORTING_PREFIX then string.sub(blockId, #SUPPORTING_PREFIX + 1) else nil
end

function M.currentStep(s: State): Guide.Step
 return s.review.steps[s.review.cur]
end

-- Whether the page has a guide to switch between, as opposed to showing the default file list.
function M.switchable(s: State): boolean
 return s.other ~= nil
end

-- The step whose block shows `line` of `file`: the one covering it, else the file's nearest step,
-- which then draws the line too (see `strays`). Nil for a file no step visits.
function M.stepFor(s: State, file: string, line: number): number?
 return Review.stepShowing(s.review, file, line) or M.nearestStep(s, file, line)
end

-- The lines of the reader's comments, and of the one being written, that no step's block covers
-- (written in the file view, where blocks show whole files), as entries the nearest step's block
-- draws, so every comment is somewhere in the guided view.
local function strays(s: State, file: string, step: Guide.Step): { Diff.Interval }?
 local found: { Diff.Interval }? = nil
 local function add(line: number)
  if Review.stepShowing(s.review, file, line) then return end
  local i = M.nearestStep(s, file, line)
  if i == nil or s.review.steps[i] ~= step then return end
  for n, entry in s.diffs[file].entries do
   if entry.diff and entry.row.new == line then
    found = found or {}
    table.insert(found :: { Diff.Interval }, { first = n, last = n })
    return
   end
  end
 end
 for _, own in s.review.own do
  if own.file == file then add(own.to) end
 end
 local c = s.composer
 if c and c.file == file then add(c.to) end
 return found
end

-- What block `blockId` on `file` shows: a step's block when `lines` is the step, else a supporting
-- file's. Lines with cards under them stay drawn when a big file is shown whole.
function M.show(s: State, file: string, blockId: string, lines: Guide.Step?): Diff.Show
 local annotated = {}
 if lines then
  for _, comment in s.review.guide.comments do
   if comment.file == file then annotated[comment.line] = true end
  end
 end
 for _, own in s.review.own do
  if own.file == file then annotated[own.to] = true end
 end
 local c = s.composer
 if c and c.file == file and (c.step or M.supportingBlock(file)) == blockId then annotated[c.to] = true end
 local hit = if s.hit and s.hit.file == file then s.hit.entry else nil
 local reveals = s.reveals[blockId] or {}
 local extra = if lines then strays(s, file, lines) else nil
 if extra then
  local all = table.clone(reveals)
  for _, interval in extra do table.insert(all, interval) end
  reveals = all
 end
 return { lines = lines, whole = s.whole[blockId] == true, annotated = annotated, hit = hit, reveals = reveals }
end

-- Whether a folded folder of the file tree hides `path`.
function M.inFoldedFolder(s: State, path: string): boolean
 for folder in string.gmatch(path, "()/") do
  if s.foldedFolders[string.sub(path, 1, folder - 1)] then return true end
 end
 return false
end

-- Opens every folder above `path`, so a jump to it lands on a shown file.
function M.unfoldFoldersOf(s: State, path: string)
 for folder in string.gmatch(path, "()/") do
  s.foldedFolders[string.sub(path, 1, folder - 1)] = nil
 end
end

-- Whether the reader has block `blockId` open, budget aside: unreviewed steps start open and
-- reviewed ones folded until reopened; supporting files open one by one or all at once.
local function wantsOpen(s: State, blockId: string): boolean
 local path = M.supportingPath(blockId)
 if path then return s.supportingOpen and s.fileOpen[path] == true and not M.inFoldedFolder(s, path) end
 if s.review.reviewed[blockId] then return s.peek[blockId] == true end
 return not s.folded[blockId]
end

type Candidate = { id: string, file: string, lines: Guide.Step? }

-- Opens `forced` blocks whatever they cost, then `queue` in order until a block doesn't fit;
-- returns how many of `queue` stay folded.
local function fill(s: State, plan: Plan, forced: { Candidate }, queue: { Candidate }): number
 local spent = 0
 local function cost(block: Candidate): (number, boolean)
  local fd = s.diffs[block.file]
  if fd.file.binary then return 0, true end
  local rows = Diff.layout(fd, M.show(s, block.file, block.id, block.lines)).rows
  local plain = not fd.highlighted or rows > PLAIN_OVER
  return rows * (if plain then PLAIN_COST else 1), plain
 end
 for _, block in forced do
  local rowCost, plain = cost(block)
  spent += rowCost
  plan.open[block.id], plan.plain[block.id] = true, plain
 end
 for n, block in queue do
  local rowCost, plain = cost(block)
  if spent + rowCost > ROW_BUDGET then return #queue - n + 1 end
  spent += rowCost
  plan.open[block.id], plan.plain[block.id] = true, plain
 end
 return 0
end

-- The blocks this render draws open. Blocks the reader opened by hand, the current step and the
-- block holding the comment being written always open. The other open steps follow in reading
-- order from the current step, then the steps before it nearest first, until the rows run out;
-- open supporting files follow in page order under a budget of their own.
function M.plan(s: State): Plan
 local r = s.review
 local plan: Plan = { open = {}, plain = {}, supportingFolded = 0 }
 local composerBlock = if s.composer then s.composer.step or M.supportingBlock(s.composer.file) else nil
 -- Splits the blocks the reader has open into those that open whatever they cost (`always`, the
 -- pinned ones, the composer's) and the queue.
 local function split(blocks: { Candidate }, always: string?): ({ Candidate }, { Candidate })
  local forced, queue = {}, {}
  for _, block in blocks do
   if not wantsOpen(s, block.id) then continue end
   if block.id == always or s.pinned[block.id] or block.id == composerBlock then
    table.insert(forced, block)
   else
    table.insert(queue, block)
   end
  end
  return forced, queue
 end
 local steps: { Candidate } = {}
 local function addStep(i: number)
  local step = r.steps[i]
  table.insert(steps, { id = step.key, file = step.file, lines = step })
 end
 for i = r.cur, #r.steps do addStep(i) end
 for i = r.cur - 1, 1, -1 do addStep(i) end
 local forced, queue = split(steps, r.steps[r.cur].key)
 fill(s, plan, forced, queue)
 if s.supportingOpen then
  local files: { Candidate } = {}
  for _, file in FileTree.order(Review.supportingFiles(r)) do
   table.insert(files, { id = M.supportingBlock(file.path), file = file.path })
  end
  local pinned, opened = split(files, nil)
  plan.supportingFolded = fill(s, plan, pinned, opened)
 end
 return plan
end

-- Opens or folds block `blockId` by hand; the budget leaves an opened block open.
function M.setOpen(s: State, blockId: string, open: boolean)
 s.pinned[blockId] = if open then true else nil
 local path = M.supportingPath(blockId)
 if path then
  s.fileOpen[path] = if open then true else nil
  if open then
   s.supportingOpen = true
   M.unfoldFoldersOf(s, path)
  end
 elseif s.review.reviewed[blockId] then
  s.peek[blockId] = if open then true else nil
 else
  s.folded[blockId] = if open then nil else true
 end
end

-- Makes step `i` current, opening its block when it was reviewed and folded.
function M.visitStep(s: State, i: number)
 local key = s.review.steps[i].key
 s.review.cur = i
 if s.review.reviewed[key] then s.peek[key] = true end
end

function M.openSupportingFile(s: State, path: string)
 M.setOpen(s, M.supportingBlock(path), true)
end

-- Opens every supporting file, or closes them all when all are already open. Opening all leaves
-- them to the budget.
function M.toggleAllSupporting(s: State)
 local files = Review.supportingFiles(s.review)
 local open = not s.supportingOpen
 for _, file in files do
  if not s.fileOpen[file.path] then open = true end
 end
 for _, file in files do
  if open then s.fileOpen[file.path] = true else M.setOpen(s, M.supportingBlock(file.path), false) end
 end
 s.supportingOpen = true
end

function M.reveal(s: State, blockId: string, first: number, last: number)
 s.reveals[blockId] = s.reveals[blockId] or {}
 table.insert(s.reveals[blockId], { first = first, last = last })
end

function M.toggleWhole(s: State, blockId: string)
 if s.whole[blockId] then
  s.whole[blockId], s.reveals[blockId] = nil, nil
 else
  s.whole[blockId] = true
 end
end

-- The step on `file` whose range is closest to `line` (the first on it when `line` is nil).
function M.nearestStep(s: State, file: string, line: number?): number?
 local best, bestDistance = nil, math.huge
 for i, step in s.review.steps do
  if step.file == file then
   local distance = if line == nil or (line >= step.from and line <= step.to) then 0
    else math.min(math.abs(line - step.from), math.abs(line - step.to))
   if distance < bestDistance then best, bestDistance = i, distance end
  end
 end
 return best
end

-- Shows `file` (and its line `entry`, marked as the hit) in the nearest step's block, else in the
-- file's own block; returns that block's id and whether it is a step's.
function M.showFile(s: State, file: string, entry: number?): (string, boolean)
 local line = nil
 if entry then
  local row = s.diffs[file].entries[entry].row
  line = row.new or row.old
 end
 local i = M.nearestStep(s, file, line)
 local blockId
 if i then
  M.visitStep(s, i)
  blockId = s.review.steps[i].key
  s.folded[blockId] = nil
 else
  M.openSupportingFile(s, file)
  blockId = M.supportingBlock(file)
 end
 if entry then
  M.reveal(s, blockId, entry, entry)
  s.hit = { file = file, entry = entry }
 end
 return blockId, i ~= nil
end

-- The lines a click on a line's "+" comments on. Tern gives plugins clicks but no drag, so a range
-- is two clicks: the first "+" starts a comment, a second "+" in the same hunk stretches it to
-- there (`extends`), the same "+" again closes it (nil). GitHub only takes a range within a hunk,
-- so a "+" in another hunk starts a new comment.
function M.commentRange(s: State, file: string, line: number): (number?, number?, boolean)
 local c = s.composer
 if c and c.file == file and c.from == c.to then
  if line == c.from then return nil, nil, false end
  local from, to = math.min(c.from, line), math.max(c.from, line)
  local first, last = Diff.commentableRange(s.diffs[file], from, to)
  if first == from and last == to then return from, to, true end
 end
 return line, line, false
end

-- Opens a comment on lines from..to, hung under `to` in whichever block shows it, keeping any text
-- already typed; returns the block id.
function M.openComposer(s: State, file: string, from: number, to: number): string
 local i = M.stepFor(s, file, to)
 local step, blockId = nil, M.supportingBlock(file)
 if i then
  M.visitStep(s, i)
  step = s.review.steps[i].key
  blockId = step
 else
  M.openSupportingFile(s, file)
 end
 local field = if s.composer then s.composer.field else Fields.create("", true)
 s.composer = { file = file, from = from, to = to, step = step, field = field }
 return blockId
end

-- Hangs a comment being written under the step of the view now shown (or the supporting file's).
local function rehomeComposer(s: State)
 local c = s.composer
 if not c then return end
 local i = M.stepFor(s, c.file, c.to)
 c.step = if i then s.review.steps[i].key else nil
end

local function park(s: State): Place
 return {
  reading = Review.reading(s.review),
  peek = s.peek, folded = s.folded, reveals = s.reveals, whole = s.whole, pinned = s.pinned,
  descriptionOpen = s.descriptionOpen, foldedFolders = s.foldedFolders, supportingOpen = s.supportingOpen, fileOpen = s.fileOpen,
 }
end

local function unpark(s: State, place: Place)
 Review.adopt(s.review, place.reading)
 s.peek, s.folded, s.reveals, s.whole, s.pinned = place.peek, place.folded, place.reveals, place.whole, place.pinned
 s.descriptionOpen, s.foldedFolders, s.supportingOpen, s.fileOpen = place.descriptionOpen, place.foldedFolders, place.supportingOpen, place.fileOpen
end

-- Shows the other view, with its own place and the reader's work untouched. It lands on the file
-- the reader was reading: on the view's own step when that is on the file, else on the file's
-- first step, else (a file no step visits) on its supporting block. Returns the block to scroll to.
function M.switchView(s: State, to: ViewId): string?
 local parked = s.other
 if not parked or s.view == to then return nil end
 local file = M.currentStep(s).file
 s.other = park(s)
 unpark(s, parked)
 s.view, s.arrival, s.flash = to, "still", nil
 local blockId
 local i = M.nearestStep(s, file, nil)
 if i then
  if M.currentStep(s).file ~= file then M.visitStep(s, i) end
  blockId = M.currentStep(s).key
 else
  M.openSupportingFile(s, file)
  blockId = M.supportingBlock(file)
 end
 rehomeComposer(s)
 return blockId
end

function M.saveComposer(s: State)
 local c = s.composer
 if c then Review.addOwn(s.review, c.file, c.from, c.to, c.field.text) end
 s.composer = nil
end

function M.openSearch(s: State)
 s.search = { field = Fields.create("", false), results = {}, selected = 1 }
end

function M.runSearch(s: State, box: SearchBox)
 box.results, box.selected = Search.run(box.field.text, s.review, s.diffs), 1
end

function M.moveSearch(box: SearchBox, delta: number)
 box.selected = math.clamp(box.selected + delta, 1, math.max(1, #box.results))
end

function M.openReview(s: State)
 s.reviewOpen = true
 s.reviewCursor = Review.firstWaiting(s.review)
end

-- Moves the review panel's selection; returns the comment it lands on.
function M.moveReviewCursor(s: State, delta: number): Review.Item?
 local items = Review.items(s.review)
 s.reviewCursor = math.clamp(s.reviewCursor + delta, 1, math.max(1, #items))
 return items[s.reviewCursor]
end

-- Includes or leaves out comment `n` of the review and selects it.
function M.toggleItem(s: State, n: number)
 local item = Review.items(s.review)[n]
 if item then
  s.reviewCursor = n
  Review.include(s.review, item, not Review.isIncluded(s.review, item))
 end
end

-- The model dropdown, highlighting the model in use.
function M.openModels(s: State, agent: Agent.Agent)
 local selected = 1
 for i, model in agent.models do
  if model.selector == agent.model then selected = i end
 end
 s.models = { field = Fields.create(), query = "", selected = selected, effort = agent.effort, top = math.max(1, selected - 3) }
end

-- The models matching the dropdown's filter.
function M.modelChoices(box: ModelBox, agent: Agent.Agent): { Agent.Model }
 return Agent.matching(agent.models, box.field.text)
end

-- Rows the model list fits before it scrolls.
local MODEL_ROWS = 8

-- Starts the list far enough down that the highlighted model is among the rows it fits. The list
-- is never scrolled to it: Tern's reveal into a scroller pins it, so the wheel stops working.
function M.keepModelShown(box: ModelBox)
 if box.selected < box.top then
  box.top = box.selected
 elseif box.selected >= box.top + MODEL_ROWS then
  box.top = box.selected - MODEL_ROWS + 1
 end
end

function M.moveModel(box: ModelBox, agent: Agent.Agent, delta: number)
 box.selected = math.clamp(box.selected + delta, 1, math.max(1, #M.modelChoices(box, agent)))
 M.keepModelShown(box)
end

-- Steps the effort the highlighted model will get through the levels it takes.
function M.stepEffort(box: ModelBox, agent: Agent.Agent, delta: number)
 local model = M.modelChoices(box, agent)[box.selected]
 if not model or #model.efforts == 0 then return end
 local at = table.find(model.efforts, Agent.effortFor(model, box.effort) :: string) :: number
 box.effort = model.efforts[(at - 1 + delta) % #model.efforts + 1]
end

-- Makes the highlighted model, with the effort it can take, the one runs use; false when the
-- filter matches nothing.
function M.chooseModel(box: ModelBox, agent: Agent.Agent): boolean
 local model = M.modelChoices(box, agent)[box.selected]
 if not model then return false end
 agent.model, agent.effort = model.selector, Agent.effortFor(model, box.effort)
 box.effort = agent.effort
 return true
end

-- Has runs use the lens after (`delta` 1) or before (-1) the current one, wrapping round.
function M.stepLens(agent: Agent.Agent, delta: number)
 agent.lens = Lens.step(agent.lenses, agent.lens, delta).name
end

-- Has runs use lens number `n` of the list; false when there is none.
function M.chooseLens(agent: Agent.Agent, n: number): boolean
 local lens = agent.lenses[n]
 if not lens then return false end
 agent.lens = lens.name
 return true
end

return M
