-- Picks a PR from the checkout the focused pane is in; without a directory the page says where to run it.
tern.command({ id = "review", title = "Review a pull request", run = function(cx: WindowCx)
 local pane = cx.session:pane("@focused")
 cx:new_block("prguide.guide", { "repo=" .. (if pane and pane.cwd then pane.cwd else "") }, "tab")
end })
tern.command({ id = "sample", title = "PR Guide: sample", run = function(cx: WindowCx)
 cx:new_block("prguide.guide", {}, "tab")
end })
