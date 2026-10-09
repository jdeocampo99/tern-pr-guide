# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

Rendered by Tern's own HTML/CSS engine inside a terminal-app block, not a browser. See Capabilities and Constraints for what that engine can't do.

## Users

Engineers who use Tern and review their teammates' GitHub pull requests often, sometimes several a day and sometimes PRs too large for GitHub's own UI to handle well. They know the codebase and GitHub's review conventions, and they want to work through a PR without leaving the terminal app.

## Product Purpose

PR Guide turns a GitHub pull request into a guided review inside Tern. The reader sees what the PR does first: a plain overview, then an optional before/after diagram. Then they walk through it change by change, with the code beside a plain explanation. They comment, then post one review back to GitHub.

Success means all four of these hold:

- The reader understands the PR faster than they would on GitHub.
- The comments they post are better: short, specific and kind, and they agree with them.
- The whole loop stays in Tern: pick, read, comment, submit.
- It stays fast on huge PRs. Speed is a product promise.

## Positioning

The PR is read as a story, not a wall of files. The overview comes first, then a few changes, each with small steps the reader ticks off, with code and its exact lines highlighted beside each step. Diffs are built locally with git, so GitHub's diff size cap doesn't apply. The page draws only the code near the reader, so an 85-file PR and a 5,600-line file stay fast. The AI reviewer runs on the user's own OMP agent and model, and a lens steers it (Balanced, Security, Architecture, Quick skim, Teaching, or user-written).

## Operating Context

- Opened from Tern's command palette (**New PR review block**, `⌥⌘R`; **New AI generated PR review block**, `⌥⇧⌘R`). It works inside a clone or anywhere else. A picker lists open PRs, and recently opened PRs from any repo sit at the top.
- Keyboard-first: every action has a key (`j`/`k` steps, `⏎` reviewed, `/` search, `r` review, `⌘⏎` submit, `?` all shortcuts).
- Depends on `gh` (logged in), `git`, and optionally `omp` for AI reviews. Reviews are stored at `.git/prguide/<n>.json`, in the format documented in `GUIDE.md`.
- Posting to GitHub takes a two-press confirm. Dry runs (`post=false`, and the sample block) save to `/tmp` instead.

## Capabilities and Constraints

- **Two views, equal standing.** The AI guided review is the headline feature. The plain GitHub-style file view (Files, `t`) is a fully supported first-class path, not a degraded fallback. Comments, drafts, the summary and ticks are shared between the two views.
- **AI is optional at runtime.** Without `omp` or a model there is no Generate button, and everything else works.
- **Follows GitHub's rules.** Comments go only on changed lines, and a comment range stays within one block of changes. The review is Comment, Approve or Request changes, posted as a single review. Nothing is posted if the PR got new commits while the reader was on the page.
- **Rendering limits (Tern).** Layout is flex only. Pinned elements use `position: sticky`. Plugins get no scroll events. Every color is a `light-dark()` pair. There's no SVG, so icons are text glyphs or the host's named icons. The page draws about 600 lines of code at once at most.
- **Code layout.** Only `src/fetch.luau` touches the outside world. `src/block.luau` owns window effects. Views in `src/view/` turn state into nodes. All styling lives in `guide.css` with `gp-` classes. `GUIDE.md`, `prompts/guide.md` and `src/guide.luau` change together.
- **Terminology:** review, guided review, change, step, supporting changes, suggestion (an AI-suggested comment), lens, Guided | Files, mark reviewed, dry run.

## Brand Commitments

- Name: **PR Guide**. Distributed as a Tern plugin at `github.com/jubbydev/tern-pr-guide`.
- Voice for UI copy: official, neutral, plain and short, like GitHub. Labels are sentence case and start with the verb. Progress reads "Loading…". Failures read "Couldn't …: reason". Empty states read "No …". Use nouns over "you". No exclamation marks, emoji or marketing words.
- AI-suggested comments read like a kind, busy teammate: short, specific, friendly.
- Follows GitHub's conventions where they exist.

## Evidence on Hand

- README screenshots in `docs/screenshots/`: overview, step, search, review, whole file, picker.
- Sample data: `fixtures/pr-350.json`, `fixtures/guide-350.json`, and the built-in **New PR Guide sample block**.
- Performance claims in the README (85-file PR, a 5,600-line file opens instantly) come from the author's own use.
- No user counts, testimonials or external benchmarks exist. Don't invent them.

## Product Principles

1. **Understanding before judgment.** Explain what the PR does before asking the reader to evaluate it.
2. **Speed is a feature.** No design choice may cost responsiveness on huge PRs or make keypresses feel slow.
3. **Stay in place.** Every step of a review completes in Tern. Leaving for GitHub is optional, never required.
4. **The reviewer owns the review.** AI suggests and the human decides. Nothing posts without an explicit, confirmed action.
5. **Both paths are first-class.** The plain file view gets the same care as the guided review.

## Accessibility & Inclusion

Keyboard-complete: every action has a key, shown beside its label. Respects `prefers-reduced-motion`. Light and dark themes are both supported and must both be checked.
