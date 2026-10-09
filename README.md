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
for the step you're on sits on the right. `j`/`k` move between steps, `⏎` marks a step reviewed and
moves on. **Mark all reviewed** in the header (`m`) ticks every file at once, and pressing it again clears them.

**Two ways to read it.** A PR with a guide opens guided. The **Guided | Files** switch in the header
(or `t`) flips to the plain GitHub-style file tree, one file at a time, and back. Your comments, drafts,
summary and ticks are the same in both, and each view remembers where you were.

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
tern plugin install github.com/jdeocampo99/tern-pr-guide
```

You also need the [GitHub CLI](https://cli.github.com) logged in (`gh auth login`). A local clone
of the repository isn't required.

To work on the plugin itself, clone it and use `tern plugin link /path/to/tern-pr-guide` instead.

## Review a PR

Open the command palette, choose **New PR review block**, and pick a PR. It works from any
terminal, inside a clone or not, and any GitHub PR link opens: paste it and press `⏎`.

PRs you opened lately, from any repo, sit at the top under **Recently opened**, so a PR you closed
is one `⏎` away.

In a terminal inside a clone, the picker lists that repo's open PRs, the one for your branch first.
Type to filter by number, title, author or branch, or paste a PR number or link. Anywhere else, it
lists your open PRs across GitHub: the ones waiting for your review first, then your own. Type to
filter (the repo name counts too). A bare number doesn't say which repo, so paste the link there.

![Picking a pull request](docs/screenshots/picker.png)

Two shortcuts work anywhere in Tern: `⌥⌘R` opens **New PR review block**, and `⌥⇧⌘R` opens **New AI
generated PR review block**, which starts the AI review as soon as you pick a PR (see
[AI guided review](#ai-guided-review)). To use other keys, bind the actions `plugin.prguide.review`
and `plugin.prguide.generate` in Tern's keybind settings. **New PR Guide sample block** in the
palette opens a built-in sample, so you can try it without a PR.

Submitting posts to GitHub after that confirm step. To rehearse without posting, open the page
from Lua with `post=false`: the button reads "Save (dry run)" and the review is saved to
`/tmp/prguide-review-<n>.json` instead. The sample page is always a dry run.

**Advanced / scripting.** The page is the block `prguide.guide`:

```lua
cx:new_block("prguide.guide", {"pr=123", "repo=/path/to/your/clone"}, "tab")
```

| Argument | Meaning |
|---|---|
| `repo=` | path inside your local clone; on its own, it opens the picker |
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

To skip the button, choose **New AI generated PR review block** (`⌥⇧⌘R`) in the palette and pick a
PR: the review starts as soon as it opens, with the model and lens you last picked. A PR that
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

Anywhere in Tern: `⌥⌘R` opens **New PR review block** and `⌥⇧⌘R` opens **New AI generated PR
review block** (see [AI guided review](#ai-guided-review)).

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

## Good to know

- GitHub only accepts review comments on lines the PR changed, so only those lines get a `+`, and a
  comment range stays within one block of changes.
- The picker lists up to 50 open PRs. For any other PR, paste its link (or, in a clone, its number).
- A link to a PR in another repo opens from your clone of that repo when there is one in the same
  folder as this clone (for example both in `~/Code`). Without one, PR Guide downloads a light copy
  of the repo (history only, no files; even a huge repo takes about half a minute) into its own
  folder, `~/Library/Application Support/Tern/plugin-data/prguide/repos/<owner>/<repo>.git`, the
  first time you open a PR of it. Later PRs of that repo reuse the copy, and saved AI reviews live
  there too. Delete the folder any time to reclaim the space. Private repos work through `gh`'s login.
- To keep every keypress fast, the page draws at most about 600 lines of code at once. Steps further
  away show just their file header and open when you reach them or click them.
