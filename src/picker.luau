--!strict
-- The page that picks a PR to review: the checkout's open PRs, filtered by what the reader types,
-- and the PR a typed or pasted number or link names.
local Fields = require("./text-field")

-- An open PR as the list shows it.
export type Summary = {
 number: number,
 title: string,
 author: string,
 branch: string,
 draft: boolean,
 -- When it last changed, as GitHub's ISO time.
 updated: string,
 adds: number,
 dels: number,
 files: number,
}

export type Picker = {
 field: Fields.Field,
 -- Nil until the list loads, or when loading it failed.
 prs: { Summary }?,
 -- The current branch's PR, when it has one.
 current: number?,
 error: string?,
 -- PRs with a guide file.
 guided: { [number]: boolean },
 -- Index into `rows`.
 selected: number,
 -- When the list loaded, in seconds since the epoch; "2h ago" counts from here.
 loadedAt: number,
}

export type Row = { pr: Summary, thisBranch: boolean }

local M = {}

M.LIST_FIELDS = "number,title,author,headRefName,isDraft,updatedAt,additions,deletions,changedFiles"

function M.new(guided: { [number]: boolean }): Picker
 return { field = Fields.create(), prs = nil, current = nil, error = nil, guided = guided, selected = 1, loadedAt = 0 }
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
  })
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
 for _, text in { "#" .. pr.number, pr.title, pr.author, pr.branch } do
  if string.find(string.lower(text), needle, 1, true) then return true end
 end
 return false
end

-- The PRs the list shows: the current branch's first, then the rest in GitHub's order, all matching
-- what the reader typed.
function M.rows(p: Picker): { Row }
 local rows: { Row } = {}
 local needle = string.lower(string.match(p.field.text, "^%s*(.-)%s*$") :: string)
 for _, pr in p.prs or {} do
  if needle == "" or matches(pr, needle) then
   local row = { pr = pr, thisBranch = pr.number == p.current }
   if row.thisBranch then table.insert(rows, 1, row) else table.insert(rows, row) end
  end
 end
 return rows
end

function M.move(p: Picker, delta: number)
 p.selected = math.clamp(p.selected + delta, 1, math.max(1, #M.rows(p)))
end

-- What ⏎ opens: a pasted PR link as it is, the number the field names, else the selected row's.
function M.choice(p: Picker): string?
 if M.linkRepo(p.field.text) then return trim(p.field.text) end
 local named = M.named(p.field.text)
 if named then return tostring(named) end
 local row = M.rows(p)[p.selected]
 return if row then tostring(row.pr.number) else nil
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
