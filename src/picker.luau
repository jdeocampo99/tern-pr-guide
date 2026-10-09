--!strict
-- The page that picks a PR to review: the checkout's open PRs, or, away from a GitHub checkout, the
-- reader's open PRs across GitHub; filtered by what the reader types, plus the PR a typed or pasted
-- number or link names.
local Fields = require("./text-field")

-- An open PR as the list shows it. The statistics come with a checkout's list only.
export type Summary = {
 number: number,
 title: string,
 author: string,
 branch: string,
 draft: boolean,
 -- When it last changed, as GitHub's ISO time.
 updated: string,
 adds: number?,
 dels: number?,
 files: number?,
 -- "owner/repo" in a list across GitHub; nil in a checkout's own list.
 repo: string?,
 -- The label this PR sits under in a list across GitHub.
 group: string?,
 -- What names the row on the page.
 key: string,
}

export type Picker = {
 field: Fields.Field,
 -- Nil until the list loads, or when loading it failed.
 prs: { Summary }?,
 -- PRs the reader opened lately, in any repo, newest first; listed above the rest.
 recent: { Summary },
 -- The checkout's "owner/repo"; nil across GitHub.
 slug: string?,
 -- The current branch's PR, when it has one.
 current: number?,
 error: string?,
 -- PRs with a guide file.
 guided: { [number]: boolean },
 -- Index into `rows`.
 selected: number,
 -- When the list loaded, in seconds since the epoch; "2h ago" counts from here.
 loadedAt: number,
 -- The list is the reader's PRs across GitHub, not a checkout's: a bare number names no repo.
 anywhere: boolean,
}

export type Row = { pr: Summary, thisBranch: boolean }

-- A PR the reader opened, as kept between sessions.
export type Opened = { repo: string, number: number, title: string, author: string, at: string }

local M = {}

M.LIST_FIELDS = "number,title,author,headRefName,isDraft,updatedAt,additions,deletions,changedFiles"
M.SEARCH_FIELDS = "repository,number,title,author,isDraft,updatedAt"

-- How many PRs a list across GitHub keeps, and the labels it groups them under.
M.ANYWHERE_CAP = 50
M.REQUESTED, M.OWN, M.RECENT = "Review requested", "Yours", "Recently opened"
-- How many recently opened PRs are kept.
M.RECENT_CAP = 8

-- The opened PRs kept in `saved` (whatever was stored), skipping anything malformed.
function M.openedList(saved: any): { Opened }
 local list = {}
 if type(saved) ~= "table" then return list end
 for _, item in saved do
  if type(item) == "table" and type(item.repo) == "string" and type(item.number) == "number" then
   table.insert(list, {
    repo = item.repo,
    number = item.number,
    title = if type(item.title) == "string" then item.title else "",
    author = if type(item.author) == "string" then item.author else "",
    at = if type(item.at) == "string" then item.at else "",
   })
  end
 end
 return list
end

-- `list` with `opened` moved to the front, each PR once, at most RECENT_CAP long.
function M.remember(list: { Opened }, opened: Opened): { Opened }
 local out = { opened }
 for _, item in list do
  if #out >= M.RECENT_CAP then break end
  if not (M.sameRepo(item.repo, opened.repo) and item.number == opened.number) then table.insert(out, item) end
 end
 return out
end

function M.new(guided: { [number]: boolean }, anywhere: boolean, recent: { Opened }, slug: string?): Picker
 local rows = {}
 for n, item in recent do
  table.insert(rows, {
   number = item.number, title = item.title, author = item.author, branch = "", draft = false,
   updated = item.at, repo = item.repo, group = M.RECENT, key = "rc" .. n,
  })
 end
 return {
  field = Fields.create(), prs = nil, recent = rows, slug = slug, current = nil, error = nil, guided = guided,
  selected = 1, loadedAt = os.time(), anywhere = anywhere,
 }
end

-- Reads `gh pr list --json <LIST_FIELDS>`.
function M.parse(stdout: string): { Summary }
 local prs = {}
 for _, raw in tern.json.decode(stdout) do
  table.insert(prs, {
   number = raw.number,
   title = raw.title,
   author = if type(raw.author) == "table" then raw.author.login else "",
   branch = raw.headRefName,
   draft = raw.isDraft == true,
   updated = raw.updatedAt,
   adds = raw.additions,
   dels = raw.deletions,
   files = raw.changedFiles,
   key = "pr" .. raw.number,
  })
 end
 return prs
end

-- Reads `gh search prs --json <SEARCH_FIELDS>`, the PRs under the label `group`; `combine` keys them.
function M.parseSearch(stdout: string, group: string): { Summary }
 local prs = {}
 for _, raw in tern.json.decode(stdout) do
  local repo = if type(raw.repository) == "table" then raw.repository.nameWithOwner else nil
  if type(repo) == "string" and type(raw.number) == "number" then
   table.insert(prs, {
    number = raw.number,
    title = raw.title or "",
    author = if type(raw.author) == "table" and type(raw.author.login) == "string" then raw.author.login else "",
    branch = "",
    draft = raw.isDraft == true,
    updated = raw.updatedAt or "",
    repo = repo,
    group = group,
    key = "",
   })
  end
 end
 return prs
