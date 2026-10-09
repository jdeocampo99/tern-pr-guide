# PR Guide

A Tern plugin (Luau and one stylesheet) that turns a GitHub PR into a guided review. `README.md` is the user manual. `GUIDE.md` is the guide-file contract.

## Where code goes

Each module's header comment names its one job. Put new code in the module that comment already covers. If none covers it, make a new module with its own header comment.

- **Boundary:** only `src/fetch.luau` reaches outside the plugin: `gh`, `git`, `omp`, `tern.kv`, and files.
- **Glue:** only `src/block.luau` does window effects: scrolling, focus, timers, toasts. A new action is one `ACTIONS` entry, sent by both clicks and `keys.luau`.
- **Views:** `src/view/*.luau` turn state into nodes and nothing else. Build them with `Ui.el` and `Ui.span`.
- **Styles:** `guide.css` only, with `gp-` classes and the color tokens `DESIGN.md` names. To change a look, edit the rule where it lives.
- `GUIDE.md`, `prompts/guide.md` and `src/guide.luau` change together.
- Mockups and scratch files go in `/tmp`. `docs/screenshots/` is only for README images.

## UI

Read `DESIGN.md` and `docs/ui.md` before any change to `src/view/` or `guide.css`, and before making a mockup. `DESIGN.md` is the visual system: tokens, components, and which colors come from Tern versus GitHub. `docs/ui.md` covers how to lay out new components, motion, and what Tern can't render.

## Copy

New UI text sounds official: neutral, plain and short, like GitHub.

| Kind | Pattern | Examples |
|---|---|---|
| Labels, buttons | Sentence case, verb first | "Mark all reviewed", "Request changes" |
| Progress | Present participle plus "…" | "Loading open pull requests…" |
| Failure | "Couldn't …: reason" | "Couldn't open your lenses folder" |
| Empty state | "No …" | "No description provided." |

- Prefer a noun over "you": "Needs attention", "Awaiting author".
- Plain statements: no exclamation marks, emoji or marketing words.
- In the same change, update the README. A new key also goes in `view/help.luau` and the README Keys table.

## Verify

- `tern plugin reload` exits 1 if the plugin fails to load.
- Try the change in Tern with **New PR Guide sample block**, or a real PR opened with `post=false`. Test reviews are always dry runs.
- Check UI changes in light and dark.

## Commits

The subject is the user-visible behavior as a plain sentence, with no type prefix. Example: "Picker: Recently opened PRs from any repo at the top, so a closed PR is one keypress away".
