# PR Guide

**Review GitHub pull requests in Tern, one step at a time.**

PR Guide turns a pull request into a story you read piece by piece. Instead of a wall of files, you
see what the PR does, then walk through it change by change, with the code right beside a plain
explanation.

![The review page: a plain-language overview, a before/after diagram, and the first change](docs/screenshots/overview.png)

## Why use it

- **The whole review happens in Tern.** Pick a PR, read it, comment, and submit, all without
  opening a browser.
- **Fast, even on huge PRs.** Diffs are built locally with git, and the page only draws the code
  near you. An 85-file PR stays snappy and a 5,600-line file opens instantly.
- **Does what you'd do on GitHub.** Read the description, comment on any changed line, then
  comment, approve, or request changes as one review.
- **An AI reviewer you choose.** One button (or `⇧G`) has your own [OMP](https://omp.sh) agent read
  the PR and write a guided review, in the spirit of Linear Diffs. Pick any model and effort level
  OMP offers, and a [lens](#review-lenses) such as Security or Teaching to steer what it looks for.
- **The PR as a story.** The review opens with a short overview and a before/after diagram, then
  breaks the PR into a few changes, each with small steps you tick off as you go.
- **Comments you'd actually post.** Suggested comments are written like a kind, busy teammate:
  short, specific, and friendly. Keep the ones you agree with, drop the rest.
- **Works without AI too.** Any PR opens as a GitHub-style file tree, one file at a time.

## What it does

**Starts with the big picture.** A short overview anyone can follow, and an optional before/after
diagram of what the PR changes. The author's own description is one click (or `i`) away.

**Walks you through the code.** Each change has a sticky card on the left with its steps; the code
for the step you're on sits on the right with its exact lines highlighted, removed ones included.
Steps on one file share a single block, each numbered in the gutter. `j`/`k` move between steps, `⏎` marks a step reviewed and
moves on. **Mark all reviewed** in the header (`m`) ticks every file at once, and pressing it again clears them.

**Two ways to read it.** A PR with a guide opens guided. The **Guided | Files** switch in the header
(or `t`) flips to the plain GitHub-style file tree, one file at a time, and back. Your comments, drafts,
summary and ticks are the same in both, and each view remembers the step or file you were on; the
page itself starts at the top.

![A step with its code and a suggested comment](docs/screenshots/step.png)

**Suggested comments, if you want them.** The AI review comes with suggested review comments. Add the
ones you agree with (`a`), dismiss the rest (`d`), or write your own: hover a changed line and click
`+`, or press `c` on a step.

**Finds anything.** `/` searches steps, files, comments and changed code, and jumps straight to the
line.

![Search across steps, files, comments and code](docs/screenshots/search.png)

**Posts one review.** `r` opens your review: tick the comments to include, edit the summary, pick
Comment, Approve or Request changes, and submit with `⌘⏎`. The first press only asks: the button
turns orange and reads "Post to GitHub? Press ⌘⏎ again". Press `⌘⏎` (or click it) again to post;
any other key, `esc`, or closing the panel cancels. Everything goes to GitHub as a
single review. If the PR got new commits while you were reading, nothing is posted and the page
tells you.

![Finishing a review](docs/screenshots/review.png)

**Handles big PRs and big files.** Changes are computed locally with git, so it isn't limited by
GitHub's diff size cap. Show a whole file and the changed parts stay marked while long untouched
stretches use Tern's own fast code viewer: a 5,600-line file opens instantly. The page also only
draws the code near where you are, so an 85-file PR stays responsive.

![A 5,600-line file shown whole, with the removed lines still marked](docs/screenshots/whole-file.png)

## Install

```sh
tern plugin install github.com/jubbydev/tern-pr-guide
```

You also need the [GitHub CLI](https://cli.github.com) logged in (`gh auth login`). A local clone
of the repository isn't required.

To work on the plugin itself, clone it and use `tern plugin link /path/to/tern-pr-guide` instead.

## Review a PR

Press `⌥⌘R` (or choose **PR hub** in the command palette) to open the PR hub. It is the one way
in: your pull requests and the ones waiting for your review sit on a board, and `⏎` on a card opens
it in the guide. Pressing `⌥⌘R` again focuses the hub you already have, so each window has one.

`⌥⇧⌘R` (**PR hub, AI guides**) opens the same hub, but `⏎` opens the PR with the AI review started
(see [AI guided review](#ai-guided-review)). On any card, `⇧⏎` does the same. To use other keys, bind
the actions `plugin.prguide.review` and `plugin.prguide.generate` in Tern's keybind settings.

The status line shows a **PRs** segment ("PRs · 2 to review · 10 need fixes") once the hub has
loaded. It turns red for a few seconds when a pull request starts needing fixes, and clicking it
opens or focuses the hub. The hub refreshes when you switch back to it, at most every 30 seconds.

PRs you opened lately, from any repo, sit under **Recently opened**, a fold under Review requests
(`R` shows or hides it), so a PR you closed is one `⏎` away. A PR link opens from any directory:
the guide finds your clone of that repo, or makes its own copy (see
[Good to know](#good-to-know)). **New PR Guide sample block** in the palette opens a built-in
sample, so you can try it without a PR.

Submitting posts to GitHub after that confirm step. To rehearse without posting, open the page
from Lua with `post=false`: the button reads "Save (dry run)" and the review is saved to
`/tmp/prguide-review-<n>.json` instead. The sample page is always a dry run.

**Advanced / scripting.** The page is the block `prguide.guide`:

```lua
cx:new_block("prguide.guide", {"pr=123", "repo=/path/to/your/clone"}, "tab")
```

| Argument | Meaning |
|---|---|
| `repo=` | path inside your local clone (or, with a PR link, any folder to look in); it needs `pr=`, and on its own the block points to the PR hub |
| `pr=` | PR number or URL, opened straight away |
| `guide=` | a saved review (JSON) to open instead of the clone's; see [GUIDE.md](GUIDE.md) |
| `post=false` | dry run: save the review to `/tmp/prguide-review-<n>.json` instead of posting |
| `generate=true` | start the AI guided review as soon as the PR opens; a PR that already has a review just opens |

Behind the scenes it runs `gh pr view` once, fetches the PR into `refs/prguide/<n>/*` in a clone
(your branches and working tree are untouched), and diffs locally. Lockfiles and files marked
`linguist-generated` are left out. Remove the refs afterwards with
`git update-ref -d refs/prguide/<n>/head` (and `/base`).

## AI guided review

With [OMP](https://omp.sh) installed, a PR without a guided review shows a **Generate AI Guided
Review** button, with the lens, model and effort it will use beside it. Click it (or press `⇧G`) and
your agent reads the PR and writes the review; the page turns into the walkthrough when it's done.
It takes a few minutes, and you can keep reading meanwhile.

To skip the button, press `⌥⇧⌘R` (**PR hub, AI guides**) and open a PR from the hub: the review
starts as soon as it opens, with the model and lens you last picked. A PR that
already has a review just opens, and if OMP or a model isn't available the PR opens as usual with a
note saying why.

- Click the model, or press `⇧M`, to pick another: type to search the models OMP lists, `↑`/`↓` for
  the model, `←`/`→` for the effort, `⏎` to use it. Your pick is remembered for every PR.
- Until you pick one, it uses your OMP review model: `modelRoles.review` in
  `~/.omp/agent/config.yml`, else `modelRoles.default`. Without `omp` on your login shell's PATH or
  a model, there is no button.
- It runs on your model, so it costs about what a normal AI review does.
- Reviews are saved in the clone (worktrees share them, and nothing is committed), so reopening a
  PR is instant and never runs the AI again.

## Review lenses

A lens tells the AI what to look for. Pick one in the same menu as the model (click it, or press
`⇧M`, then click a lens or use `⇧←` `⇧→`). Your pick is remembered, and a finished review says which
lens it was written with.

- **Balanced** (the default): a clear walkthrough of the whole PR.
- **Security**: reads the PR like an attacker, flagging anything that could be misused.
- **Architecture**: how the change fits the codebase, and what it will cost to live with.
- **Quick skim**: the big picture in a few steps, and only the comments that matter.
- **Teaching**: explains the code for someone new to it.

**Add your own.** Choose **Edit lenses…** in the menu (or press `⌃E`). It opens your lenses folder,
with a README that explains the format. A lens is one markdown file: a `# Name`, a line saying what
it's for, then your instructions.

```markdown
# Performance

Hunts for slow paths and wasted work.

Look for work done in loops that could be done once, queries inside loops, needless copying, and
blocking calls on hot paths. Only comment on things that would matter at scale.
```

A lens with the name of a built-in one replaces it. The review is always written in the same format,
whatever a lens says.

## For tool authors

A review is a JSON file at `.git/prguide/<number>.json` in the clone. Any tool (a script, another
AI, a person) can write one, and the page uses it when that PR opens. The format is in
[GUIDE.md](GUIDE.md).

## Keys

Anywhere in Tern: `⌥⌘R` opens the PR hub and `⌥⇧⌘R` opens it with AI guides (see
[AI guided review](#ai-guided-review)).

| Reading | | Reacting | | Finishing | |
|---|---|---|---|---|---|
| `j` `k` | next / previous step | `⏎` | step reviewed, move on | `r` | open your review |
| `n` `p` | next / previous suggestion | `⇧⏎` | whole change reviewed | `x` | include or leave out |
| `/` | search | `v` | whole file reviewed | `a` | include / exclude all |
| `s` | supporting changes | `a` `d` | add / dismiss suggestion | `1` `2` `3` | comment, approve, request changes |
| `o` | open every supporting file | `c` | comment on this step | `⌘⏎` | submit |
| `g` | open on GitHub | | | `?` | all shortcuts |
| `i` | PR description | `m` | mark / unmark all reviewed | | |
| `t` | guided / file view | | | | |

### PR hub keys

**New PR hub sample block** opens the PR hub on recorded sample data (`fixture=cases`; `fixture=rereview` shows Merge when ready and Re-request review; `fixture=review-fix` shows a retained fix with three conflicts in two files).

| Move | | The selected card | | The board | |
|---|---|---|---|---|---|
| `h` `j` `k` `l` / arrows | move between cards | `⏎` / double-click | open (Needs fixes opens the fixes page; Fix ready opens Review fix) | `/` | search |
| `.` | next pull request that needs you, across both tabs | | | | |
| `T` | switch tab | `A` | fix with agent, Stop, Try again, Clone repo, or summarize | `F` | filter by repository |
| | | `O` | choose an existing clone folder, or open a failed fix's retained worktree | | |
| `I` | show or hide Inactive | `⇧⏎` | open with the AI guide started |
| `R` | show or hide Recently opened (Review requests) | `⇧A` | summarize feedback, or Return worktree on a card Tandem watches whose failed fix still holds its worktree | `S` | sort |
| | | `C` | copy link | `⇧M` | agent model |
| | | `M` | merge (a GitHub merge asks first: `⌘⏎` confirms, `Esc` cancels), Merge when ready (In review cards), or cancel a merge in flight | `N` | add a pull request by link |
| | | `Space` | select the card for Merge selected or Close stale (also `⌘`-click or `⇧`-click) | `⇧X` | select every stale pull request that isn't a draft |
| | | `M` `X` | with a selection: merge it (Ready) or close it (Inactive), after one confirm | `⌘⏎` | confirm a question |
| | | | | `Esc` | clear the selection, cancel or close |
| | | `U` | update branch (Ready cards that are behind main) | `?` | all shortcuts |
| | | `,` | merge method (also the `▾` on Merge) | `⌘R` | refresh (the sample board steps through its recorded refreshes) |
| | | `⇧R` | re-run failed checks (behind the `▾` on Fix checks; first when the card says "Likely flaky") | | |
| | | `Q` | re-request review (when a reviewer is waiting on a re-review) | | |
| | | `X` | remove from Review requests (pull requests you added) | | |

**Fixes page.** `⏎` on a Needs fixes card opens the pull request at what needs fixing, in the guided
review's layout. The left column lists the problems as steps, grouped Requested changes, Comments,
Failing checks and Merge conflicts; the right shows the code for the step on show. A comment or
requested change is pinned at its line. A failing check's annotation is pinned at its line (annotations
under `.github/` and "Process completed with exit code" lines are dropped). A conflict shows "Your
branch" and the base branch side by side, and "Main changed this in #415" when the base's last commit on
that file names its pull request. A pull request that needs fixes only because a merge failed opens with
the reason. Bot comments are listed apart under "Not counted". The page reads GitHub once when it opens
(1 point); conflicts and annotated source come from your clone of the repo (or PR Guide's saved copy),
and without one the conflict step says "No local copy of owner/repo". The button next to the title
shows the card's own wording ("Fix with agent", "Hand off to Tandem").

| Fixes page | | | |
|---|---|---|---|
| `j` `k` / arrows | next / previous step, or action in the code | `R` | reply to the thread (`⌘⏎` posts, `Esc` cancels) |
| `h` `l` / arrows | between the steps and the code | `E` | resolve the thread |
| `⏎` | go to the code, or choose the highlighted action | `⇧L` | view the check's log on GitHub |
| `A` | the card's action ("Fix with agent") | `G` | open on GitHub (the conflict editor for a conflict) |
| `B` | show or hide the bot comments | `⇧R` | re-run failed checks |
| | | `Esc` | back to the board, card still selected |

Reply and Resolve write to GitHub straight away; the sample block applies them to the page only.

**Re-run failed checks** (`⇧R`, behind the `▾` on a Needs fixes card with a failing check, and on the
fixes page) runs `gh run rerun <id> --failed` for each failing workflow run, once per press and never on
its own. It costs no AI tokens. When the evidence says a failure is likely flaky, Re-run moves first
on the card and the card says why, for example "Likely flaky: failed 3 of the last 20 runs on main".
Evidence is any of: the same workflow failed 3 or more of its last 20 runs on the base branch; it passed
earlier on this commit; the failure text names the infrastructure (timeout, network reset, rate limit,
lost runner, exit 137); or every annotation points at a file the pull request didn't change. An error in
a file the pull request changed means the failure is real: nothing else counts, and Fix with agent stays
first. A base branch's run history is read once an hour per repository (one call to GitHub's Actions API).

**Merge** uses the repository's merge method and shows GitHub's reason when it refuses. Each repository
has one method: squash and merge, create a merge commit, rebase and merge, merge when ready (GitHub's
merge queue), comment a command (`/merge`, `/aviator merge`), or add a label. The method comes from
your choice (`,` or the `▾` on Merge), else what the repository declares (`.aviator/config.yml`, a
merge queue), else a habit seen in its last 8 merged pull requests (a bot merged after a person
commented `/merge`), else your GitHub default. The hub asks once before using a learned command, and `Esc` declines it for good. A comment,
label or queue method merges at once with no question; the card then reads "Commented /merge ·
waiting for the merge" or "Queued in Aviator", and `M` cancels it (the method's cancel comment, removing
the label, or turning off auto-merge). A comment method with no cancel can't be cancelled. In the
chooser, "Comment a command" and "Add a label" ask for text; for a comment, add `| /cancel` to name its
cancel comment. The hub never uses GitHub's merge on a repository that merges by comment, label or queue.

A merge that fails (removed from the merge queue, an Aviator or bot reply, or a check that failed after
the merge was asked for) moves the pull request to Needs fixes as **Merge failed**, first in line, with
the reason on the card. A new commit on the branch, or asking for the merge again, clears it.
**Copy link** copies the title and link as plain text.

**Merge when ready** sits behind the `▾` on In review cards (`M`). It sets GitHub's auto-merge
(`gh pr merge --auto` plus the repository's method flag, such as `--squash`; the merge queue needs only
`--auto`), or posts the repository's merge command early for a comment method, and the card then reads
"Merges when ready". `M` cancels it. It is hidden where the repository's "Allow auto-merge" setting is off
(read from GitHub once per session with the merge-method check, 1 point), and until that is known. A merge
command that is only a learned suggestion is asked on a Ready card first.

**Re-request review.** When a reviewer's latest review asked for changes and you pushed since, the pull
request stays in In review, and the card reads "Waiting on @maria-k to re-review" with **Re-request
review** (`Q`) as its action. It asks every such reviewer again (`gh pr edit --add-reviewer`), and the
action goes away once they are asked.

**Add a pull request by link:** `N` (from either tab) opens the field at the top of To review.
Paste a `github.com/owner/repo/pull/123` link or type `owner/repo#123`. `⏎` adds it to Review
requests as "Added by you" (up to 50), `⇧⏎` opens it without adding. For a pull request already on
the board, `⏎` shows it and `⇧⏎` opens it. `X` removes one you added.

After a failed fix, **Open worktree** (`O`) appears only while the agent still holds its lease.
If returning the lease failed, **Try again** (`A`) retries that return before starting another fix.
The hub keeps the lease handle until it is returned, including when the hub closes. A Fix ready
worktree stays in place for review. **Review fix** (`⏎` or double-click on Fix ready) shows only the
conflict resolutions from that commit. Each line is marked main, Your branch, or Agent; shared context
has no ownership badge. Rules that took both sides are reviewed in the same way.

| Review fix | Action |
|---|---|
| `j` `k` / `↑` `↓` | next or previous conflict |
| `⏎` | mark the selected conflict reviewed or unreviewed |
| `B` | switch between the resolution and original conflict |
| `P` | push to the PR branch once every conflict is reviewed |
| `D` | ask to discard the fix; `⌘⏎` or Ctrl+Enter confirms |
| `Esc` | cancel Discard, or return to the board with the card selected |

Push sends the exact reviewed commit with a plain git push, including for a fork's branch. It refuses
if the branch head changed. A clean merge with no conflicts is already reviewed. A push failure keeps
the fix, ticks and lease for retry. After a successful push the lease is returned; if returning it fails,
`P` retries the return without pushing again. Discard resets only the leased worktree and returns its
lease. It never writes to the remote. A failed return keeps the fix and asks again on `D`.

In a menu, `j` `k` move, `Space` chooses (a repository toggles), `⏎` chooses or closes, `Esc` closes, and in the agent menu `←` `→` change the effort.

## Good to know

- GitHub only accepts review comments on lines the PR changed, so only those lines get a `+`, and a
  comment range stays within one block of changes.
- A link to a PR in another repo opens from your clone of that repo when there is one in the same
  folder as this clone (for example both in `~/Code`). Without one, PR Guide downloads a light copy
  of the repo (history only, no files; even a huge repo takes about half a minute) into its own
  folder, `~/Library/Application Support/Tern/plugin-data/prguide/repos/<owner>/<repo>.git`, the
  first time you open a PR of it. Later PRs of that repo reuse the copy, and saved AI reviews live
  there too. Delete the folder any time to reclaim the space. Private repos work through `gh`'s login.
- To keep every keypress fast, the page draws at most about 600 lines of code at once. Steps further
  away show just their file header and open when you reach them or click them.
