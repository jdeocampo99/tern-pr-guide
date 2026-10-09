# Guide file format

A guide tells the review page how to walk a reader through one pull request: a plain summary, the
PR split into a few changes with ordered steps, and suggested review comments. The plugin works
without one; a guide only adds the walkthrough and suggestions.

Any tool can write a guide. The plugin never needs to know which. Save the guide for PR `<number>`
as `.git/prguide/<number>.json` in the clone and the plugin picks it up when that PR opens.

```json
{
  "schema": 1,
  "head": "560d7e1aab66404d7f9581b0268f622da58e08b7",
  "author": "Tandem",
  "lens": "Security",
  "overview": "A short TL;DR anyone can follow.",
  "flow": null,
  "changes": [
    {
      "title": "Steps match by number",
      "why": "One sentence on why this change exists.",
      "steps": [
        { "file": "src/playbooks/progress.ts", "from": 29, "to": 31, "title": "Step items carry their number", "note": "One sentence." },
        { "file": "src/playbooks/progress.ts", "side": "old", "from": 40, "to": 42, "title": "Index matching goes", "note": "Points at removed lines." }
      ]
    }
  ],
  "comments": [
    { "id": "c1", "file": "src/playbooks/progress.ts", "line": 48, "kind": "question", "body": "Markdown text." }
  ],
  "summary": "The opening comment of the review, in Markdown."
}
```

## Fields

- `schema`: always `1`.
- `head`: the PR commit the guide was written against. When the PR has moved on, the page still
  shows the guide and says it was written for an older version.
- `author`: the name shown on suggested comments ("Tandem suggests").
- `lens` (optional): the name of the review lens the guide was written through ("Security", say).
  The page shows it next to the progress, as "Security lens". A guide without one shows nothing.
- `overview`: a TL;DR of the PR in 2-4 plain sentences, for someone who doesn't know the project.
- `flow` (optional): a before/after diagram, described below.
- `changes`: 1-4 changes in reading order. Each has a `title`, a one-sentence `why`, and `steps`.
- `steps[]`: `file` is a path in the PR; `from`/`to` is an inclusive line range; `title` and `note`
  are short plain text (`note` may use `code` spans). `side` (optional) says which file the range
  counts in: `"new"` (the default, and what a guide without `side` means) is the file after the PR
  and the range must contain an added line; `"old"` is the file before it and the range must
  contain a removed line, which is how a step points at deleted code. A step with no changed line
  in its range is about untouched code: it is dropped, and its `note` is added to the note of the
  step before it in the same change when that is on the same file. Consecutive steps on one file in
  one change are drawn as one code block, each step's lines numbered in the gutter; the step you
  are on has its lines highlighted.
- `comments[]`: suggested inline comments. `line` is a new-file line in the diff (removed lines
  can't take a comment). `kind` is one of
  `problem`, `question`, `suggestion`, `nit`. `id` is unique within the guide.
- `summary`: the drafted opening comment the reader can edit before submitting.

The diff an agent reads numbers both sides: each line starts with its old-file number, then its
new-file number (an added line has no old one, a removed line no new one), then its mark.

Changed files that no step visits are shown under "Supporting changes", as a folder tree.

## Flow diagram

`flow` is `{ "title", "subtitle", "rows" }`. Each row is a list read left to right:

- a box: `{ "text": "launchAgent()", "kind": "added" | "changed" | "removed", "change": 3, "note": "owner check" }`,
  where `kind`, `change` (the change number it belongs to) and `note` are optional;
- an arrow: `{ "edge": "tool call" }` (the label may be empty);
- a fork: `{ "branch": [ { "edge": "all closed", "text": "report accepted" }, ... ] }`.

## Without a guide

The page lists the changed files as a folder tree, like GitHub, and walks them one file at a time
in that order, with no suggested comments and an empty summary. A guide file whose changes all fail
to match the PR gets the same tree.