end

-- The lists joined in order, each PR once (the first list's label wins) and at most `cap` of them.
function M.combine(lists: { { Summary } }, cap: number): { Summary }
 local prs, seen = {}, {}
 for _, list in lists do
  for _, pr in list do
   local id = string.lower(pr.repo or "") .. "#" .. pr.number
   if not seen[id] and #prs < cap then
    seen[id] = true
    table.insert(prs, pr)
    pr.key = "pr" .. #prs
   end
  end
 end
 return prs
end

-- The PR numbers that guide files named `<number>.json` are for.
function M.guideNumbers(names: { string }): { [number]: boolean }
 local numbers = {}
 for _, name in names do
  local n = string.match(name, "^(%d+)%.json$")
  if n then numbers[tonumber(n) :: number] = true end
 end
 return numbers
end

local function trim(text: string): string
 return string.match(text, "^%s*(.-)%s*$") :: string
end

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

-- What opens `pr` from the page: its number in a checkout's list, else its link.
function M.reference(pr: Summary): string
 if pr.repo then return "https://github.com/" .. pr.repo .. "/pull/" .. pr.number end
 return tostring(pr.number)
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

local function matches(pr: Summary, needle: string): boolean
 for _, text in { "#" .. pr.number, pr.title, pr.author, pr.branch, pr.repo or "" } do
  if string.find(string.lower(text), needle, 1, true) then return true end
 end
 return false
end

-- Which repo `pr` is in: its own across GitHub, else the checkout's.
local function repoOf(p: Picker, pr: Summary): string
 return string.lower(pr.repo or p.slug or "")
end

-- The PRs the list shows, all matching what the reader typed: the current branch's PR, then the
-- recently opened ones, then the rest in GitHub's order, each PR once.
function M.rows(p: Picker): { Row }
 local needle = string.lower(string.match(p.field.text, "^%s*(.-)%s*$") :: string)
 local function shown(pr: Summary): boolean
  return needle == "" or matches(pr, needle)
 end
 local branch: Summary? = nil
 for _, pr in p.prs or {} do
  if pr.number == p.current and pr.repo == nil then branch = pr end
 end
 local rows: { Row } = {}
 local seen: { [string]: boolean } = {}
 if branch then
  seen[repoOf(p, branch) .. "#" .. branch.number] = true
  if shown(branch) then table.insert(rows, { pr = branch, thisBranch = true }) end
 end
 for _, list in { p.recent, p.prs or {} } do
  for _, pr in list do
   local id = repoOf(p, pr) .. "#" .. pr.number
   if not seen[id] then
    seen[id] = true
    if shown(pr) then table.insert(rows, { pr = pr, thisBranch = false }) end
   end
  end
 end
 return rows
end

function M.move(p: Picker, delta: number)
 p.selected = math.clamp(p.selected + delta, 1, math.max(1, #M.rows(p)))
end

-- What ⏎ opens: a pasted PR link as it is, else the number the field names (in a checkout's list
-- only: across GitHub a number names no repo), else the selected row's.
function M.choice(p: Picker): string?
 if M.linkRepo(p.field.text) then return trim(p.field.text) end
 local named = M.named(p.field.text)
 if named then return if p.anywhere then nil else tostring(named) end
 local row = M.rows(p)[p.selected]
 return if row then M.reference(row.pr) else nil
end

-- Seconds since the epoch of an ISO time like "2026-10-08T09:12:33Z".
local function epoch(iso: string): number?
 local y, mo, d, h, mi, s = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
 if not y then return nil end
 local month, day = tonumber(mo) :: number, tonumber(d) :: number
 -- Days from 1970-01-01 to the date, counting years from March so leap days fall last.
 local year = (tonumber(y) :: number) - (if month <= 2 then 1 else 0)
 local era = year // 400
 local yoe = year - era * 400
 local doy = (153 * ((month + 9) % 12) + 2) // 5 + day - 1
 local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
 return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)
end

local AGO_UNITS = {
 { seconds = 86400 * 365, suffix = "y" }, { seconds = 86400 * 30, suffix = "mo" }, { seconds = 86400 * 7, suffix = "w" },
 { seconds = 86400, suffix = "d" }, { seconds = 3600, suffix = "h" }, { seconds = 60, suffix = "m" },
}

-- How long before `now` (seconds since the epoch) the ISO time `iso` was, as "2h ago".
function M.ago(iso: string, now: number): string
 local at = epoch(iso)
 if not at then return "" end
 local elapsed = now - at
 for _, unit in AGO_UNITS do
  if elapsed >= unit.seconds then return (elapsed // unit.seconds) .. unit.suffix .. " ago" end
 end
 return "just now"
end

return M
