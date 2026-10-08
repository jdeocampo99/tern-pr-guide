-- Each command opens a block that picks a PR from the checkout the focused pane is in; without a
-- directory the page says where to run it. Titles follow Tern's "New <thing> block" palette names.
local function pick(cx: WindowCx, extra: string?)
 local pane = cx.session:pane("@focused")
 local args = { "repo=" .. (if pane and pane.cwd then pane.cwd else "") }
 if extra then table.insert(args, extra) end
 cx:new_block("prguide.guide", args, "tab")
end
tern.command({ id = "review", title = "New PR review block", keys = { "cmd+alt+r" }, run = function(cx: WindowCx) pick(cx) end })
tern.command({ id = "generate", title = "New AI generated PR review block", keys = { "cmd+alt+shift+r" }, run = function(cx: WindowCx) pick(cx, "generate=true") end })
tern.command({ id = "sample", title = "New PR Guide sample block", run = function(cx: WindowCx)
 cx:new_block("prguide.guide", {}, "tab")
end })
