--!strict
-- Node builders every view shares.
local Guide = require("../guide")
local Text = require("../text")

-- Remembers each animated node's entrance class across renders: views read the last render's
-- `born` and record this render's into `next` (see `entering`). Nodes first drawn in a render a
-- key caused (`animate` false) never play their entrance.
export type Motion = { born: { [string]: string }, next: { [string]: string }, booted: boolean, animate: boolean }

export type KindLabel = { verb: string, word: string, icon: string }

local ICONS: { [string]: string } = { ts = "TS", tsx = "TS", js = "JS", md = "MD", json = "{ }", luau = "LU", css = "CSS" }

local M = {}

M.kinds = {
 problem = { verb = "flags a problem", word = "Problem", icon = "⚠  " },
 question = { verb = "asks", word = "Question", icon = "" },
 suggestion = { verb = "suggests", word = "Suggestion", icon = "" },
 nit = { verb = "left a nit", word = "Nit", icon = "" },
} :: { [Guide.Kind]: KindLabel }

-- Builds the wire node tern.ui.el would, without calling it: tern.ui.el copies its whole subtree,
-- so each level of nesting paid again for every node below it.
function M.el(tag: string, props: { [string]: any }?, children: { Node }?): Node
 local p: { [string]: any } = props or {}
 p.tag = tag
 if children and #children > 0 then return { k = "el", p = p, c = children } :: any end
 return { k = "el", p = p } :: any
end

function M.span(class: string, text: string): Node
 return { k = "el", p = { tag = "span", class = class, text = text } } :: any
end

local el, span = M.el, M.span

function M.spacer(): Node
 return span("gp-fspacer", "")
end

function M.button(class: string, text: string, action: string): Node
 return el("button", { class = "gp-btn " .. class, text = text, actions = { click = action } })
end

function M.check(on: boolean, label: string, action: string): Node
 return el("span", { class = "gp-check" .. (if on then " gp-check-on" else ""), actions = { click = action } }, {
  span("gp-check-box", if on then "✓" else ""),
  span("gp-check-label", label),
 })
end

-- A text action with its shortcut beside it, so every bulk action teaches its key.
function M.actionLink(label: string, keyHint: string, action: string, done: boolean): Node
 return el("span", { class = "gp-act" .. (if done then " gp-act-done" else ""), actions = { click = action } }, {
  span("gp-act-label", label),
  span("gp-act-key", keyHint),
 })
end

-- Prose with `code` spans, drawn as inline spans. tern.ui.md fills in after the frame, and in the
-- sticky change card it stayed blank, so short prose skips it.
function M.rich(text: string): Node
 local parts, code = {}, false
 for piece in string.gmatch(text .. "`", "([^`]*)`") do
  if piece ~= "" then table.insert(parts, span(if code then "gp-icode" else "gp-itext", piece)) end
  code = not code
 end
 return el("span", { class = "gp-rich" }, parts)
end

function M.fileIcon(path: string): Node
 local extension = Text.extension(path)
 return span("gp-ficon gp-ficon-" .. extension, ICONS[extension] or "·")
end

function M.avatar(class: string, name: string): Node
 return span("gp-avatar " .. class, Text.initial(name))
end

-- The entrance class for a node drawn after the page's first render, or "" for one that stays
-- still. A change a key caused (`animate` false) stays still unless `always`: results that arrive
-- on their own, like a posted review, are not key presses. The class is remembered by `id` for the
-- node's lifetime because changing it would restart the animation.
function M.entering(motion: Motion, id: string, class: string, always: boolean?): string
 local born = motion.born[id] or (if motion.booted and (always == true or motion.animate) then class else "")
 motion.next[id] = born
 return born
end

-- A collapsible body keyed "body". Bodies present on the first render stay still; bodies that
-- appear later unroll. `closing` plays the roll-up before the body goes.
function M.body(motion: Motion, id: string, closing: boolean, height: number, children: { Node }): Node
 local bucket = math.clamp(math.ceil(height / 40), 1, 75)
 local born = M.entering(motion, id, "gp-hb gp-hb" .. bucket)
 return el("div", { class = "gp-body gp-rb" .. bucket .. " " .. born .. (if closing then " gp-closing" else ""), key = "body" }, children)
end

return M
