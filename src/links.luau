--!strict
-- Pure helpers for the PR hub's way in. Link and number parsing (the PR a pasted "354", "#354" or
-- link names, the repo and host of a link, a git remote's repo); the `#prguide-open=` link that opens
-- a PR in the guide; which pane ⌥⌘R opens or focuses; and the status segment's text and redraw timing.
-- Requires nothing and reads no clock: callers pass `now` in seconds.
local M = {}

local function trim(text: string): string
 return string.match(text, "^%s*(.-)%s*$") :: string
end

-- Links and numbers ------------------------------------------------------------------------------

-- The PR a typed or pasted "354", "#354" or GitHub PR link names.
function M.named(text: string): number?
 local trimmed = trim(text)
 local n = string.match(trimmed, "^#?(%d+)$") or string.match(trimmed, "^https?://[^/]+/[^/]+/[^/]+/pull/(%d+)")
 return if n then tonumber(n) else nil
end

-- The "owner/repo" a GitHub PR link is in, as the link spells it.
function M.linkRepo(text: string): string?
 return string.match(trim(text), "^https?://[^/]+/([^/]+/[^/]+)/pull/%d+")
end

-- The host a GitHub PR link is on.
function M.linkHost(text: string): string?
 return string.match(trim(text), "^https?://([^/]+)/[^/]+/[^/]+/pull/%d+")
end

-- What opens PR `number` of `slug` ("owner/repo") in the guide: its link, or, with no repo to say
-- where it is, the bare number.
function M.reference(slug: string?, number: number): string
 if slug then return "https://github.com/" .. slug .. "/pull/" .. number end
 return tostring(number)
end

-- What opening the typed or pasted `text` means: a PR link as it is; a bare number only when `slug`
-- says which repository it is in (then that PR's link). A number alone names no repo, so it gives nil.
function M.resolve(text: string, slug: string?): string?
 if M.linkRepo(text) then return trim(text) end
 local number = M.named(text)
 if number and slug then return M.reference(slug, number) end
 return nil
end

-- The "owner/repo" a git remote URL points at: https, ssh:// and scp-like `git@host:owner/repo.git`.
function M.remoteRepo(url: string): string?
 local trimmed = trim(url)
 local path = string.match(trimmed, "^[%w+.-]+://[^/]+/(.+)$") or string.match(trimmed, "^[^/:]+:(.+)$")
 if not path then return nil end
 local slug = (string.gsub((string.gsub(path, "/$", "")), "%.git$", ""))
 return if string.match(slug, "^[^/]+/[^/]+$") then slug else nil
end

-- Whether two "owner/repo" names are the same GitHub repo, which ignores case.
function M.sameRepo(a: string?, b: string?): boolean
 return a ~= nil and b ~= nil and string.lower(a) == string.lower(b)
end

-- The link the hub opens a PR with ------------------------------------------------------------------

-- A PR link carrying `#prguide-open=<root>`: the window's link route claims it and opens the guide.
-- `root` is a checkout of the repo, or, with `search` set, a folder to look for one in (PR Guide's
-- own copy of the repo is used when there is none).
export type OpenRoute = { number: number, root: string, generate: boolean, search: boolean, link: string }

local function escape(text: string): string
 return (string.gsub(text, "[^%w%-_.~]", function(c: string): string return string.format("%%%02X", string.byte(c)) end))
end

local function unescape(text: string): string
 return (string.gsub(text, "%%(%x%x)", function(hex: string): string return string.char(tonumber(hex, 16) :: number) end))
end

function M.openLink(slug: string, number: number, root: string, generate: boolean, search: boolean): string
 return M.reference(slug, number) .. "#prguide-open=" .. escape(root) .. (if generate then "&generate=true" else "") .. (if search then "&search=true" else "")
end

-- The route a clicked or opened `url` stands for; nil for any other link, which opens GitHub's page.
function M.openRoute(url: string): OpenRoute?
 local link, rest = string.match(url, "^(https?://[^/]+/[^/]+/[^/]+/pull/%d+)[^#]*#prguide%-open=(.*)$")
 if not link then return nil end
 local number = M.named(link)
 local root, flags = string.match(rest :: string, "^([^&]*)(.*)$")
 root = unescape(root :: string)
 if not number or root == "" then return nil end
 return { number = number, root = root, generate = string.find(flags :: string, "&generate=true", 1, true) ~= nil, search = string.find(flags :: string, "&search=true", 1, true) ~= nil, link = link }
end

-- The guide block's arguments for `route`. With a folder to search, the guide gets the link itself
-- and finds the checkout (or makes the saved copy) as it does for a pasted link.
function M.routeArgs(route: OpenRoute): { string }
 local args = { "pr=" .. (if route.search then route.link else tostring(route.number)), "repo=" .. route.root }
 if route.generate then table.insert(args, "generate=true") end
 return args
end

-- ⌥⌘R: the hub pane to open ------------------------------------------------------------------------

export type PaneLike = { pane: number, block: string?, parked: boolean? }
export type Entry = { kind: "new" | "focus" | "unpark", pane: number? }

local function isHub(pane: PaneLike): boolean
 local block = pane.block
 return block ~= nil and (block == "prguide.hub" or string.match(block, "%.prguide%.hub$") ~= nil)
end

-- What opening the hub does: nothing is open (a new tab block), a hub is parked (deal it into the
-- tab, then focus it), or a hub is open (focus it). One hub per window: the focused one wins, then a
-- tiled one, then a parked one.
function M.hubEntry(panes: { PaneLike }, focused: number?): Entry
 local best: PaneLike? = nil
 local bestRank = 0
 for _, pane in panes do
  if isHub(pane) then
   local rank = if pane.pane == focused then 3 elseif not pane.parked then 2 else 1
   if rank > bestRank then best, bestRank = pane, rank end
  end
 end
 if not best then return { kind = "new", pane = nil } end
 return { kind = if best.parked then "unpark" else "focus", pane = best.pane }
end

-- The status segment ----------------------------------------------------------------------------------

M.FLASH_SECONDS = 10
M.WATCH_SECONDS = 15

-- "PRs · 2 to review · 10 need fixes": a part with a zero count is left out, and with both zero it is "PRs".
function M.statusText(toReview: number, needFixes: number): string
 local text = "PRs"
 if toReview > 0 then text ..= " · " .. toReview .. " to review" end
 if needFixes > 0 then text ..= " · " .. needFixes .. " need fixes" end
 return text
end

-- Whether the segment is flashing red: the Needs fixes count rose at `flashAt`, less than 10 s ago.
function M.flashing(flashAt: number?, now: number): boolean
 return flashAt ~= nil and now - flashAt < M.FLASH_SECONDS
end

-- Seconds until the window next looks at the cache: every 15 s, but sooner when a flash ends first.
function M.watchDelay(flashAt: number?, now: number): number
 if flashAt ~= nil then
  local left = flashAt + M.FLASH_SECONDS - now
  if left > 0 and left < M.WATCH_SECONDS then return left end
 end
 return M.WATCH_SECONDS
end

-- What the chrome last drew from, so the window knows when to redraw it.
export type Seen = { refreshedAt: string, toReview: number, needFixes: number, flashing: boolean }

-- Whether the chrome must be redrawn: the cache was refreshed, a count moved or the flash ended.
function M.statusChanged(old: Seen?, new: Seen?): boolean
 if old == nil or new == nil then return old ~= new end
 return old.refreshedAt ~= new.refreshedAt or old.toReview ~= new.toReview or old.needFixes ~= new.needFixes or old.flashing ~= new.flashing
end

return M
