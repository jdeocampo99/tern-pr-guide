--!strict
-- Node builders every view shares.
local Guide = require("../guide")
local Text = require("../text")

-- Remembers each animated node's entrance class across renders: views read the last render's
-- `born` and record this render's into `next` (see `entering`). Nodes first drawn in a render a
-- key caused (`animate` false) never play their entrance.
export type Motion = { born: { [string]: string }, next: { [string]: string }, booted: boolean, animate: boolean }

export type KindLabel = { verb: string, word: string, icon: string? }

-- Icons by file extension; any extension not listed here is a plain file.
local CODE_FILES: { [string]: boolean } = {}
for extension in string.gmatch("ts tsx js jsx mjs cjs luau lua css scss json rs go py rb java kt swift c h cpp hpp cs sh bash zsh sql html toml yaml yml", "%S+") do
 CODE_FILES[extension] = true
end
local IMAGE_FILES: { [string]: boolean } = {}
for extension in string.gmatch("png jpg jpeg gif webp svg ico bmp avif", "%S+") do
 IMAGE_FILES[extension] = true
end

-- The key names the plugin's hint strings write as glyphs.
local KEY_GLYPHS: { [string]: string } = {
 ["⇧"] = "shift", ["⌘"] = "cmd", ["⏎"] = "enter", ["⌃"] = "ctrl", ["⌥"] = "alt",
 ["←"] = "left", ["→"] = "right", ["↑"] = "up", ["↓"] = "down",
}

local M = {}

M.kinds = {
 problem = { verb = "flags a problem", word = "Problem", icon = "warn" },
 question = { verb = "asks", word = "Question" },
 suggestion = { verb = "suggests", word = "Suggestion" },
 nit = { verb = "left a nit", word = "Nit" },
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

-- A native icon node, built as tern.ui.node("icon", …) would.
function M.icon(name: string, key: string?): Node
 return { k = "icon", p = { name = name, key = key } } :: any
end

-- The disclosure mark before a heading that folds: right while it is folded, down while open.
function M.caret(open: boolean): Node
 return el("span", { class = "gp-caret" }, { M.icon(if open then "chev" else "chev-r") })
end

-- Native keycaps for a hint written as the plugin always has: glyph modifiers and arrows
-- ("⇧M", "⌘⏎", "⇧← →"), words ("esc"), and space-separated keys ("j k", "1 2 3"), each of which is
-- its own cap.
function M.keys(hint: string, key: string?): Node
 local names: { string } = {}
 for token in string.gmatch(hint, "%S+") do
  local plain = ""
  for char in string.gmatch(token, utf8.charpattern) do
   local glyph = KEY_GLYPHS[char]
   if glyph then
    if plain ~= "" then table.insert(names, plain) end
    plain = ""
    table.insert(names, glyph)
   else
    plain ..= char
   end
  end
  if plain ~= "" then table.insert(names, plain) end
 end
 return { k = "kbd", p = { keys = names, key = key } } :: any
end

-- Keys each followed by what they do, as one muted line: "a add · d dismiss".
function M.keyLine(class: string, hints: { { string } }): Node
 local parts: { Node } = {}
 for n, hint in hints do
  if n > 1 then table.insert(parts, span("gp-keyline-sep", "·")) end
  table.insert(parts, M.keys(hint[1]))
  table.insert(parts, span("gp-keyline-label", hint[2]))
 end
 return el("span", { class = "gp-keyline " .. class }, parts)
end

function M.spacer(): Node
 return span("gp-fspacer", "")
end

function M.button(class: string, text: string, action: string): Node
 return el("button", { class = "gp-btn " .. class, text = text, actions = { click = action } })
end

-- A tick box with its label, and the key that ticks it when there is one.
function M.check(on: boolean, label: string, action: string, key: string?): Node
 local kids = {
  el("span", { class = "gp-check-box" }, if on then { M.icon("check") } else nil),
  span("gp-check-label", label),
 }
 if key then table.insert(kids, M.keys(key)) end
 return el("span", { class = "gp-check" .. (if on then " gp-check-on" else ""), actions = { click = action } }, kids)
end

-- A text action with its shortcut beside it, so every bulk action teaches its key.
function M.actionLink(label: string, keyHint: string, action: string, done: boolean): Node
 local kids = {}
 if done then table.insert(kids, M.icon("check")) end
 table.insert(kids, span("gp-act-label", label))
 table.insert(kids, M.keys(keyHint))
 return el("span", { class = "gp-act" .. (if done then " gp-act-done" else ""), actions = { click = action } }, kids)
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

-- Code files draw as code, Markdown as Markdown, pictures as pictures, and the rest as plain files.
function M.fileIcon(path: string): Node
 local extension = string.lower(Text.extension(path))
 local name = if CODE_FILES[extension] then "file-code"
  elseif extension == "md" or extension == "mdx" then "markdown"
  elseif IMAGE_FILES[extension] then "file-image"
  else "file"
 return M.icon(name)
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
