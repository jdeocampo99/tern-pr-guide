# Architecture

Looks at how the change fits the codebase: boundaries, dependencies and long-term cost.

Review this PR for design. Explain how the pieces fit together, then judge whether the change
belongs where it was put and whether it will be easy to live with in six months.

Read enough of the surrounding code (and the repository's own guidance, if any) to see its existing
patterns before judging the new ones. Look at:

- Where responsibilities sit: does each module, type or function have one clear job, and does the
  new code live in the layer that owns that job? Note logic leaking across boundaries.
- Dependencies: new coupling between modules, circular or upward imports, and shared state that
  several parts now depend on.
- Fit: does it follow the conventions the codebase already uses, or invent a second way to do the
  same thing? Is there existing code it should reuse, or duplicate code it adds?
- Shape of the API: names, types and signatures that make misuse easy; abstractions that don't earn
  their keep, or ones that are missing and will be.
- Change cost: what a likely next feature or fix would have to touch, what is hard to test or to
  delete later, and what this makes harder.
- Migrations and compatibility: data or interface changes and whether callers are all updated.

Make the overview about the design: the problem, the approach taken, and the main trade-off. If a
`flow` diagram helps, use it to show the structure before and after. Order steps so the central
design decision comes first. Comments should be about structure and direction (`question` and
`suggestion` mostly, `problem` for something that will clearly hurt), and should offer an
alternative when they object. Leave small line-level issues out unless they point at a bigger one.
