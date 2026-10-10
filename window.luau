--!strict
-- The window half: the one way into the PR hub (the commands, the status segment and the link route that
-- opens a card's PR in the guide), kept fresh by a timer and by focus. The decisions are in src/links.luau.
local Links = require("./src/links")

-- The node a window-sent event names. A block's root is always drawn, so the event reaches it even if
-- Tern drops action events that name no node.
local HUB_NODE = "main.hub"

local function isHub(block: string?): boolean
 return block ~= nil and (block == "prguide.hub" or string.match(block, "%.prguide%.hub$") ~= nil)
end

-- Opens the PR hub, or focuses the one this window has (one hub per window). Every call tells the hub whether
-- to open PRs with the AI guide started; that send doubles as the liveness probe, since a dead block (one left
-- by a plugin reload) is invisible in PaneInfo but raises when sent an event. Only a hub that answered is
-- unparked and focused; with none, a new one opens.
local function openHub(cx: WindowCx, generate: boolean)
 local entry = Links.hubEntry(cx.session:panes(), cx.session:focused(), function(pane: number): boolean
  return (pcall(function()
   cx.session:event(pane, { ev = "action", id = HUB_NODE, act = "set-generate", value = if generate then "true" else "false" })
  end))
 end)
 local pane = entry.pane
 if entry.kind == "new" or not pane then
  cx:new_block("prguide.hub", if generate then { "generate=true" } else {}, "tab")
  return
 end
 if entry.kind == "unpark" then
  local ok, why = cx.layout:unpark(pane)
  if not ok then
   cx:toast("error", "Couldn't open the PR hub", why)
   return
  end
 end
 cx.layout:focus(pane)
end

tern.command({ id = "review", title = "PR hub", keys = { "cmd+alt+r" }, run = function(cx: WindowCx) openHub(cx, false) end })
tern.command({ id = "generate", title = "PR hub, AI guides", keys = { "cmd+alt+shift+r" }, run = function(cx: WindowCx) openHub(cx, true) end })
tern.command({ id = "sample", title = "New PR Guide sample block", run = function(cx: WindowCx)
 cx:new_block("prguide.guide", {}, "tab")
end })
tern.command({ id = "hub-sample", title = "New PR hub sample block", run = function(cx: WindowCx)
 cx:new_block("prguide.hub", { "fixture=cases" }, "tab")
end })

-- What the segment shows, set by the watcher below. The formatter reads only this: Tern disables a
-- status hook that takes more than a few milliseconds, so it never touches kv or decodes anything.
local current: Links.Seen? = nil
local observed: Links.Observed? = nil -- the flashAt last seen and when: a flash runs 10 s from then
local watching = false
local startWatch: () -> ()

tern.chrome.status(function(_pane): { StatusSegment }?
 local seen = current
 if not watching then pcall(tern.timer, 0, startWatch) end
 if not seen then return nil end
 return { {
  text = Links.statusText(seen.toReview, seen.needFixes),
  tone = if seen.flashing then "error" else nil,
  command = "plugin.prguide.review",
 } }
end)

-- A claimed link opens the PR in the guide; any other link opens GitHub's own page.
tern.route.link(function(link: LinkRequest, _cx: WindowCx): RouteDecision?
 local route = Links.openRoute(link.url)
 if not route then return nil end
 return { block = "prguide.guide", args = Links.routeArgs(route) }
end)

-- A hub pane that gains focus is told, so it can refresh when it has gone stale. A pane restored from an
-- earlier session may have no program to receive it: that is not worth a message.
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
 startWatch()
 local pane = cx.session:pane(ev.pane)
 if pane and isHub(pane.block) then
  pcall(function() cx.session:event(ev.pane, { ev = "action", id = HUB_NODE, act = "hub-focused" }) end)
 end
end)

-- Blocks can't redraw the status line, so the window reads the tiny `hub.status` record the hub writes
-- and looks at it every 2 s (a block can't message the window, so a flash shows within about 2 s), redrawing the line when what it shows has changed.
-- One chain runs per module load. `window_start` doesn't fire again when the plugin reloads in a running
-- window, so the watcher also starts from the module load, the first focus and the first status draw.
local function watch()
 local now = os.time()
 local ok, raw = pcall(tern.kv.get, "hub.status")
 local latest: Links.Seen? = nil
 latest, observed = Links.watch(if ok then raw else nil, now, observed)
 if Links.statusChanged(current, latest) then
  current = latest
  tern.chrome.refresh()
 end
 tern.timer(math.ceil(Links.watchDelay(if observed then observed.at else nil, now) * 1000), watch)
end

startWatch = function()
 if watching then return end
 watching = true
 watch()
end

tern.on("window_start", function(_cx: WindowCx)
 startWatch()
end)
-- Deferred so nothing here depends on what is ready while the module loads.
pcall(tern.timer, 0, startWatch)
