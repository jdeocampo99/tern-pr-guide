--!strict
-- The window half: the one way into the PR hub (the commands, the status segment and the link route that
-- opens a card's PR in the guide), kept fresh by a timer and by focus. The decisions are in src/links.luau.
local Links = require("./src/links")
local Sync = require("./src/hub/sync")

-- The node a window-sent event names. A block's root is always drawn, so the event reaches it even if
-- Tern drops action events that name no node.
local HUB_NODE = "main.hub"

local function isHub(block: string?): boolean
 return block ~= nil and (block == "prguide.hub" or string.match(block, "%.prguide%.hub$") ~= nil)
end

-- Opens the PR hub, or focuses the one this window has (one hub per window). With `generate`, a hub
-- already open is told to open PRs with the AI guide started; without it, to stop.
local function openHub(cx: WindowCx, generate: boolean)
 local entry = Links.hubEntry(cx.session:panes(), cx.session:focused())
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
 cx.session:event(pane, { ev = "action", id = HUB_NODE, act = "set-generate", value = if generate then "true" else "false" })
end

tern.command({ id = "review", title = "PR hub", keys = { "cmd+alt+r" }, run = function(cx: WindowCx) openHub(cx, false) end })
tern.command({ id = "generate", title = "PR hub, AI guides", keys = { "cmd+alt+shift+r" }, run = function(cx: WindowCx) openHub(cx, true) end })
tern.command({ id = "sample", title = "New PR Guide sample block", run = function(cx: WindowCx)
 cx:new_block("prguide.guide", {}, "tab")
end })
tern.command({ id = "hub-sample", title = "New PR hub sample block", run = function(cx: WindowCx)
 cx:new_block("prguide.hub", { "fixture=cases" }, "tab")
end })

-- The hub's cache, as the board last stored it; nil while there is none.
local function readCache(): Sync.Cache?
 local ok, raw = pcall(tern.kv.get, "hub.cache")
 return if ok then Sync.load(raw) else nil
end

local function seenOf(cache: Sync.Cache, now: number): Links.Seen
 local counts = cache.counts
 return { refreshedAt = cache.refreshedAt, toReview = counts.toReview, needFixes = counts.needFixes, flashing = Links.flashing(counts.flashAt, now) }
end

-- Reads the cache and nothing else: a formatter never fetches. Hidden while there is no cache.
tern.chrome.status(function(_pane): { StatusSegment }?
 local cache = readCache()
 if not cache then return nil end
 local seen = seenOf(cache, os.time())
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

-- A hub pane that gains focus is told, so it can refresh when it has gone stale.
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
 local pane = cx.session:pane(ev.pane)
 if pane and isHub(pane.block) then
  cx.session:event(ev.pane, { ev = "action", id = HUB_NODE, act = "hub-focused" })
 end
end)

-- Blocks can't redraw the status line, so the window looks at the cache every 15 s (sooner when a
-- flash is about to end) and redraws it when what the segment shows has changed.
tern.on("window_start", function(_cx: WindowCx)
 local seen: Links.Seen? = nil
 local function watch()
  local now = os.time()
  local cache = readCache()
  local latest = if cache then seenOf(cache, now) else nil
  if Links.statusChanged(seen, latest) then tern.chrome.refresh() end
  seen = latest
  tern.timer(math.ceil(Links.watchDelay(if cache then cache.counts.flashAt else nil, now) * 1000), watch)
 end
 local cache = readCache()
 seen = if cache then seenOf(cache, os.time()) else nil
 tern.timer(Links.WATCH_SECONDS * 1000, watch)
end)
