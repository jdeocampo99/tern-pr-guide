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
  "overview": "A short TL;DR anyone can follow.",
  "flow": null,
  "changes": [
    {
      "title": "Steps match by number",
      "why": "One sentence on why this change exists.",
      "steps": [
        { "file": "src/playbooks/progress.ts", "from": 29, "to": 31, "title": "Step items carry their number", "note": "One sentence." }
      ]
    }
  ],
  "comments": [
    { "id": "c1", "file": "src/playbooks/progress.ts", "line": 48, "kind": "question", "body": "Markdown text." }
  ],
  "summary": "The opening comment of the review, in Markdown.",
  "groups": { "src/instructions.ts": "Agent guidance" }
}
```

## Fields

- `schema`: always `1`.
- `head`: the PR commit the guide was written against. When the PR has moved on, the page still
  shows the guide and says it was written for an older version.
- `author`: the name shown on suggested comments ("Tandem suggests").
- `overview`: a TL;DR of the PR in 2-4 plain sentences, for someone who doesn't know the project.
- `flow` (optional): a before/after diagram, described below.
- `changes`: 1-4 changes in reading order. Each has a `title`, a one-sentence `why`, and `steps`.
- `steps[]`: `file` is a path in the PR; `from`/`to` is an inclusive range of new-file line numbers
  that touches the diff; `title` and `note` are short plain text (`note` may use `code` spans).
- `comments[]`: suggested inline comments. `line` is a new-file line in the diff. `kind` is one of
  `problem`, `question`, `suggestion`, `nit`. `id` is unique within the guide.
- `summary`: the drafted opening comment the reader can edit before submitting.
- `groups` (optional): file path to a group name for files outside every step. Unlisted files are
  grouped by path: tests, docs, then everything else.

Changed files that no step visits are shown under "Supporting changes".

## Flow diagram

`flow` is `{ "title", "subtitle", "rows" }`. Each row is a list read left to right:

- a box: `{ "text": "launchAgent()", "kind": "added" | "changed" | "removed", "change": 3, "note": "owner check" }`,
  where `kind`, `change` (the change number it belongs to) and `note` are optional;
- an arrow: `{ "edge": "tool call" }` (the label may be empty);
- a fork: `{ "branch": [ { "edge": "all closed", "text": "report accepted" }, ... ] }`.

## Without a guide

The page builds one change named after the PR, with one step per changed file covering its diff,
no suggested comments, and an empty summary.
