# UI guide

Read this before changing anything in `src/view/` or `guide.css`. Keep the current look and reuse the values already in `guide.css`.

## Laying out new UI

These rules are condensed from the `impeccable` skill's `reference/layout.md`. Read that file when building a whole new surface.

For a larger feature or a new page, first gather references when the Mobbin MCP is available. Use `search_screens` to find how established apps show similar information, and `search_flows` for multi-step flows. Take the structure from them, then build it within this plugin's look and Tern's limits.

1. **Start from the task.** Before building, name what the reader decides on this surface, what they read first, what comes second, and which items belong together.
2. **Pass the squint test.** With the detail blurred out, the primary element, the secondary element and the groups still read in that order.
3. **Group by proximity first.** Use tight spacing inside a group and generous spacing between groups. Add a panel, border or divider only when spacing alone can't separate the groups.
4. **Match density to how often the surface is used.** A list read many times a day stays dense, one row per item. Detail the reader rarely needs goes behind a fold or a hover.
5. **Show each fact once.** A PR appears in one section. An active filter shows in one control.
6. **Reuse structures the reader already knows.** Use the same row layout for the same kind of item, with counts in fixed right-aligned columns, and familiar controls (field, tabs, dropdown) in the plugin's existing styles. Follow GitHub's conventions where they exist.
7. **Spend color only on state.** Color, weight and depth mark the thing needing action; everything else stays muted.
8. **Design the extremes.** Check long titles, an empty list, loading, one item, 50+ items, and a narrow pane.
9. **Make keyboard order match visual order.**

## Motion

These rules are condensed from the `emil-design-eng` skill. The motion tokens are in the first lines of `guide.css`.

- **Animate according to how often something happens.** Changes driven by a key never animate. Entrances go through `Ui.entering`, and transitions live under `.gp-soft`. Occasional UI such as panels, popovers and toasts gets a standard animation. Rare moments, like a guide arriving or a review being sent, may take `--gp-dur-rare`.
- **Give every animation a purpose:** press feedback, a state change, or softening a jump. Movement with no purpose stays still.
- **Easing:** anything entering or leaving uses `--gp-ease-out`. Movement that stays on screen uses `--gp-ease-in-out`. Hover and color changes use `ease`. Constant motion like a progress sweep uses `linear`.
- **Duration:** use the tokens and stay under 300ms; only rare moments use the 320ms `--gp-dur-rare`. Exits are faster than entrances (150ms vs 200ms).
- Entrances start at `scale(0.95)` plus `opacity: 0`. Popovers scale from the edge of their trigger.
- Pressables share the `scale(0.97)` press in the "press feedback" section.
- Animate `transform` and `opacity`. Heights unroll through `Ui.body`.
- Anything that can retrigger mid-flight uses transitions, which retarget, instead of keyframes, which restart.
- Stagger lists by 30–80ms. Never block input while an animation plays.
- Every new animation gets a short fade in the `prefers-reduced-motion` block.

## Tern's limits

- Layout is flex only. Pinned elements use `position: sticky`; plugins get no scroll events.
- Every color is a `light-dark()` pair.
- No SVG. Icons are text glyphs (✓ ✕ • ↗ ⏎ ⌘) or the host's named `icon` strings. Mockups follow the same limits.
- An action that has a key shows the key beside its label.
- Check `tern.d.luau`, written by `tern plugin types .`, before assuming the host offers something.
