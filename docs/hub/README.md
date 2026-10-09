# PR hub: design spec

A hub page for PR Guide. It shows every open PR you wrote and every PR waiting on your review, across repos, sorted by who needs to act next. This folder holds the approved design: this spec, clickable mockups in `mockups/` and the measured GitHub queries in `queries/`. **No plugin code has been written yet.**

**Status:** design approved and split into GitHub issues: parent [#17](https://github.com/jubbydev/tern-pr-guide/issues/17), with sub-issues #2–#20 labelled `hub` and `v0`/`v1`/`v2`. Each sub-issue names the modules it may touch and what it depends on. Start with #2 (rules); #3 (GitHub data) and #5 (board) follow it in parallel. See "How to build this" for the whole order.

## Start here

1. Serve the repo root: `python3 -m http.server 61440` (the mockups link `docs/tern-tokens.css` and `guide.css` by relative path).
2. Open these pages:

   | Page | What it shows |
   |---|---|
   | http://localhost:61440/docs/hub/mockups/index.html?agent=1 | The hub, with one card in each agent state |
   | http://localhost:61440/docs/hub/mockups/index.html?tab=rev | The Review requests tab, with the add-by-link field |
   | http://localhost:61440/docs/hub/mockups/pr-fixes.html?pr=418 | ⏎ on a Needs fixes card: what needs fixing, at the code |
   | http://localhost:61440/docs/hub/mockups/review-fix.html | Review fix: checking the agent's conflict resolution before pushing |

3. Before touching `src/view/` or `guide.css`, read the repo's `AGENTS.md`, `DESIGN.md` and `docs/ui.md`. Mockups link `docs/tern-tokens.css` and `guide.css` inside a `.gp-root` wrapper.

## Product decisions (settled)

### Structure

Two Tern tabs, one board each. `T` switches between them.

| Tab | Columns | Below |
|---|---|---|
| Your pull requests | Needs fixes · In review · Ready to merge | Inactive (folded) |
| Review requests | To review · Waiting on author · Approved | |

- **Tab counts:** blue, counting only the cards in the your-turn column.
- **Card looks:**
  - Your-turn cards: washed red (yours) or blue (reviews).
  - Waiting cards: neutral.
  - Done cards: green-edged with a ✓.
  - Agent work: purple.
  - Running checks: amber.
- **Header:**
  - Title, search, then "Updated 40s ago" and the agent model menu (`⇧M`).
  - The tab row holds the tabs, then **All repositories ▾** (`F`, multi-select) and **Sort ▾** (`S`).
  - Sort options: Repository (the default, with Priority order inside each repo), Priority, Newest first, Oldest first, Smallest first.
- **Kept out on purpose:** counts in the header, inline keycaps on the tab-row controls (the hint bar lists the keys), and filler notes such as "Nothing needed from you".

### Which column a PR is in

Each PR appears exactly once.

- **Needs fixes:** your PR had activity in the last 7 days and has at least one of the following. Each reason shows as its own red chip.
  - **Merge failed:** the merge queue rejected it. It sorts first.
  - **A failing check.**
  - **Feedback from a person:** the reviewer's latest review requested changes, or a thread is unresolved and its author's latest review isn't an approval. Plain comments ("LGTM"), threads whose author later approved, bots and your own comments never count. An approval doesn't clear a failing check or a conflict.
  - **A merge conflict.**
- **In review:** everything else that's waiting on someone else: waiting on review, on one more approval, on checks, or on Tandem. A PR Tandem is working on stays here.
- **Ready to merge:** approved, checks passing, no conflicts.
- **Inactive:** drafts, and PRs with no activity for 7 days, including stale conflicts. Your real data has 16 conflicted PRs, which is why the 7-day gate exists.
- **Review requests tab:**
  - **To review:** requested reviews, PRs with new commits since you approved (re-review), and PRs you added by link.
  - **Waiting on author:** you requested changes or commented.
  - **Approved.**
- **Re-review rule:** `my latest review's commit oid != headRefOid`. No LLM is involved.
- **Priority order:**
  - Your-turn columns: by kind first (a person waiting on you beats a machine), then the longest waiting.
  - Ready to merge: the oldest first, since conflicts grow with time.
  - Waiting columns: the newest first.

### Cards and actions

- **Anatomy:** chip line (the job), title, an optional note (what the agent found or why a fix failed), and the repo line (repo #num, checks, age).
- **Action placement (one rule for every card):**
  - Resting cards show no actions. The chip already names the job.
  - While a card is hovered or selected, its **split button** replaces the checks and age on the repo line, the way Gmail swaps a row's date for its actions.
  - Hovered, the button is quiet. Selected, it's filled and shows its key.
  - Alternatives sit behind the attached ▾. Card heights never change.
- **Clicks:** a click selects; double-click or ⏎ opens.

| Card | Main action | Behind ▾ / other keys |
|---|---|---|
| Needs fixes | **Fix with agent** (A), or **Hand off to Tandem** for PRs Tandem watches | **Summarize** (⇧A, or A when the only reason is comments) |
| Agent running | **Stop** (A) | |
| Fix ready | **Review fix** (⏎) | **Discard fix** (D, with an inline confirm) |
| Reviewed fix | **Push to branch** (P) | Discard fix (D) |
| Fix failed | **Try again** (A) | Open worktree (O) |
| No local clone | **Clone repo** (A) | Choose folder… (O) |
| In review | **Copy link** (C): copies "title url" as plain text (Tern's clipboard has no rich flavor; see the clipboard facts) | |
| In review with a bot review | **Fix bot comments** (A); the card stays in In review | Copy link (C) |
| Ready to merge | **Merge** (M) | Merge method for the repo (`,`) |
| To review | **Review** (⏎) | Remove from Review requests (X), only on PRs you added |

### ⏎ on a Needs fixes card (`pr-fixes.html`)

This opens the PR at what needs fixing, in the guided review layout.

- **Left column:** the problems as steps, grouped Requested changes, Comments, Failing checks, Merge conflicts.
- **Right side:** the code for the selected step.

| Step | Shows | Actions |
|---|---|---|
| Comment or requested change | The thread pinned at its line in the diff | Reply (R), Resolve (E) |
| Failing check | The annotation pinned at its line | View log (⇧L) |
| Merge conflict | "Your branch" and "main" blocks, plus "Main changed this in #415 by @devon" | Fix with agent (A), Resolve on GitHub (G) |

- **Keys:** h/l move between the steps and the code panel; j/k move within either one.

### Agent fixes (v2)

- **The agent:** your own `omp`, with the model and effort from the `⇧M` menu, which guided reviews already use (`src/agent.luau`, kv key `model`).
- **One PR at a time.** There is no "Fix all".
- **Where it works:** in a treehouse worktree, never in your checkout. It commits there and never pushes. The card goes running → **Fix ready** → **Review fix** (`review-fix.html`) → **Push to branch**.
- **Review fix page (`review-fix.html`):**
  - The diff shows only the agent's resolution. Each line is tagged main, Your branch or Agent.
  - B shows the original conflict.
  - Push unlocks once every conflict is marked reviewed.
- **Token-light conflict pipeline:**
  1. No AI: `git merge origin/<base>` with rerere on. A clean merge reaches Fix ready at zero tokens.
  2. No AI: lockfiles and generated files take the base side, then are regenerated.
  3. AI only for the hunks left, through a small `conflicts` tool: `list`, `show <id>` (base, ours and theirs, a few context lines, and the subjects of commits on each side), `take <id> ours|theirs|both`, `write <id>`, `check`.
  4. Commit in the worktree.
- **Conflicts are fixed by merging the base branch in.** No force push.
- **Summaries:** read-only `omp -p` over the feedback, on click only. The verdict ("Reply to @maria-k") goes on the chip line, with one line per commenter below.
- **PRs Tandem watches** are handed to Tandem: one owner per branch.

### Merging

Each repo has one merge setting, stored in kv. It's one of six kinds:

| Kind | How | Confirm |
|---|---|---|
| Squash and merge · Create a merge commit · Rebase and merge | `gh pr merge` | ⌘⏎ inline |
| Merge when ready (GitHub merge queue) | `gh pr merge --auto` | No, it can be cancelled |
| Comment a command (`/merge`, `/aviator merge`, plus an optional cancel comment) | `gh pr comment` | No, it can be cancelled |
| Add a label | `gh pr edit --add-label` | No, it can be cancelled |

- **Where the setting comes from (first match wins):**
  1. Set by you.
  2. Declared by the repo: `.aviator/config.yml` means comment `/aviator merge`, and `repository.mergeQueue` means the merge queue.
  3. **Learned** from the repo's last 8 merged PRs. For example, a bot merged right after a person commented `/…`. Checking costs 1 point. It's shown as a suggestion and asked once.
  4. `viewerDefaultMergeMethod`.
- **Detection runs once per repo and is cached.**
- **The hub never calls GitHub's merge on a repo that merges by comment, label or queue.** Two tools can't own one branch.
- **Queued merges:** the card shows "Commented /merge · waiting for the merge" or "Queued in Aviator". A queue rejection moves the PR to Needs fixes as **Merge failed**, with the reason from GitHub's `RemovedFromMergeQueueEvent.reason` or Aviator's blocked status. For comment merges, failure is known only from a check failing after the comment, or from the bot's reply.

### Adding a PR by link

To review has its own field: "Paste a pull request link to review" (`N`, from either tab).

| Pasted | ⏎ | ⇧⏎ |
|---|---|---|
| A new PR | **Add to review** (lands as "Added by you") | **Open without adding** |
| A PR already on the board | **Show on the board** | **Open** |

- **Anything else** shows "A pull request link looks like github.com/owner/repo/pull/123".
- **Search only searches.**
- **After you review it,** `reviewed-by:@me` keeps the PR on the board.

### Telling you something needs fixes

- **On every arrival in Needs fixes:**
  - the card arrives with a fading red ring (good news gets a green wash);
  - the hub's status-line segment flashes red.
- **One `cx:toast` per refresh:**
  - one PR: "#396 needs fixes: merge failed";
  - several: "3 pull requests need fixes".
- **Toast only for:** merge failed, a person's requested changes or comment, and failing checks. **Conflicts only get the ring**, because they arrive in bursts from other people's merges.
- **Never toast** on first load, for inactive PRs, or for something you just did.
- **No system notifications:** plugins have no system notification API (as far as I found).

### Keys

| Key | Action |
|---|---|
| h j k l / arrows | Move: up and down within a column, left and right to the nearest card in the next column |
| ⏎ / double-click | Open (Needs fixes cards open at the fixes) |
| T | Switch tab |
| I | Show or hide Inactive |
| F / S | Repository filter / Sort menu (menus: j/k, ⏎ or Space, Esc) |
| ⇧M | Agent model menu (↑↓ model, ←→ effort) |
| N | Add a PR by link |
| / | Search |
| A, ⇧A, P, D, O, C, M, `,`, X | Card actions (see the table above) |
| ⌘⏎ / Esc | Confirm / cancel inline questions |
| ⌘R | Refresh |

- **Every control has a key.** The hint bar shows only what applies right now: Next up, Move, Open, the selected card's main action (plus Select when it applies), and **? All shortcuts**. `?` opens a grouped panel of every key (Move, The selected card, The board), and Esc or a click outside closes it. Board-wide keys appear in that panel and in the controls' tooltips, not in the bar. The search field and the add-by-link field show their keys inside them. This matches the plugin's review page, which ends its hint bar with "? all shortcuts".
- **A click and its key run the same action.**
- **Keyboard-driven changes never animate.**

## Data and GitHub cost (measured)

| Call | Cost | Time | When |
|---|---|---|---|
| `docs/hub/queries/hub-f.graphql`: 3 searches (author, review-requested, reviewed-by), check counts, author types | 9 pts, before the extensions in Verification are re-measured | 6–8 s | On a change, on focus (debounced to 30 s), and every 5 min while the hub block exists (a block can't observe visibility) |
| `threads.graphql`: thread authors via `nodes(ids:)`, only for PRs with an unresolved thread whose `updatedAt` changed | 9 pts for 17 PRs | 0.7 s | After hub-f |
| `checks.graphql`: CI state for PRs with running checks | 1 pt for 5 or 40 PRs | 1–1.5 s | Every 30 s while any check is running |
| REST `/notifications` with `If-Modified-Since` | free (304) | | Every 60 s, as the change probe |
| Fixes-page details: threads with path/line/body, changes-requested reviews, failing check runs with annotations | 1 pt | | When a Needs fixes PR is opened |
| Learning a repo's merge habit: last 8 merged PRs with `mergedBy` and comments | 1 pt | | Once per repo |

- **Don't** put thread authors inside the search query. Measured at **159 points** per call.
- **Budget:** about 220 pts/hr while the hub block exists. Even the 30 s debounce ceiling (about 2,200/hr) fits the 5,000/hr GraphQL budget, which Tandem's pr-watch shares.
- **Latency is the real cost.** Always render from the kv cache first, then refresh in the background.
- **Check annotations include noise.** Drop paths under `.github/` and messages like "Process completed with exit code". Measured on Tagalingo-App #1013, the useful one was `src/lib/query-persister.ts:39 Type …`.
- **Conflicted files** come from local `git merge-tree --write-tree --name-only`, not GitHub.
- **Your real data:** 36 open PRs you wrote across 7 repos (20 in Tagalingo-App), 16 with conflicts, and 1 review request.

## Shared Luau contracts

Every issue builds against these types and signatures. An issue that needs a change edits this section in the same PR as the code. Every module starts with `--!strict`, as `src/keys.luau:1` does. Time is `now: number`, in seconds since the epoch, passed in by the caller. Stored times are ISO strings like `"2026-10-09T04:16:06Z"`. No module in this section reads the clock itself. Types are shown unqualified: in code, another module's type is written `Model.HubPR`, `Github.Client`, `Fields.Field` and so on.

**Existing patterns these follow** (read the code before changing them):

- **State** is one mutable record built by `M.new`, with each field commented (`src/state.luau:68-119`, `:133`). `keyed: boolean` marks a change that came from a key and must not animate (`:108-109`).
- **Keys** return `Action = { act: string, value: string? }` (`src/keys.luau:8`) from `M.action(s, key): Action?` (`:98`). A click sends the same action as the key.
- **Glue** is one `ACTIONS: { [string]: Handler }` table and `dispatch` (`src/block.luau:277`, `:445`), inside a `BlockDef<Block>` with `init/title/view/event/key` (`src/block.luau:686-781`; Tern's type is `tern.d.luau:271-291`).
- **Views** are `view(s: State.State, motion: Ui.Motion): Node` (`src/view/page.luau:71`; `Motion` is `src/view/ui.luau:9`).
- **Callbacks** fire once with `(value?, err?)`: `Fetch.findRepo` (`src/fetch.luau:356`), `listAnywhere` (`:457`), `listPrs` (`:482`), `openPr` (`:514`), `submitReview` (`:562`). The hub's GitHub callbacks use the same shape, with a structured `Error` where `fetch.luau` uses a string.

**What each module may `require`:**

| Module | May require |
|---|---|
| `src/links.luau` | nothing |
| `src/hub/model.luau` | nothing |
| `src/hub/fixes.luau` | `model` |
| `src/github.luau` | `model`, `fixes`. No `tern.*` at load; parsers take already decoded tables (`tern.json.decode` runs in the caller). |
| `src/hub/sync.luau` | `model` |
| `src/hub/agent-fix.luau` | `model`, `fixes` |
| `src/hub/summary.luau` | `model`, `fixes` |
| `src/hub/state.luau` | `model`, `sync`, `fixes`, `agent-fix`, `summary`, `src/text-field.luau`. Never `fetch`, `github` or `block`. |
| `src/keys.luau` | `src/hub/state.luau`, plus what it requires today minus `picker` |
| `src/view/hub/*.luau` | `state`, `model`, `fixes`, `src/view/ui.luau`, `src/text.luau`. Never `sync` or `github`. |
| `src/fetch.luau` | `model` and `fixes` for types, `github` for the `Runner` type, plus what it requires today minus `picker` |
| `src/hub/block.luau` | everything above; it is the only module that wires them |
| `tools/conflicts` | nothing (a standalone script) |

### `src/links.luau` (pure; the picker's link parsing, moved)

```luau
function M.named(text: string): number?            -- "354", "#354" or a PR link -> 354 (picker.luau:179)
function M.linkRepo(text: string): string?         -- "owner/repo" a PR link is in (picker.luau:186)
function M.linkHost(text: string): string?         -- the link's host (picker.luau:191)
function M.reference(slug: string?, number: number): string  -- link, or the bare number without a slug (picker.luau:196)
function M.remoteRepo(url: string): string?        -- "owner/repo" of a git remote URL (picker.luau:202)
function M.sameRepo(a: string?, b: string?): boolean  -- case-insensitive (picker.luau:211)
```

### `src/hub/model.luau` (pure rules)

```luau
export type Tab = "mine" | "review"
export type Column = "needs_fixes" | "in_review" | "ready" | "inactive" | "to_review" | "waiting_on_author" | "approved"
export type Reason = "merge_failed" | "feedback" | "checks" | "conflict"   -- in this order: severity, and the chip order
export type Sort = "repository" | "priority" | "newest" | "oldest" | "smallest"

export type CheckState = "none" | "pending" | "passing" | "failing"
export type Checks = { state: CheckState, passing: number, failing: number, pending: number }

export type Verdict = "approved" | "changes_requested" | "commented" | "dismissed"
-- A reviewer's latest review (hub-f's `latestReviews`).
export type Review = { author: string, bot: boolean, verdict: Verdict, at: string, oid: string }
-- An unresolved thread, by its first comment's author (threads.graphql).
export type OpenThread = { author: string, bot: boolean }
export type ReviewState = {
	decision: "approved" | "changes_requested" | "review_required" | "none",
	latest: { Review },               -- one per reviewer
	mine: Review?,                    -- the viewer's own latest review
	requestedMe: boolean,             -- a review is requested of the viewer
	requested: { string },            -- logins and team slugs
	unresolved: number,               -- unresolved threads, counted in hub-f
	threads: { OpenThread },          -- authors of the unresolved ones, once threads.graphql ran
	threadsKnown: boolean,            -- false until then: unknown threads never count as feedback
	comments: number,
}

export type MergeFailure = { kind: "queue" | "aviator" | "comment" | "check" | "bot", reason: string }
-- A merge asked for and not finished: the repo's queue, a posted command, or a label.
export type PendingMerge = { method: "queue" | "comment" | "label", at: string }

export type HubPR = {
	key: string,                      -- "owner/repo#123", the repo as GitHub spells it; unique on the board
	id: string,                       -- GraphQL node id, for `nodes(ids:)`
	repo: string, number: number, url: string, title: string,
	author: string, authorBot: boolean,
	role: Tab,                        -- "mine": the viewer wrote it. "review": it is waiting on, or was added for, the viewer
	draft: boolean,
	createdAt: string, lastActivityAt: string,   -- GitHub's createdAt and updatedAt
	headOid: string, baseBranch: string,
	additions: number, deletions: number, files: number,
	checks: Checks,
	conflicts: boolean,               -- mergeable == CONFLICTING
	behind: boolean,                  -- mergeStateStatus == BEHIND
	reviews: ReviewState,
	mergeFailure: MergeFailure?,
	pending: PendingMerge?,
	tandem: boolean,                  -- Tandem watches the branch; filled by the block, never by GitHub
	addedByMe: boolean,               -- on the board through a pasted link; filled from `hub.added`
}

export type Placement = { tab: Tab, column: Column, reasons: { Reason } }   -- reasons is empty outside needs_fixes

export type RateLimit = { cost: number, remaining: number, limit: number, resetAt: string }
export type Error = { operation: string, message: string, rateLimit: RateLimit? }   -- operation is like "gh api graphql: hub"
export type PRRef = { repo: string, number: number }
-- What one GitHub refresh returns, normalized. Defined here so `sync` and `state` can use it without requiring `github`.
export type Refresh = {
	prs: { HubPR },                   -- `tandem` and `addedByMe` false, `pending` nil: the block fills them from local facts
	viewer: string,
	rateLimit: RateLimit,             -- the last call's envelope
	calls: { RateLimit },             -- every call's envelope, in order: hub-f, then threads
	truncated: boolean,               -- a search returned more than 50
	partial: Error?,                  -- threads failed: `prs` still stands, with threadsKnown = false
}

function M.epoch(iso: string): number?                  -- picker.luau:271, moved
function M.ago(iso: string, now: number): string        -- "2h ago" (picker.luau:290), moved
function M.reasons(pr: HubPR, now: number): { Reason }
function M.placement(pr: HubPR, now: number): Placement
function M.classify(pr: HubPR, now: number): Column     -- placement(pr, now).column
function M.botFeedback(pr: HubPR): boolean              -- a bot's latest review or unresolved thread, for Fix bot comments
function M.mergeable(pr: HubPR): boolean                -- ready, not behind, nothing pending: the cards Space may select
function M.size(pr: HubPR): number                      -- additions + deletions
export type Filter = { repositories: { [string]: boolean }?, search: string }   -- nil repositories = all
function M.visible(pr: HubPR, filter: Filter): boolean  -- search matches "#n", title, author, repo, base branch
function M.order(prs: { HubPR }, column: Column, sort: Sort, now: number): { HubPR }

-- Next up
export type NextItem = { key: string, tab: Tab, column: Column, reason: Reason? }
export type NextUp = { item: NextItem, index: number, total: number }
function M.queue(prs: { HubPR }, now: number): { NextItem }    -- everything that needs the viewer, both tabs, most urgent first
function M.nextUp(prs: { HubPR }, now: number, after: string?): NextUp?  -- the item after `after`; the first when nil; wraps; nil when none

-- Flakes. Evidence is fetched by github.luau; the verdict is a rule.
export type FlakeEvidence = {
	history: { failed: number, total: number }?,   -- the same check on recent runs of the base branch
	passedBefore: boolean,                         -- it passed on this commit earlier, or on the previous one without a change to the failing area
	text: string,                                  -- the failure text
	annotationPaths: { string },
	changedPaths: { string },
}
export type FlakeVerdict = { flaky: boolean, basis: ("history" | "rerun" | "text" | "outside_diff")?, reason: string? }
function M.flake(evidence: FlakeEvidence): FlakeVerdict
	-- An annotation on a changed path is never flaky. `reason` reads "failed 3 of the last 20 runs on main".
	-- History: 3 or more failures in the last 20 runs on the base branch means likely flaky; 1 or fewer means not.
	-- Two is not enough on its own: only another basis (passedBefore, text, outside_diff) makes it flaky.
	-- The thresholds are named constants in this file, pinned by the flake issue's tests.

-- Merging
export type MergeMethod =
	{ kind: "squash" } | { kind: "merge" } | { kind: "rebase" }
	| { kind: "queue" }                                           -- gh pr merge --auto
	| { kind: "comment", command: string, cancel: string? }       -- gh pr comment
	| { kind: "label", label: string }                            -- gh pr edit --add-label
export type MergeSource = "user" | "declared" | "learned" | "viewer"
export type MergeEvidence = {
	user: MergeMethod?,
	declared: MergeMethod?,           -- .aviator/config.yml, or repository.mergeQueue
	learned: MergeMethod?,            -- from the last 8 merged PRs
	learnedAnswered: boolean,         -- the viewer was asked about `learned` and said no (a yes becomes `user`)
	viewerDefault: "squash" | "merge" | "rebase",
}
export type MergeResolution = { method: MergeMethod, source: MergeSource, ask: boolean }  -- ask: a learned method nobody confirmed yet
function M.resolveMergeMethod(evidence: MergeEvidence): MergeResolution   -- user, declared, learned (unless answered), viewer
```

### `src/hub/fixes.luau` (pure; what the fixes page shows)

```luau
export type ThreadDetail = {
	id: string, group: "requested" | "comment",
	author: string, bot: boolean,
	path: string, line: number?,      -- nil when the thread is on the file or the line is gone
	outdated: boolean,
	body: string,                     -- the first comment
	replies: number, url: string,
}
export type ReviewDetail = { author: string, body: string, at: string, url: string }   -- a changes-requested review
export type Annotation = { path: string, line: number, level: "failure" | "warning" | "notice", title: string?, message: string }
export type FailingCheck = {
	name: string, workflow: string?, runId: number?, url: string,
	summary: string?,
	annotations: { Annotation },      -- after the noise filter: no `.github/` paths, no "Process completed with exit code"
}
export type Cause = { number: number?, title: string, author: string, sha: string }   -- "Main changed this in #415 by @devon"
export type Conflict = { path: string, cause: Cause? }
export type FixDetails = {
	key: string, headOid: string, fetchedAt: string,
	reviews: { ReviewDetail },
	threads: { ThreadDetail },
	checks: { FailingCheck },
	changedPaths: { string },
	conflicts: { Conflict }?,         -- nil until fetch.luau has read local `git merge-tree --write-tree --name-only`
}
```

### `src/github.luau` (the GitHub boundary)

```luau
-- RateLimit, Error, PRRef and Refresh are defined in model.

-- What `tern.process.run` gives and takes, minus the `cx`. src/fetch.luau exports the real runner (shell PATH and all); tests pass a fake.
export type Out = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Runner = (argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Out) -> ()) -> ()

export type RefreshRequest = { added: { PRRef }, previous: { HubPR } }   -- previous supplies cached threads when `lastActivityAt` is unchanged
export type Probe = { changed: boolean, lastModified: string?, pollSeconds: number? }   -- REST /notifications
export type ChecksUpdate = { byId: { [string]: { headOid: string, checks: Checks } }, rateLimit: RateLimit }
export type History = { failed: number, total: number }
export type Detected = { declared: MergeMethod?, learned: MergeMethod?, viewerDefault: "squash" | "merge" | "rebase", checkedAt: string }
export type Command = { argv: { string }, stdin: string? }

export type Client = {
	refresh: (req: RefreshRequest, done: (value: Refresh?, err: Error?) -> ()) -> (),
	probe: (since: string?, done: (value: Probe?, err: Error?) -> ()) -> (),
	checks: (ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ()) -> (),
	details: (pr: HubPR, done: (value: FixDetails?, err: Error?) -> ()) -> (),
	history: (repo: string, checkName: string, done: (value: History?, err: Error?) -> ()) -> (),
	detect: (repo: string, done: (value: Detected?, err: Error?) -> ()) -> (),
	run: (command: Command, done: (stdout: string?, err: Error?) -> ()) -> (),   -- executes a command from `commands`
}
function M.client(run: Runner): Client

-- Pure parsers: decoded JSON in, normalized records out. They never throw on a missing field.
function M.parseHub(raw: any): { prs: { HubPR }, viewer: string, rateLimit: RateLimit, truncated: boolean }?
function M.parseThreads(raw: any): { threads: { [string]: { OpenThread } }, rateLimit: RateLimit }?   -- keyed by node id
function M.parseChecks(raw: any): ChecksUpdate?
function M.parseProbe(stdout: string): Probe?             -- `gh api -i`: 200 or 304, Last-Modified, X-Poll-Interval
function M.parseDetails(raw: any, pr: HubPR): FixDetails?

-- Command builders: exact argv, no network. Merging squash/merge/rebase is `gh pr merge`; queue is `--auto`;
-- comment is `gh pr comment`; label is `gh pr edit --add-label`.
M.commands = {
	merge = function(pr: HubPR, method: MergeMethod): Command end,
	cancelMerge = function(pr: HubPR, method: MergeMethod): Command end,
	updateBranch = function(pr: HubPR): Command end,
	rerun = function(repo: string, runId: number): Command end,            -- gh run rerun <id> --failed
	requestReview = function(pr: HubPR, login: string): Command end,
	close = function(pr: HubPR): Command end,
	comment = function(pr: HubPR, body: string): Command end,
	reply = function(pr: HubPR, threadId: string, body: string): Command end,
	resolve = function(threadId: string): Command end,
}
```

`threads.graphql` and `checks.graphql` select `number` and not the repository, so a bare number is ambiguous across repos. Both gain `id` and key their results by it (see Verification).

### `src/hub/sync.luau` (pure; cache shapes, diff, schedule)

```luau
export type Counts = { toReview: number, needFixes: number, flashAt: number? }   -- what the status segment reads; flashAt is a time
export type Cache = {
	schema: 1,
	refreshedAt: string, viewer: string,
	prs: { HubPR },
	rateLimit: RateLimit?,
	lastModified: string?,            -- the probe's validator
	counts: Counts,
}
export type Added = { [string]: PRRef }       -- hub.added, by key
export type Local = { added: Added, tandem: { [string]: boolean } }
export type MergeRecord = { schema: 1, user: MergeMethod?, declared: MergeMethod?, learned: MergeMethod?, learnedAnswered: boolean, checkedAt: string? }
export type Opened = { repo: string, number: number, title: string, author: string, at: string }   -- hub.recent, newest first, at most RECENT_CAP

M.RECENT_CAP = 8                      -- picker.luau:62
M.PROBE_EVERY, M.REFRESH_EVERY, M.DEBOUNCE, M.CHECKS_EVERY = 60, 300, 30, 30   -- seconds

function M.load(raw: any): Cache?     -- nil for anything malformed or not schema 1; never throws
function M.save(cache: Cache, capBytes: number, size: (value: any) -> number): any
	-- The value for kv. Drops the oldest `lastActivityAt` first until `size(value) <= capBytes`.
	-- `size` is injected (the block passes `#tern.json.encode(v)`), so this stays pure.
function M.merge(fresh: Refresh, previous: Cache?, localFacts: Local, now: number): Cache
	-- Sets `tandem` and `addedByMe`, carries `pending` over while `headOid` is unchanged, rebuilds `counts`.
function M.loadMerge(raw: any): MergeRecord?
function M.mergeEvidence(record: MergeRecord?, viewerDefault: "squash" | "merge" | "rebase"): MergeEvidence
function M.openedList(saved: any): { Opened }                     -- picker.luau:65, moved
function M.remember(list: { Opened }, opened: Opened): { Opened } -- picker.luau:83, moved

export type Arrival = { key: string, reasons: { Reason }, toast: boolean }   -- toast: any reason but a conflict
export type Changes = {
	firstLoad: boolean,               -- no previous cache: no ring, no toast
	arrivals: { Arrival },            -- entered needs_fixes from outside it, and not suppressed
	good: { string },                 -- entered ready or approved: the green wash
	toast: { text: string, sub: string? }?,   -- one per refresh: "#396 needs fixes: merge failed", or "3 pull requests need fixes"
}
function M.diff(old: Cache?, fresh: { HubPR }, now: number, suppressed: { [string]: boolean }): Changes
	-- `suppressed` holds the keys the viewer just acted on. Inactive PRs never arrive.

export type ScheduleInput = {
	now: number,
	refreshedAt: number?,             -- the last full refresh, re-read from `hub.cache` every tick so windows share work
	refreshing: boolean,
	probedAt: number?,
	probeChanged: boolean,            -- the last probe saw a change that no refresh has covered
	focusedAt: number?,               -- a focus the block has not refreshed for yet
	checksAt: number?,
	running: { string },              -- node ids of PRs with running checks
}
export type Schedule = { probe: number, refresh: number?, checks: number? }   -- seconds from now until due; 0 is now; nil is off
function M.schedule(input: ScheduleInput): Schedule
	-- probe: PROBE_EVERY after the last one. refresh: REFRESH_EVERY after the last, or sooner when a probe saw a change
	-- or the hub regained focus, but never within DEBOUNCE of the last. checks: CHECKS_EVERY, only while `running` is not empty.
```

### `src/hub/agent-fix.luau` (the agent run state machine)

```luau
export type LineTag = "base" | "ours" | "theirs" | "agent"   -- ours is the viewer's branch; theirs is the base branch merged in
export type ResolvedLine = { tag: LineTag, text: string }
export type ConflictHunk = {
	id: string, path: string, start: number,
	base: { string }, ours: { string }, theirs: { string },
	context: { before: { string }, after: { string } },
	subjects: { ours: { string }, theirs: { string } },        -- subjects of the commits on each side
	resolved: { by: "rule" | "agent", lines: { ResolvedLine } }?,
}
export type Stage = "worktree" | "merge" | "rules" | "agent" | "commit"
export type Run = { key: string, stage: Stage, since: number, worktree: string?, hunks: { ConflictHunk }, left: number }
export type Fix = {
	worktree: string, branch: string, base: string,
	headOid: string,                  -- the PR head the agent started from; Push refuses when the remote head moved
	commit: string, hunks: { ConflictHunk }, summary: string, usedAgent: boolean,   -- usedAgent false: a clean merge, zero tokens
}
export type Event =
	{ kind: "stage", stage: Stage } | { kind: "worktree", path: string }
	| { kind: "hunks", hunks: { ConflictHunk } } | { kind: "resolved", id: string, by: "rule" | "agent", lines: { ResolvedLine } }
	| { kind: "committed", commit: string, summary: string } | { kind: "failed", reason: string } | { kind: "stopped" }
export type Outcome =
	{ kind: "running", run: Run } | { kind: "ready", fix: Fix } | { kind: "failed", reason: string, worktree: string? } | { kind: "stopped" }
function M.start(key: string, now: number): Run
function M.step(run: Run, event: Event): Outcome
```

`tools/conflicts` prints JSON on stdout and exits 0 on success, 1 when a hunk is unknown or conflicts remain, 2 on bad usage. It runs in the worktree it is called from and needs no Tern.

| Command | Output |
|---|---|
| `list` | `{ "hunks": [{ "id", "path", "start", "lines" }], "generated": [path] }` |
| `show <id>` | one `ConflictHunk` without `resolved` (a few context lines, bounded) |
| `take <id> ours\|theirs\|both` | `{ "id", "taken" }` |
| `write <id>` | reads the replacement from stdin; `{ "id", "lines" }` |
| `check` | `{ "remaining": number }`; exit 1 when above 0 |

### `src/hub/summary.luau` (pure; read-only Summarize)

```luau
export type Summary = { verdict: string, comments: { { author: string, text: string } } }   -- "Reply to @maria-k", then one line per commenter
function M.prompt(details: FixDetails): string
function M.parse(text: string): Summary?
function M.onlyComments(details: FixDetails): boolean    -- the only reason is comments, so A summarizes
```

### `src/hub/state.luau` (interaction state and the prepared board)

```luau
export type Mode = "board" | "search" | "link" | "menu" | "confirm" | "help"
export type MenuId = "repositories" | "sort" | "agent" | "merge" | "actions"
export type CardAction = { act: string, value: string?, label: string, key: string?, confirm: boolean }

export type AgentFixState =
	{ kind: "no_clone", slug: string }
	| { kind: "running", run: AgentFix.Run }
	| { kind: "ready", fix: AgentFix.Fix, reviewed: { [string]: boolean } }    -- `reviewed` holds reviewedConflictIds
	| { kind: "pushing", fix: AgentFix.Fix }
	| { kind: "failed", reason: string, worktree: string? }
-- A ready fix is "reviewed" once `reviewed` holds every hunk id: State.reviewed(fix, reviewed): boolean.

export type Card = {
	pr: HubPR, column: Column, reasons: { Reason },
	main: CardAction?,                -- the split button's action
	more: { CardAction },             -- behind the attached ▾
	agent: AgentFixState?, summary: Summary?, merge: MergeResolution?,
	ring: ("bad" | "good")?,          -- the arrival ring, until it fades
	selected: boolean, marked: boolean,
}
export type RepoOption = { repo: string, count: number, on: boolean }

-- Everything a view reads, built by State.project. Views never filter, sort or classify.
export type BoardData = {
	tab: Tab,
	columns: { { column: Column, cards: { Card } } },   -- the tab's columns, left to right, filtered and ordered
	inactive: { Card },                                 -- the fold under "Your pull requests"
	recent: { Opened },                                 -- the fold under "Review requests"
	grid: { { string } },                               -- keys per column, for h j k l
	counts: { mine: number, review: number },           -- your-turn cards per tab: the blue counts
	repositories: { RepoOption },
	open: { inactive: boolean, recent: boolean },       -- which folds show their rows (a search opens Inactive)
	nextUp: NextUp?,
	empty: boolean,
}

-- The agent's model and effort, and the models the ⇧M menu offers. nil until the block has found the agent.
export type AgentModel = { selector: string, name: string, efforts: { string } }
export type AgentChoice = { models: { AgentModel }, model: string, effort: string? }

export type State = {
	prs: { HubPR }, now: number,
	board: BoardData,                 -- rebuilt by State.project after any input below changes
	tab: Tab,
	selected: string?, marked: { [string]: boolean },
	repositories: { [string]: boolean }?,
	sort: Sort,
	search: Fields.Field, link: Fields.Field,
	mode: Mode, menu: MenuId?, menuCursor: number,
	confirm: { kind: string, keys: { string } }?,
	folded: { [string]: boolean },    -- true: the fold is closed; Inactive and Recently opened start closed
	walking: boolean,                 -- Next up is being walked: the banner shows "2 of 11"
	ringed: { [string]: "bad" | "good" },
	agents: { [string]: AgentFixState },
	details: { [string]: FixDetails }, summaries: { [string]: Summary },
	merges: { [string]: MergeResolution },    -- by repo
	refreshedAt: string?, loading: boolean, error: Error?,
	agent: AgentChoice?,
	narrow: boolean,                  -- the pane is split beside a terminal: the columns stack
	keyed: boolean,                   -- as src/state.luau:108
	born: { [string]: string }, booted: boolean,   -- arrival motion, as src/state.luau:113
}

function M.new(prs: { HubPR }, now: number, saved: any): State
function M.project(s: State)                 -- recomputes s.board from s.prs and the inputs
function M.mode(s: State): Mode
function M.reviewed(fix: AgentFix.Fix, reviewed: { [string]: boolean }): boolean
```

Every file in `src/view/hub/` exports `function M.view(s: State.State, motion: Ui.Motion): Node`, plus `M.layer(s): Node?` where it has an overlay.

### `src/keys.luau` (hub keys)

```luau
function M.hubAction(s: HubState.State, key: Key): Action?   -- the hub's counterpart of `M.action` (keys.luau:98)
function M.hubAfterTyping(mode: HubState.Mode, outcome: Fields.Outcome): Action?   -- after a key typed into the search field
```

`I` shows or hides Inactive (the fold is a control, so it has a key). A card's action keys (`A`, `⇧A`, `C`, `M`, `U`, `,`, `X`) come from the selected card's `main` and `more`, so a click and a key send the same `Card.main.act`.

`M.pickerAction` (`:109`) is deleted with the picker. Typing modes (`search`, `link`) return nil for letters, as `searchKey` does (`:22`).

### `src/hub/block.luau` (glue)

```luau
export type Timers = { probe: TimerHandle?, refresh: TimerHandle?, checks: TimerHandle?, debounce: TimerHandle?, ring: TimerHandle? }
-- #5 declares `s`, `fixture`, `generate` and `agent`; the GitHub client, cache, timers and flights arrive with #4.
export type Block = {
	s: State.State, cache: Sync.Cache?,
	agent: Agent.Agent?,              -- the reader's omp, once found (never with a fixture)
	github: Github.Client, timers: Timers,
	flights: { refresh: boolean, checks: boolean, probe: boolean },   -- one call of each kind at a time
	fixture: string?,                 -- `fixture=cases`: no network, no timers
	generate: boolean,                -- ⏎ opens the PR with the AI guide started
	closed: boolean,
}
export type Saved = { tab: Tab, sort: Sort, repositories: { string }?, folded: { [string]: boolean } }
-- `BlockDef<Block>`: init(cx, args, saved), title, view, key, event, save — as src/block.luau:686.
```

The hub has its own `ACTIONS` table, sent by clicks (`event`) and by `Keys.hubAction` (`key`). It owns the timers, the `tern.kv` reads and writes, and `cx:toast`. A window can send it an action event; `hub-focused` and `set-generate` are the two the window half sends.

### `src/fetch.luau` (additions)

`src/fetch.luau` keeps local git, treehouse, `omp` and Tandem CLI calls, and one new export: `M.runner: Github.Runner`, which resolves `gh` and the shell's PATH the way `run` does (`:69-121`). The agent engine, Fix bot comments and the Tandem hand-off add their own functions here, each in the `(value?, err?)` style above.

## How this maps onto Tern

### Registration and the one hub per window

- **Registration.** `plugin.toml` gets `[[blocks]] id = "hub"` beside `guide` (`plugin.toml:9-12`), with `palette = false` as `guide` has, because the commands open it. `host.luau` gains `tern.block.define("hub", require("./src/hub/block"))` (`host.luau:1`; `tern.block.define` is `tern.d.luau:1885-1887`). The module returns a `BlockDef<Block>` with `init`, `view`, `key`, `event` and `save` (`tern.d.luau:271-291`). Its pane kind is `prguide.hub`.
- **`openHub(cx, generate)`** lives in `window.luau` and replaces `pick` (`window.luau:2-10`). It scans `cx.session:panes()` (`tern.d.luau:1445`) for a pane whose `block == "prguide.hub"` (`PaneInfo.block`, `:392`).
  - Found and parked (`PaneInfo.parked`, `:377`): `cx.layout:unpark(pane)` (`:1487`), which deals it into the current tab.
  - Found otherwise: `cx.layout:focus(pane)` (`:1466`).
  - Not found: `cx:new_block("prguide.hub", args, "tab")` (`:1596`), with `args = { "generate=true" }` when `generate`.
  - Opening with `generate` while a hub exists sends it `cx.session:event(pane, { ev = "action", act = "set-generate", value = "true" })` (`:1443`). **[INFERENCE]** that an action event without a node id reaches the block's `event`. The one-way-in issue checks it in Tern and, if it doesn't, sends the event with the id of a node the view always has.
- **Callers.** The ⌥⌘R command (`review`), the ⌥⇧⌘R command (`generate`) and the status segment all call `openHub`. Command ids stay, so existing key bindings and `plugin.prguide.review` keep working. Their palette titles become "PR hub" and "PR hub, AI guides". The **New PR Guide sample block** command stays, and a **New PR hub sample block** command (`hub-sample`) opens `prguide.hub` with `fixture=cases`.
- **Block arguments** follow `options` in `src/block.luau:452-471`: `name=value`, unknown names rejected with a message. The hub takes `generate=true|false` and `fixture=<name>`.

### Opening a card's PR

`BlockCx` has no `new_block`; `WindowCx` does (`tern.d.luau:1141-1160`, `:1596`). The block therefore asks the window half to open it:

1. The block resolves the card's `owner/repo` with the existing resolver: `Fetch.checkoutFor(near, dir, slug, done)` (`src/fetch.luau:388`), then `Fetch.savedCopy(host, slug)` (`:445`) when it finds none. `dir` is `cx.cwd` (`tern.d.luau:1145`), else `HOME`. When neither gives a repo, the block shows a toast with the reason and opens nothing.
2. It calls `cx:open(url)` (`tern.d.luau:1134-1135`, which goes through the window's `route.link`) with `https://github.com/<owner>/<repo>/pull/<n>#prguide-open=<url-encoded root>`, plus `&generate=true` for ⇧⏎ or ⌥⇧⌘R.
3. `window.luau` registers `tern.route.link` (`:1928`) and claims only links carrying `#prguide-open=`, answering `{ block = "prguide.guide", args = { "pr=<n>", "repo=<root>", "generate=true"? } }` (`RouteDecision`, `:1011-1025`). The guide requires `repo=` with `pr=` (`src/block.luau:469`).
4. A link the route doesn't claim opens GitHub's own page, so a missing route degrades to the browser.

### The status segment

`window.luau` registers `tern.chrome.status(function(pane) ... end)` (`tern.d.luau:1939`). It returns one `StatusSegment` (`:955-964`) such as "PRs · 2 to review · 10 need fixes", with `command = "plugin.prguide.review"` and `tone = "error"` while flashing.

- **The formatter only reads.** It reads `hub.cache` with `tern.kv.get` and uses `Cache.counts`. It never fetches, and it is pure per input (`:1931-1932`).
- **The block can't refresh chrome.** `tern.chrome.refresh` is window only (`:1943`). `window_start` (`:1909`) starts a one-shot window timer that re-arms itself every 15 s, re-reads `hub.cache`, and calls `tern.chrome.refresh()` when `refreshedAt` or `counts` changed, and once when `flashAt` plus 10 s passes so the flash ends. It never calls it from the formatter (that raises, `:1942`).
- **The segment is hidden** (the formatter returns nil) while no cache exists.

### Timers and visibility

- **Timers.** `tern.timer(ms, fn)` calls `fn` once and returns a `TimerHandle` (`tern.d.luau:1746`) whose `cancel()` has no effect once fired (`:1124-1128`). Every poll is therefore a one-shot that re-arms itself. `src/hub/block.luau` stores each handle in `Block.timers` (`probe`, `refresh`, `checks`, `debounce`, `ring`), cancels the old handle before arming a new one, and sets each delay from `Sync.schedule`. Timers start after `init` returns, as the guide's do (`src/block.luau:697`).
- **Visibility is not observable from a block.** `BlockCx` has `render`, `save`, `exit`, `frame` and `blob`, and no focus, visibility or close hook (`tern.d.luau:1141-1160`); `BlockDef` has no close hook (`:271-291`). Focus and `parked` are readable only in the window half (`FocusEvent` `:1102`, `PaneInfo.parked` `:377`). So **the hub polls for as long as the block exists**, parked or in a background tab, and the "while visible" figures below mean "while the block exists".
- **Focus refresh** comes from the window: `tern.on("focus", ...)` (`:1907`) checks whether the focused pane is a `prguide.hub` block and sends it `cx.session:event(pane, { ev = "action", act = "hub-focused" })` (`:1443`). The block records `focusedAt`, and `schedule` applies the 30 s debounce.
- **Closing the block.** There is no unmount hook, so the block can't be told to stop. Each timer callback first checks `Block.closed`, and a failing `cx:render()` (called under `pcall`) sets it and ends the chain. **[INFERENCE]** that a closed block's `cx:render()` raises. The state issue verifies it: close the hub, then confirm no `gh` process starts for 6 minutes. The shared cache bounds the damage if it doesn't hold: every tick re-reads `hub.cache` and skips a refresh when `refreshedAt` is within the debounce, so a leaked chain costs the free probe, not GraphQL points.
- **Named timers, each with an acceptance check** (the sync issue's `schedule` tests drive them from a fake clock): probe every 60 s, checks every 30 s while a check runs, refresh every 5 min, a 30 s debounce on changes and focus, and a ring that fades after the arrival.

### kv keys and caps

`tern.kv` is a JSON store shared by both halves and every window (`tern.d.luau:1751-1759`). It documents no size limit, so the limits below are our own safety budget **[INFERENCE]**. Reads and writes raise on a bad store, so they sit in `pcall`, as `src/fetch.luau:583` does.

| Key | Holds | Cap |
|---|---|---|
| `hub.cache` | `Sync.Cache`, schema 1: normalized records only | at most 50 PRs per search query; the serialized value at most 1 MiB, evicting the oldest `lastActivityAt` first; if the write still fails the block keeps its in-memory state and shows the error |
| `hub.recent` | `{ Opened }`, migrated from the picker's `recent` key | 8 entries |
| `hub.added` | `Sync.Added`: PRs added by link | 50 entries |
| `hub.clones` | slug (`owner/repo`) → the clone path the viewer chose ("Choose folder…"), for the agent's clone lookup | one per repo |
| `hub.merge.<owner>/<repo>` | `Sync.MergeRecord` | one per repo |

Never store raw GraphQL, tokens or diffs. Only `src/hub/block.luau` reads and writes these keys. The guide's `model`, `runSeconds` and the retired `recent` keys stay in `src/fetch.luau`, which deletes `recent` after the migration. AGENTS.md's Boundary and Glue lines are amended in the PRs that add `src/github.luau` and `src/hub/block.luau`, so they name those modules next to `src/fetch.luau` and `src/block.luau`.

### Picker retirement

The picker is `src/picker.luau`, `src/view/picker.luau`, and the picker paths in `src/block.luau` and `src/keys.luau`. The hub replaces it, so the one-way-in issue does this in order, in one PR:

1. **Migrate** (everything below has a new home before anything is deleted):
   - the 8-entry recent store (`Picker.openedList`, `remember`, `RECENT_CAP`, `Opened`; `Fetch.recentPrs`, `rememberPr`, `RECENT_KEY`) moves to `Sync` and `hub.recent`. On first load of the hub, a missing `hub.recent` is filled from `recent`, and `recent` is deleted. `Fetch.rememberPr` keeps being called when the guide opens a PR;
   - link and number parsing (`named`, `linkRepo`, `linkHost`, `reference`, `remoteRepo`, `sameRepo`) moves to `src/links.luau`. Its callers are `src/block.luau:590,602,718` and `src/fetch.luau:372,431,439`;
   - `epoch` and `ago` move to `model`; `guideNumbers` (`src/fetch.luau:352`) becomes a local helper of `fetch.luau`.
2. **Preserve** in the Review requests fold: ⏎ and a pasted link open the PR, a number alone is refused when it names no repo, and a PR appears once, newest first.
3. **Delete** `src/picker.luau`, `src/view/picker.luau`, `Keys.pickerAction`, `PICKER_ACTIONS`, `pickerKey`, `pickerDispatch`, `showPicker`, `openPicker` and the `picker` field and branches of `src/block.luau`, `Fetch.listAnywhere`, `Fetch.listPrs`, `Fetch.guidedPrs`, and the `gp-pk-*` rules of `guide.css`. A guide block launched with `repo=` and no `pr=` shows "Open a pull request from the PR hub (⌥⌘R)" instead of a picker.
4. **Update** the README, PRODUCT.md and the `docs/screenshots/picker.png` mention in the same change.

### Mockups are references, Tern is the implementation

Product code follows `docs/ui.md:38-40`, not the mockups' CSS.

- **Use:** flexbox (no grid), native `overlay` nodes in `BlockView.layer` (`tern.d.luau:262-269`) for menus, the help panel and confirms, and `cx:toast(level, text, sub)` (`:1133`) for toasts. Tern's `kbd` and `icon` nodes, and `light-dark()` pairs for colors.
- **Don't copy:** `position: absolute` menus, toast and scrim (`index.html:216`, `:319`, `:341`, `:350`, `:398`); `:has()` (`:283`); `rgb(from …)` (`:33`, `:163`, `:199`). Use explicit state classes and fixed `light-dark()` washes instead.
- **No SVG and no grid** appear in the mockups, and the product adds none. `position: sticky` with `backdrop-filter` is for Tern glass only (a nested `backdrop-filter` fails inside the glass header, so menus are overlays).
- **Tokens.** `docs/tern-tokens.css` lacks Tern's `--tk-*` syntax colors, which `review-fix.html` and `pr-fixes.html` copy locally. **#5 adds them to the token file**, and owns DESIGN.md's component and color additions: washed action cards, status chips, the split button, boxes, amber for running CI and purple for agent and Tandem work. #18 adds the agent chip.

### The clipboard

Tern's clipboard is plain text: `cx:copy(text)` (`tern.d.luau:1136-1137`, and `WindowCx` `:1606`). Nothing in `tern.d.luau` takes an HTML flavor. **Copy link** copies `"<title> <url>"` as plain text, and that passes. A rich HTML link through `osascript` in `src/fetch.luau` is optional. If it's added, it needs its own test: paste into a rich-text field and check it keeps the title as a hyperlink.

### Platform constraints

- **Host API:** `tern.timer`, `tern.process.run`, `tern.fetch`, `tern.kv` (`plugin-data/prguide/kv.json`), `tern.fs`, `cx:toast(level, title, body)`, the window-only `tern.chrome` (status-line segments and tab titles), `WindowCx:new_block`. Type definitions: `tern.d.luau` at the repo root.
- **No OS notifications or tab badges for plugins.**
- **CSS:** flexbox only (no grid), `light-dark()`, keyframes, transitions, `position: sticky`. **No SVG:** use text glyphs or Tern's named icons.
- **Untested in Tern:** reduced-motion handling.
- **`luau` has no file or env access** (`io` and `os.getenv` are nil in `/opt/homebrew/bin/luau`, checked). Tests can't read files, so fixtures are `.luau` modules (see Verification).

### What the plugin does today

- **The picker** calls `gh pr list`, `gh search prs --review-requested=@me` / `--author=@me` and `gh pr view` (`src/fetch.luau` around lines 457–501). It keeps the 8 most recently opened PRs in kv. Any pasted PR link opens. The hub replaces it (see Picker retirement).
- **Opening a PR** costs one `gh pr view`. Everything else is local git, fetched into `refs/prguide/<n>/*`. Guides are stored at `<common git dir>/prguide/<n>.json`.
- **Module rules (AGENTS.md):**
  - Only `src/fetch.luau` reaches outside the plugin. The hub adds `src/github.luau` (it starts processes only through the runner `fetch.luau` hands it) and lets `src/hub/block.luau` read and write kv.
  - Only `src/block.luau` does effects, and every action is one `ACTIONS` entry that both clicks and `keys.luau` send. The hub's counterpart is `src/hub/block.luau`.
  - Views live in `src/view/*` and only build nodes.
  - Styles go in `guide.css` with `gp-` classes.
  - A new key goes in `view/help.luau` and the README's Keys table.

## Verification

### Tests

```
tests/run.luau              runs every test module; any failed assert makes it exit non-zero
tests/model_test.luau       tests/links_test.luau     tests/github_test.luau
tests/sync_test.luau        tests/state_test.luau     tests/agent_fix_test.luau
tests/fake-runner.luau      a scripted `Github.Runner`
tests/conflicts.sh          the `tools/conflicts` tests: throwaway git repos with conflicts, the five commands run for real (a shell script because `luau` has no process API)
fixtures/hub/…              see the fixture plan
```

```sh
/opt/homebrew/bin/luau tests/run.luau
tools/luau-fixtures --check
tern plugin reload
```

- **Plain `assert`** with literal expected values written independently of the code under test. Each test module returns a function; `run.luau` calls them all, names the one that failed, and rethrows.
- **Pure modules only.** Tests `require` `links`, `model`, `fixes`, `github`, `sync`, `state`, `agent-fix` and `summary`. Never `fetch`, `block`, `window` or a view: `fetch.luau` touches `tern` at load, and the views need Tern's nodes.
- **Frozen clock.** Every rules test passes a fixed `now`, and `cases.luau` records it as `asOf`. No test reads the clock.
- **Specific assertions the early issues must hold:**
  - `model`: every fixture key lands in its expected column and order, including 16 conflict cases (stale, active, draft), and the negatives: a bot's comment, "LGTM", and an approved PR with a leftover thread never make Needs fixes.
  - `github`: `parseHub`, `parseThreads` and `parseChecks` consume the recorded responses. A fake runner asserts that `hub-f` sends no thread authors, and that the summed `rateLimit.cost` over a refresh is at most 18 (hub-f 9 plus threads 9). Each call keeps its own envelope; the figure is re-measured after the query changes and updated here.
  - `sync`: `schedule` and `diff` run on a fake clock from 0 to 3600 s. The probe fires at 60 s, a change or focus triggers a refresh within the 30 s debounce, checks poll at 30 s only while a check runs, and the total cost stays at most 220 points.

### Fixture plan

`luau` can't read files, so each recorded JSON has a generated `.luau` twin.

| File | What it is |
|---|---|
| `fixtures/hub/raw-hub-f.json` | A recorded `hub-f.graphql` response, redacted. It needs the extended query below. |
| `fixtures/hub/raw-threads.json` | A recorded `threads.graphql` response, with unresolved threads by people and by bots. |
| `fixtures/hub/raw-checks.json` | A recorded `checks.graphql` response with running, failing and passing PRs. |
| `fixtures/hub/raw-*.luau` | Generated by `tools/luau-fixtures` from the JSON: `return { … }`, with null members dropped as `tern.json.decode` does. Both files are committed. `--check` fails when a twin is stale. |
| `fixtures/hub/cases.luau` | Normalized `HubPR` records, `asOf`, the expected column and order per sort, the expected Next up keys, and a `refreshes` list: successive caches with `suppressed`, the expected rings, and the expected toast text (or none). Readable by the CLI and by the fixture block (`fixture=cases`). |

Later issues add their own fixtures (`merge-methods`, `selection`, `details`, `fixes`, `flake`, `rereview`, `agent`, `summary`, `tandem-*`), each with `asOf` where time matters.

**The extended `hub-f.graphql`.** It doesn't select several fields the rules need. Before recording, add `additions`, `deletions`, `changedFiles`, `createdAt`, `baseRefName`, `autoMergeRequest { enabledAt }` and the latest `RemovedFromMergeQueueEvent` (`timelineItems(last: 1, itemTypes: [REMOVED_FROM_MERGE_QUEUE_EVENT])`, with its `reason`). Add a `pullRequest(number:)` alias per PR added by link. **Re-measure its cost and time** against the 9 points in the table above, and update the table, the 18-point test limit and the budget. `threads.graphql` and `checks.graphql` gain `id`. Never add thread authors to the search (159 points).

### The fake runner

`tests/fake-runner.luau` builds a `Github.Runner` from a script: each entry matches an argv prefix and returns `{ status, stdout, stderr, timed_out }`. It records every call's argv, `stdin` and `cwd`. An unmatched call fails the test. Every command builder and every `Client` method has a test that asserts the exact argv sent (for example, squash is `gh pr merge <n> --repo <owner/repo> --squash`) and that nothing else ran. No test touches the network.

### Live GitHub actions

- **Only in a disposable repository** named by `GH_HUB_SMOKE_REPO` (for example `you/tern-pr-guide-hub-smoke`), with no branch protection.
- `tools/hub-smoke` seeds it: it opens test PRs (one clean, one behind main, one conflicted, one with a failing workflow) and cleans up by closing them and deleting their branches. It refuses to run without `GH_HUB_SMOKE_REPO`, and every `gh` call it makes passes `--repo "$GH_HUB_SMOKE_REPO"`.
- A tester merges, updates a branch, comments, labels, closes, re-runs and re-requests review **only on cards of that repo**.
- **`post=false` protects review posting only** (`src/block.luau:456,470`, `Fetch.submitReview`). It is not a dry run for merge, update-branch, comment, label, close, re-run or re-request actions.
- Merge methods that need another service (Aviator, a merge queue) are checked against their recorded fixtures, not live.

### UI checklist

Run it against the fixture block (**New PR hub sample block**, `fixture=cases`, a frozen clock, no network). Repeat every row in **light and dark** (switch Tern's theme), at two sizes:

| Size | Hub |
|---|---|
| Wide | the window at 1440 × 900, the hub alone in its tab |
| Split | the hub pane 720 px wide beside a terminal (`index.html:23` uses 720 px) |

Record `cx.cols` and `cx.rows` (`tern.d.luau:1146-1149`) with each run. Save screenshots to `/tmp/hub-checks/` as `hub-<light|dark>-<wide|split>-<step>.png`.

| # | Do | Expect |
|---|---|---|
| 1 | `⌥⌘R` | One hub opens. Press `⌥⌘R` again: no second pane, the hub is focused. Park the hub, `⌥⌘R`: it comes back. Focus another pane, `⌥⌘R`: it is focused again. `⌥⇧⌘R` with a hub open: still one, and its ⏎ now starts the AI guide. |
| 2 | `T`, `T` | The tab switches and switches back. Blue counts show only your-turn cards. |
| 3 | `/`, type, Esc | Focus enters the search field and the list filters. `j` types into it. Esc clears it and returns to the board. |
| 4 | `F` | The repository menu opens without animation: `j`/`k` move, Space toggles, ⏎ or Esc closes. |
| 5 | `S`, each of the five sorts | The order matches `cases.luau` for that sort, including Smallest first. |
| 6 | `h j k l` and the arrows | Up and down stay in a column; left and right go to the nearest card in the next column. **No card changes height** when selected or hovered, with six or more long titles and a mix of draft and stale cards (compare the card's top-to-next-top distance before and after). |
| 7 | `?`, then Esc | The grouped shortcut panel opens, and Esc closes it. A click outside also closes it. |
| 8 | `.` repeatedly | Next up visits the keys in `cases.luau`'s Next up list, switches tabs when needed, shows "n of N", and ends hidden when nothing needs you. The cursor never moves on open. |
| 9 | `⌘R` in the fixture block, once per `refreshes` entry | First load: no ring, no toast. A merge-failed arrival: red ring, segment flash, toast "#396 needs fixes: merge failed". Three arrivals: one toast "3 pull requests need fixes". A conflict-only arrival: ring, no toast. An inactive PR: nothing. A PR the viewer just merged or fixed: nothing. A PR that became ready: green wash, no toast. |
| 10 | `⌥⌘R` twice more, then close the hub | The status segment shows the counts, flashes red on an arrival, and its click focuses the hub. After closing, no polling continues (see Timers). |

### Per-PR gates

Every PR passes these before review:

1. `/opt/homebrew/bin/luau tests/run.luau` and `tools/luau-fixtures --check` exit 0.
2. `tern plugin reload` exits 0 and loads both `prguide.guide` and `prguide.hub`.
3. The UI-checklist rows the PR touches pass in light and dark, wide and split, and the screenshots are attached.
4. A PR with live GitHub actions has them tried in `GH_HUB_SMOKE_REPO`, nowhere else.
5. `GUIDE.md`, `prompts/guide.md` and `src/guide.luau` still change together when the guide changes; a new key is in `view/help.luau` and the README Keys table.

## How to build this

- **Base.** Branch every issue from `docs/pr-hub-design` and open its PR against that branch. **One PR per issue**, and the issue's `Touches only` list is the PR's file list. A PR opens only after every issue it depends on has merged, and it rebases onto the branch first.
- **Commits.** Each subject is the user-visible behavior as a plain sentence, with no type prefix (AGENTS.md, Commits).
- **Shared files.** No two issues edit the same shared file at once. The files are `src/hub/block.luau`, `src/hub/state.luau`, `src/hub/model.luau`, `src/github.luau`, `src/fetch.luau`, `src/keys.luau`, `src/view/hub/`, `guide.css`, `AGENTS.md` and `tests/run.luau`. The order below is the serialization: a later issue builds on the earlier one's merged contract, and changes a contract here first. The one allowed overlap is #3 and #5, which each append lines to `tests/run.luau` and `AGENTS.md`; the second to merge rebases onto the first.
- **Order:**
  1. **v0.** #2 (rules, fixtures, test runner) → #3 (GitHub data) and #5 (board, built against `fixture=cases`) in parallel → #4 (sync) → #6, #7, #8 in that order.
  2. **v1.** #9 → #10 → #12 → #11 → #13 → #14. #10 comes before #11 and #14, and #12 before #13 and every later consumer of the details contract.
  3. **v2.** #15 (agent engine) → #18 (agent card lifecycle) → #16 (Review fix, Push and Discard) → #19 (Fix bot comments and Summarize) → #20 (Tandem hand-off). The Tandem PR is a separate PR in the Tandem repo, so it can be built any time, but **it must merge before #20's plugin side**.
- **The Tandem PR.** It goes in https://github.com/jdeocampo99/tandem as its own PR, based on `main`, and adds the native verb `pr-fix` (see Tandem below).

## Tandem (we own it)

- **pr-watch** (`src/pr-watch/`, state in `~/.tandem/state.sqlite`) polls GitHub through gh every 1–5 min. It doesn't see review requests or the need to re-review.
- **"Waiting on Tandem"** comes from `tandem watch [PR] --json`.
- **Handing off a PR needs a new verb.** `tandem native act` only accepts a coordinator's own pane (`src/native/actions.ts:175-258`), so a hub request would be refused. Add a verb such as `pr-fix {repo, number, reason}` with a plugin origin rule, mapped onto the existing `pr-watch-fix` tool (`src/session/tools.ts:357-369`).
- **The Tandem PR** is separate, in https://github.com/jdeocampo99/tandem on its default branch `main`, and merges before the plugin side of the hand-off. Native verb `pr-fix`: request `{ repo: string, number: number, reason: string }`, response matching the native outcome `{ status: "done" | "kept" | "refused", notice: string? }`. It accepts the plugin's origin and refuses any other, maps onto `pr-watch-fix`, and ships fixtures for success and refusal. "Waiting on Tandem" shows after `done`.
- **Worktrees** come from treehouse, from Tandem's pool:
  - acquire: `treehouse --root ROOT get --lease --lease-holder prguide --no-fetch --json` (cwd is the repo's clone);
  - return: `treehouse --root ROOT return PATH --if-lease-holder prguide --if-lease-id ID`;
  - root: `TANDEM_POOL_ROOT`, else `~/.tandem/pool`.
- **Clone lookup:** Tandem's `repo_locations` table (`src/repos/locate.ts:39-61`), or the plugin's own map in kv when Tandem isn't installed. A missing repo is cloned with `gh repo clone owner/repo DEST -- --filter=blob:none --no-checkout`, after asking once.
- **Tandem's conflict fixing** hands the whole job to an AI (`src/pr-watch/watcher.ts:731-737`). It should adopt the token-light pipeline above.

## Build plan

Ship in stages that each work end to end. Each stage is a commit series that `tern plugin reload` accepts and that can be tried with a real PR opened with `post=false`.

| Stage | Scope | Why this order |
|---|---|---|
| **v0: the board** | Data layer (a `HubPR` record, kv cache, hub-f + threads + checks queries, `/notifications` probe, the poller); both tabs and their columns; filter, sort (including Smallest first), search; h j k l; ⏎ opens the existing review view; Copy link; Merge for the three GitHub methods with ⌘⏎; add by link; arrival ring, status-line segment and toast; one way in (⌥⌘R opens or focuses the hub, the status-line segment opens it, Recently opened becomes a fold); sizes on review cards | Read-mostly and low-risk. It replaces the picker as the daily entry point and proves the cost and polling plan. |
| **v1: less hunting** | The fixes page (⏎ on Needs fixes); per-repo merge methods (declared, learned, comment, label, queue) and Merge failed; Summarize; the friction items below marked v1 | Each item turns "open GitHub and find it" into one key. No writes beyond comments, labels and merges. |
| **v2: agent work** | Fix with agent, Fix bot comments, Review fix, Push; treehouse; clone lookup; the `conflicts` tool; the Tandem `pr-fix` verb | The largest, and it writes code and pushes, so it builds on a trusted v0 and v1. |

**Build checks:**
- `tern plugin reload` exits 1 if the plugin fails to load.
- Check UI in light and dark.
- `GUIDE.md`, `prompts/guide.md` and `src/guide.luau` change together.

## Open questions

- **Queue position:** "2nd in line" needs the merge tool's own API (Aviator's sticky comment, or a token). Without it, the card says "waiting for the merge".
- **Copy link:** plain "title url" is the acceptance. A rich HTML link through `osascript` is optional and, if added, must be tested.
- **DESIGN.md additions** are owned by #5, together with the `--tk-*` syntax tokens in `docs/tern-tokens.css`. Confirm amber for running CI and purple for agent and Tandem work before adding them. The Components section should document washed action cards, status chips, the split button and boxes. #18 adds the agent chip.
- **`pr-fixes.html` wording:** on #418, a Tandem repo, the page says "Fix with agent" where the hub says "Hand off to Tandem". The page should use the hub's wording.

## Friction backlog

All rows are approved by the user; ideas the user didn't pick were dropped. Each item turns a trip to GitHub, or a return visit, into one key.

| # | Idea | Stage | Design |
|---|---|---|---|
| 1 | **Next up** | v1 | **A banner above the board** (chosen): one quiet gray line, sized to its content and left-aligned, reading left to right: Next up · the item's chip · its title · "web #412 · 11 left" · **Go** [.]. It walks everything that needs you across both tabs, most urgent first; `.` or a click goes to the next item, switching tabs when needed. The hub never moves the cursor on open (an automatic jump felt random). The count becomes your position while walking ("2 of 11"). In split view the repo and count drop out. Hidden when nothing needs you. Rejected: a blue control in the tab row, a label in the hint bar, a header button, and a count beside the title (`nextv=header\|title` keep them for comparison). |
| 2 | **Re-run failed checks** | v1 | Behind Fix checks ▾ for every failing check. Moves first, with the label "Likely flaky", only when the evidence says so (see below). Never re-runs on its own. `gh run rerun <id> --failed`; zero tokens. |
| 3 | **Update branch** | v0 | A Ready card whose branch is behind main (`mergeStateStatus == BEHIND`, no conflicts) shows "Behind main" and **Update branch** (U) as its main action, because strict branch protection blocks the merge until then. `gh pr update-branch`; zero tokens. The card then waits for checks in In review. |
| 4 | **Merge when ready** | v1 | Behind the ▾ on In review cards. Once set, the card shows "Merges when ready" and needs nothing more. Uses `gh pr merge --auto` (needs the repo's "Allow auto-merge" setting; hidden when it's off), or, for comment-based repos, the merge command posted early (Aviator accepts `/aviator merge` while a PR is still pending). |
| 5 | **Re-request review** | v1 | Driven by state, not a toast: when a reviewer's latest review requested changes and you've pushed since, the In review card reads "Waiting on @maria-k to re-review", and its main action is **Re-request review** (`gh pr edit --add-reviewer`). |
| 7 | **Size and Smallest first** | v0 | +84 −12 on review cards, and a "Smallest first" sort. The current hub-f query doesn't fetch `additions` and `deletions`: #3 adds them (see Verification). |
| 8 | **Merge several** | v1 | Space marks cards (as in file managers); M then merges the marked ones in queue order, after one confirm that lists them. Each uses its repo's merge method. |
| 9 | **Close stale PRs** | v1 | Space selects cards in Inactive, and **Close stale** (⇧X) in the fold header selects every stale PR but skips drafts (drafts are deliberate work in progress, so only Space selects them). One confirm lists them. No closing comment by default. `gh pr close`. |
| 10 | **One way in** | v0 | See below. |

**Mocked in `index.html`:** Next up (1), Update branch (3, on #181), Merge several (8) and Close stale (9).
- **Next up:** the tab-row control described in row 1.
- **Selecting:** Space or ⌘/⇧-click selects; Esc clears. A selected card gets a blue wash, with a blue box in place of its gutter check.
- **The selection bar** sits at the top of Ready to merge (or inside Inactive): "2 selected · Merge 2 (M) · Clear (Esc)".
- **The confirm** lists at most 5 titles plus "and N more", then one line on how they merge (for example "Comments /merge"), or "Closed pull requests can be reopened."
- **Only mergeable cards can be selected:** a card that's behind main or already queued can't be.
-

**Flake evidence (friction item 2, issue #13).** All checks are cheap, and the results are cached per repo:
- **History:** the same check (name and workflow) failed on recent main commits without a fix in between, for example "failed 3 of the last 20 runs on main". **3 or more failures in the last 20 runs on main means likely flaky, and 1 or fewer means not**; two is not enough alone. Fetched per repo about hourly from the Actions runs API.
- **Same code, different result:** the check passed on an earlier run of this same commit, or on the previous commit when the new commit didn't touch the failing area.
- **Failure text:** timeouts, network resets, rate limits, a lost runner, out-of-memory (exit 137) mean infrastructure, not code.
- **Annotations outside the diff:** the errors point only at files the PR didn't change.
- The card says why: "Likely flaky: failed 3 of the last 20 runs on main". When an annotation points at a changed file, the failure is treated as real and **Fix with agent** stays first.

**One way in (friction item 10, issue #6).** Today the palette has "New PR review block" (⌥⌘R) and "New AI generated PR review block" (⌥⇧⌘R), each opening a picker (`window.luau:11-12`, via `tern.command`). The hub replaces the picker:
- **⌥⌘R opens the hub**, or focuses it if one is already open, so there's one hub per window. Picking a PR is just ⏎ on its card, and pasting a link is the To review field. Two entry points to the same list would be clutter.
- **⌥⇧⌘R** opens the hub too, but ⏎ there opens the PR with the AI guide started. On any card, ⇧⏎ does the same.
- **The status-line segment** ("PRs · 2 to review · 10 need fixes") runs the same command on click. `StatusSegment.command` takes `plugin.prguide.<id>`.
- **The picker's "Recently opened"** (PRs you opened from any repo) moves to a fold under Review requests, so a closed PR stays one key away.

Proposals rejected so far: automatic pushes, "Fix all", toasts for conflicts, and automatic re-runs.

## Mockup reference

**Files** (in `docs/hub/mockups/`):
- `index.html`: the hub. Variant F is the approved one; G and H are kept for comparison.
- `pr-fixes.html`: the fixes page.
- `review-fix.html`: the Review fix page.
- GitHub query research is in `docs/hub/queries/`: `hub-f.graphql`, `threads.graphql`, `checks.graphql`, `probe.graphql` and a redacted `sample.json`.

**index.html URL params:**

| Param | Effect |
|---|---|
| `t=dark\|light` | Theme |
| `w=wide\|split` | Width |
| `tab=mine\|rev` | Starting tab |
| `agent=1` | Seeds the agent states: #169 running, #177 fix ready, #174 failed, #77 no local copy, #404 summarized |
| `sel=<repo>%23<n>` | Selects a card |
| `confirm=1` | Opens the merge confirm |
| `sort=` | Starting sort |
| `repos=` | Starting repository filter |
| `menu=repo\|sort\|agent` | Opens a menu |
| `act=below\|bar` | The rejected button placements, for comparison |

**Mock bar:** demos for checks passing, approval, an agent fix, and a merge failing, plus a link to the Review fix page.

**Sample merge settings:** acme/web is declared Aviator, Tagalingo-App has a learned `/merge` (not yet confirmed), tern-pr-guide rebases, and every other repo squashes.

**Other pages:**
- `pr-fixes.html`: `pr=58|404|418`, `t=`, `cur=`, `focus=panel`, `bot=1`, `reply=1`, `noann=1`.
- `review-fix.html`: `t=`, `cur=1`, `rv=1`, `orig=1`, `ask=1`, `open=1`.

## Design history (why it looks like this)

- **A–E (lists and sections, including E3)** were replaced by F. Your PRs and your review queue are different processes, so tabs stop them competing for attention.
- **Button placement:** "buttons below the selected card" made cards jump and hid what each card needed. "Buttons at the top right" crowded the chip line and overflowed with long status chips. The final rule is the hover/selection swap on the repo line.
- **"Paste a link" in search** was ambiguous, so To review got its own field.
- **Hard-coded Aviator support** became the general per-repo merge method.

## User preferences

- Very short replies; screenshots for UI work.
- UI copy is neutral and official, like GitHub. Every label says what's needed from the user. No filler copy.
- Keyboard first, with vim keys.
- Push back when you disagree.
