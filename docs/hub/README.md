# PR hub: design spec

A hub page for PR Guide. It shows every open PR you wrote and every PR waiting on your review, across repos, sorted by who needs to act next. This folder holds the approved design: this spec, clickable mockups in `mockups/` and the measured GitHub queries in `queries/`. **No plugin code has been written yet.**

**Status:** design approved and split into GitHub issues: parent [#17](https://github.com/jubbydev/tern-pr-guide/issues/17), with sub-issues #2–#16 labelled `hub` and `v0`/`v1`/`v2`. Each sub-issue names the modules it may touch and what it depends on. Start with #2 (rules) and #3 (GitHub data); they don't depend on each other.

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
  - Sort options: Repository (the default, with Priority order inside each repo), Priority, Newest first, Oldest first.
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
| In review | **Copy link** (C): a rich link, so Slack pastes the title as a hyperlink | |
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
| `docs/hub/queries/hub-f.graphql`: 3 searches (author, review-requested, reviewed-by), check counts, author types | 9 pts | 6–8 s | On a change, on focus (debounced to 30 s), and every 5 min while the hub is visible |
| `threads.graphql`: thread authors via `nodes(ids:)`, only for PRs with an unresolved thread whose `updatedAt` changed | 9 pts for 17 PRs | 0.7 s | After hub-f |
| `checks.graphql`: CI state for PRs with running checks | 1 pt for 5 or 40 PRs | 1–1.5 s | Every 30 s while any check is running |
| REST `/notifications` with `If-Modified-Since` | free (304) | | Every 60 s, as the change probe |
| Fixes-page details: threads with path/line/body, changes-requested reviews, failing check runs with annotations | 1 pt | | When a Needs fixes PR is opened |
| Learning a repo's merge habit: last 8 merged PRs with `mergedBy` and comments | 1 pt | | Once per repo |

- **Don't** put thread authors inside the search query. Measured at **159 points** per call.
- **Budget:** about 220 pts/hr while the hub is visible. Even the 30 s debounce ceiling (about 2,200/hr) fits the 5,000/hr GraphQL budget, which Tandem's pr-watch shares.
- **Latency is the real cost.** Always render from the kv cache first, then refresh in the background.
- **Check annotations include noise.** Drop paths under `.github/` and messages like "Process completed with exit code". Measured on Tagalingo-App #1013, the useful one was `src/lib/query-persister.ts:39 Type …`.
- **Conflicted files** come from local `git merge-tree --write-tree --name-only`, not GitHub.
- **Your real data:** 36 open PRs you wrote across 7 repos (20 in Tagalingo-App), 16 with conflicts, and 1 review request.

## Platform constraints (Tern)

- **Host API:** `tern.timer`, `tern.process.run`, `tern.fetch`, `tern.kv` (plugin-data/prguide/kv.json), `tern.fs`, `cx:toast(level, title, body)`, the window-only `tern.chrome` (status-line segments and tab titles), `WindowCx:new_block`. Type definitions: `tern.d.luau` at the repo root.
- **No OS notifications or tab badges for plugins.**
- **CSS:** flexbox only (no grid), `light-dark()`, keyframes, transitions, `position: sticky`. **No SVG:** use text glyphs or Tern's named icons. Menus should be a native Tern `overlay` in its own layer, because a nested `backdrop-filter` fails inside the glass header.
- **Untested in Tern:** reduced-motion handling, and whether the clipboard accepts an HTML flavor. The fallback for Copy link is `osascript` through `src/fetch.luau`.
- **`docs/tern-tokens.css`** doesn't include Tern's `--tk-*` syntax colors. `review-fix.html` and `pr-fixes.html` copy them locally; add them to the token file.

## How the plugin works today (integration points)

- **The picker** calls `gh pr list`, `gh search prs --review-requested=@me` / `--author=@me` and `gh pr view` (`src/fetch.luau` around lines 457–501). It keeps the 8 most recently opened PRs in kv. Any pasted PR link opens.
- **Opening a PR** costs one `gh pr view`. Everything else is local git, fetched into `refs/prguide/<n>/*`. Guides are stored at `<common git dir>/prguide/<n>.json`.
- **Module rules (AGENTS.md):**
  - Only `src/fetch.luau` reaches outside the plugin.
  - Only `src/block.luau` does effects, and every action is one `ACTIONS` entry that both clicks and `keys.luau` send.
  - Views live in `src/view/*` and only build nodes.
  - Styles go in `guide.css` with `gp-` classes.
  - A new key goes in `view/help.luau` and the README's Keys table.

## Tandem (we own it)

- **pr-watch** (`src/pr-watch/`, state in `~/.tandem/state.sqlite`) polls GitHub through gh every 1–5 min. It doesn't see review requests or the need to re-review.
- **"Waiting on Tandem"** comes from `tandem watch [PR] --json`.
- **Handing off a PR needs a new verb.** `tandem native act` only accepts a coordinator's own pane (`src/native/actions.ts:175-258`), so a hub request would be refused. Add a verb such as `pr-fix {repo, number, reason}` with a plugin origin rule, mapped onto the existing `pr-watch-fix` tool (`src/session/tools.ts:357-369`).
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
- **Copy link** depends on whether Tern's clipboard accepts HTML.
- **DESIGN.md additions:** confirm amber for running CI and purple for agent and Tandem work before adding them. The Components section should document washed action cards, status chips, the split button and boxes.
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
| 7 | **Size and Smallest first** | v0 | +84 −12 on review cards, and a "Smallest first" sort. The fields are already fetched. |
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

**Flake evidence for #2.** All checks are cheap, and the results are cached per repo:
- **History:** the same check (name and workflow) failed on recent main commits without a fix in between, for example "failed 3 of the last 20 runs on main". Fetched per repo about hourly from the Actions runs API.
- **Same code, different result:** the check passed on an earlier run of this same commit, or on the previous commit when the new commit didn't touch the failing area.
- **Failure text:** timeouts, network resets, rate limits, a lost runner, out-of-memory (exit 137) mean infrastructure, not code.
- **Annotations outside the diff:** the errors point only at files the PR didn't change.
- The card says why: "Likely flaky: failed 3 of the last 20 runs on main". When an annotation points at a changed file, the failure is treated as real and **Fix with agent** stays first.

**One way in (#10).** Today the palette has "New PR review block" (⌥⌘R) and "New AI generated PR review block" (⌥⇧⌘R), each opening a picker (`src/window.luau:11-12`, via `tern.command`). The hub replaces the picker:
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
