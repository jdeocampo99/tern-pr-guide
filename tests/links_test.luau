--!strict
local Links = require("../src/links")

return function()
	-- named: a bare number, "#n" or a PR link, ignoring spaces
	assert(Links.named("354") == 354 and Links.named("#354") == 354 and Links.named("  #354  ") == 354)
	assert(Links.named("https://github.com/acme/api/pull/354") == 354)
	assert(Links.named("https://github.com/acme/api/pull/354/files") == 354)
	assert(Links.named("https://ghe.corp.example/acme/api/pull/7#issuecomment-1") == 7)
	assert(Links.named("") == nil and Links.named("abc") == nil and Links.named("35x") == nil)
	assert(Links.named("https://github.com/acme/api/issues/354") == nil)

	-- linkRepo, linkHost
	assert(Links.linkRepo("https://github.com/acme/api/pull/354") == "acme/api")
	assert(Links.linkRepo(" https://github.com/Acme/API/pull/1 ") == "Acme/API")
	assert(Links.linkRepo("354") == nil and Links.linkRepo("https://github.com/acme/api") == nil)
	assert(Links.linkHost("https://github.com/acme/api/pull/354") == "github.com")
	assert(Links.linkHost("http://ghe.corp.example/acme/api/pull/9") == "ghe.corp.example")
	assert(Links.linkHost("354") == nil)

	-- reference: a link with a repo, else the bare number
	assert(Links.reference("acme/api", 354) == "https://github.com/acme/api/pull/354")
	assert(Links.reference(nil, 354) == "354")

	-- remoteRepo: https, ssh:// and scp-like remotes
	assert(Links.remoteRepo("https://github.com/acme/api.git") == "acme/api")
	assert(Links.remoteRepo("https://github.com/acme/api/") == "acme/api")
	assert(Links.remoteRepo("git@github.com:acme/api.git") == "acme/api")
	assert(Links.remoteRepo("ssh://git@github.com/acme/api.git\n") == "acme/api")
	assert(Links.remoteRepo("/Users/me/code/api") == nil)
	assert(Links.remoteRepo("https://github.com/acme") == nil)
	assert(Links.remoteRepo("") == nil)

	-- sameRepo ignores case and needs both
	assert(Links.sameRepo("Acme/API", "acme/api") and Links.sameRepo("a/b", "a/b"))
	assert(not Links.sameRepo("a/b", "a/c") and not Links.sameRepo(nil, "a/b") and not Links.sameRepo("a/b", nil) and not Links.sameRepo(nil, nil))

	-- resolve: ⏎ opens a pasted link, and a number alone is refused when no repo says where it is
	assert(Links.resolve("  https://github.com/acme/api/pull/354 ", nil) == "https://github.com/acme/api/pull/354")
	assert(Links.resolve("354", nil) == nil and Links.resolve("#354", nil) == nil)
	assert(Links.resolve("#354", "acme/api") == "https://github.com/acme/api/pull/354")
	assert(Links.resolve("nonsense", "acme/api") == nil)

	-- the #prguide-open= link: round trips, and any other link is not claimed
	local link = Links.openLink("acme/api", 354, "/Users/me/Code/api checkout", false, false)
	assert(link == "https://github.com/acme/api/pull/354#prguide-open=%2FUsers%2Fme%2FCode%2Fapi%20checkout")
	local route = Links.openRoute(link)
	assert(route and route.number == 354 and route.root == "/Users/me/Code/api checkout" and not route.generate and not route.search)
	assert(table.concat(Links.routeArgs(route :: Links.OpenRoute), "|") == "pr=354|repo=/Users/me/Code/api checkout")
	local generated = Links.openRoute(Links.openLink("acme/api", 12, "/code/api", true, false))
	assert(generated and generated.generate and table.concat(Links.routeArgs(generated), "|") == "pr=12|repo=/code/api|generate=true")
	local searching = Links.openRoute(Links.openLink("acme/api", 12, "/Users/me", false, true))
	assert(searching and searching.search and searching.link == "https://github.com/acme/api/pull/12")
	assert(table.concat(Links.routeArgs(searching), "|") == "pr=https://github.com/acme/api/pull/12|repo=/Users/me")
	assert(Links.openRoute("https://github.com/acme/api/pull/354") == nil)
	assert(Links.openRoute("https://github.com/acme/api/pull/354#discussion_r1") == nil)
	assert(Links.openRoute("https://github.com/acme/api/issues/354#prguide-open=%2Fx") == nil)
	assert(Links.openRoute("https://github.com/acme/api/pull/354#prguide-open=") == nil)

	-- hubEntry: one hub per window
	local hub = "prguide.hub"
	assert(Links.hubEntry({}, nil).kind == "new")
	assert(Links.hubEntry({ { pane = 1, block = "prguide.guide" }, { pane = 2 } }, 1).kind == "new")
	-- a hub open in the focused pane
	local entry = Links.hubEntry({ { pane = 1 }, { pane = 7, block = hub } }, 7)
	assert(entry.kind == "focus" and entry.pane == 7)
	-- a parked hub is unparked
	entry = Links.hubEntry({ { pane = 1 }, { pane = 7, block = hub, parked = true } }, 1)
	assert(entry.kind == "unpark" and entry.pane == 7)
	-- a hub open but focus is elsewhere: focus moves to it, no second hub
	entry = Links.hubEntry({ { pane = 1 }, { pane = 7, block = hub, parked = false } }, 1)
	assert(entry.kind == "focus" and entry.pane == 7)
	-- should two exist, the focused one wins, then a tiled one over a parked one
	entry = Links.hubEntry({ { pane = 5, block = hub, parked = true }, { pane = 6, block = hub }, { pane = 8, block = hub } }, 8)
	assert(entry.pane == 8)
	entry = Links.hubEntry({ { pane = 5, block = hub, parked = true }, { pane = 6, block = hub } }, 1)
	assert(entry.kind == "focus" and entry.pane == 6)
	assert(Links.hubEntry({ { pane = 3, block = "plugin.prguide.hub" } }, nil).pane == 3)
	-- a dead hub (its program exited or failed) is no hub
	assert(Links.hubEntry({ { pane = 7, block = hub, exited = 1 } }, 7).kind == "new")
	assert(Links.hubEntry({ { pane = 7, block = hub, error = "failed" }, { pane = 8, block = hub, parked = true, exited = 0 } }, nil).kind == "new")
	entry = Links.hubEntry({ { pane = 7, block = hub, exited = 1 }, { pane = 9, block = hub } }, 7)
	assert(entry.kind == "focus" and entry.pane == 9)

	-- the status segment
	assert(Links.statusText(2, 10) == "PRs · 2 to review · 10 need fixes")
	assert(Links.statusText(0, 3) == "PRs · 3 need fixes" and Links.statusText(4, 0) == "PRs · 4 to review" and Links.statusText(0, 0) == "PRs")
	assert(Links.flashing(1000, 1009) and not Links.flashing(1000, 1010) and not Links.flashing(nil, 1000))
	assert(Links.watchDelay(nil, 1000) == 15 and Links.watchDelay(1000, 1004) == 6 and Links.watchDelay(1000, 1020) == 15 and Links.watchDelay(1000, 1000) == 10)
	local a: Links.Seen = { refreshedAt = "t1", toReview = 2, needFixes = 1, flashing = false }
	assert(not Links.statusChanged(a, { refreshedAt = "t1", toReview = 2, needFixes = 1, flashing = false }))
	assert(Links.statusChanged(a, { refreshedAt = "t2", toReview = 2, needFixes = 1, flashing = false }))
	assert(Links.statusChanged(a, { refreshedAt = "t1", toReview = 3, needFixes = 1, flashing = false }))
	assert(Links.statusChanged(a, { refreshedAt = "t1", toReview = 2, needFixes = 1, flashing = true }))
	assert(Links.statusChanged(nil, a) and Links.statusChanged(a, nil) and not Links.statusChanged(nil, nil))
	local raw = { refreshedAt = "t1", counts = { toReview = 2, needFixes = 10, flashAt = 1000 } }
	local seen = Links.statusOf(raw, 1004)
	assert(seen and seen.toReview == 2 and seen.needFixes == 10 and seen.flashing and seen.flashAt == 1000)
	seen = Links.statusOf({ refreshedAt = "t1", counts = { toReview = 0, needFixes = 0 } }, 1004)
	assert(seen and not seen.flashing and seen.flashAt == nil)
	assert(Links.statusOf(nil, 0) == nil and Links.statusOf({ refreshedAt = "t", counts = {} }, 0) == nil and Links.statusOf({ counts = { toReview = 1, needFixes = 1 } }, 0) == nil)
end
