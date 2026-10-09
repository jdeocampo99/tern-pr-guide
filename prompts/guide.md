# Write a guided review for {{repo}}#{{number}}

You are helping someone review a GitHub pull request. Write a guide: a plain-language walkthrough of
the PR and draft review comments they can choose to post. The review page shows the code itself;
you only point at it.

## Where things are

- You are in a git clone of the repository, but its working tree may be on another branch or
  missing (a bare, partial clone): read the PR's files with `git show {{head}}:<path>`, never from
  the working tree. The PR's changes are `git diff {{base}}...{{head}}` (three dots: from where it
  branched) and its commits `git log {{base}}..{{head}}`.
- PR title: {{title}}
- Start with `{{diffPath}}`: every changed file's diff. Each line starts with two numbers, the line's
  number in the old file (before the PR) and in the new file (after it), then a mark and the code:
  context lines (space) have both numbers, added lines (`+`) only the new one, removed lines (`-`)
  only the old one. Take every line number you write from it, from the column the rules below name.
- Read the repository's own guidance (AGENTS.md, CLAUDE.md, CONTRIBUTING.md) when present, with
  `git show {{head}}:<file>`.

## Rules

- Read-only. Use read-only `git` and `gh` commands (log, show, blame, `gh pr view`). Don't run
  tests, builds, installs or formatters, and change no file except the guide.
- Only claim what the code supports; say so when you're unsure.

{{focus}}## Write

Write one valid JSON object (no comments, no trailing commas) to `{{guidePath}}` and nothing else
there. Format:

```json
{
  "schema": 1,
  "head": "{{head}}",
  "author": "{{author}}",
  "lens": {{lens}},
  "overview": "...",
  "flow": null,
  "changes": [
    { "title": "...", "why": "...", "steps": [ { "file": "...", "side": "new", "from": 1, "to": 2, "title": "...", "note": "..." } ] }
  ],
  "comments": [ { "id": "c1", "file": "...", "line": 1, "kind": "question", "body": "..." } ],
  "summary": "..."
}
```

- `lens`: the review lens you were asked to use; keep it exactly as written above.
- `overview`: a TL;DR in 2-4 plain sentences for someone who doesn't know the project: what the PR
  does and why, at a high level. Everyday words; skip internal names unless unavoidable.
- `changes`: in reading order, each with a short `title` and a one-sentence `why`. Size them to the
  PR, never pad: a PR that changes a handful of lines is 1 change with 1-2 steps; a typical PR is
  2-3 changes and 3-8 steps; only a big PR needs 4 changes and up to about 12 steps.
- Each step points at changed lines, because the page shows those lines highlighted. It has a
  `file`, an inclusive line range `from`..`to`, a short `title` and a one-sentence `note`; `code`
  spans are fine. Keep the range tight: the lines the step is about, not the whole function or
  file.
  - Every step MUST include at least one changed line: an added line, or a removed one. A step on
    code the PR didn't touch is dropped. Mention unchanged code only inside a note.
  - `side` says which column the range counts in. `"new"` (the default) uses the new-file numbers
    and the range must contain an added line. `"old"` uses the old-file numbers and the range must
    contain a removed line: use it for code the PR deletes, so you can point at the lines that are
    gone. A change that only removes code gets steps on `"old"`; one that replaces code can use
    either, `"new"` showing the removed lines beside the added ones.
  - Consecutive steps in one change on the same file are shown together as one block, so they
    can walk through the changes in a file one after another; don't repeat a step for lines
    already covered.
  - Order steps the way the code runs. Leave tests and docs out of steps; the page lists them under
    "Supporting changes".
- `flow` (optional, only when it truly helps): a small before/after diagram. `{ "title",
  "subtitle", "rows" }`; each row is a left-to-right list of boxes
  `{ "text": "fn()", "kind": "added" | "changed" | "removed", "change": <change number>, "note": "..." }`
  (kind, change and note optional), arrows `{ "edge": "label" }`, and forks
  `{ "branch": [ { "edge": "label", "text": "box" } ] }`.
- `comments`: draft inline comments, each on one new-file `line` inside the diff (a number from the
  new column; removed lines can't take a comment). `kind` is
  `problem`, `question`, `suggestion` or `nit`. Write like a kind, busy teammate: short, specific,
  phrased as a question or suggestion. Start minor points with "nit:". For a small exact fix, put
  the replacement in a GitHub ```suggestion block. No headings or bullet lists in a comment. Skip
  comments that don't matter; zero is fine.
- `summary`: the opening comment of the review, 1-4 sentences in the same voice.

When the file is written, reply with one line: `guide written`.
