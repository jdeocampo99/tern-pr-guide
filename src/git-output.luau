--!strict
-- Turns the output of the git commands fetch.luau runs into the PR's files.
local Pr = require("./pr")

-- A changed file from `git diff --name-status -z`; `oldPath` is set for a rename.
export type Change = { path: string, oldPath: string?, status: string }

-- One file's section of a unified diff.
export type Patch = { rows: { Pr.Row }, adds: number, dels: number, binary: boolean }

local STATUSES: { [string]: string } = { A = "added", C = "added", D = "deleted", M = "modified", R = "renamed", T = "modified" }

local LOCKFILES: { [string]: boolean } = {
 ["package-lock.json"] = true, ["npm-shrinkwrap.json"] = true, ["yarn.lock"] = true, ["pnpm-lock.yaml"] = true,
 ["bun.lock"] = true, ["bun.lockb"] = true, ["deno.lock"] = true, ["Cargo.lock"] = true, ["Gemfile.lock"] = true,
 ["poetry.lock"] = true, ["Pipfile.lock"] = true, ["uv.lock"] = true, ["composer.lock"] = true, ["go.sum"] = true,
 ["flake.lock"] = true, ["Package.resolved"] = true, ["mix.lock"] = true, ["pubspec.lock"] = true,
 ["packages.lock.json"] = true,
}

local ESCAPES: { [string]: string } = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }

local function fields(z: string): { string }
 local parts = string.split(z, "\0")
 if parts[#parts] == "" then table.remove(parts) end
 return parts
end

-- A path as git prints it in a diff header: quoted, with C escapes, when it has unusual characters.
local function unquote(path: string): string
 if string.sub(path, 1, 1) ~= '"' then return path end
 local body = string.sub(path, 2, -2)
 body = string.gsub(body, "\\(%d%d%d)", function(octal: string) return string.char(tonumber(octal, 8) :: number) end)
 return (string.gsub(body, "\\(.)", function(c: string) return ESCAPES[c] or c end))
end

-- The new path a `---`/`+++`/`rename to` value names, dropping git's prefix and trailing tab.
local function headerPath(value: string, prefix: string): string?
 local path = unquote((string.gsub(value, "\t$", "")))
 if string.sub(path, 1, #prefix) == prefix then return string.sub(path, #prefix + 1) end
 return nil
end

-- The path in `diff --git a/X b/X`, for sections with no ---/+++ lines (binary, mode-only).
local function gitHeaderPath(rest: string, known: { [string]: boolean }): string?
 local quoted = string.match(rest, ' ("b/.*")$')
 if quoted then return headerPath(quoted, "b/") end
 local at = 1
 while true do
  local start, finish = string.find(rest, " b/", at, true)
  if not start then return nil end
  local candidate = string.sub(rest, (finish :: number) + 1)
  if known[candidate] then return candidate end
  at = start + 1
 end
end

local function newPatch(): Patch
 return { rows = {}, adds = 0, dels = 0, binary = false }
end

local function lines(content: string): { string }
 local all = string.split(content, "\n")
 if all[#all] == "" then table.remove(all) end
 return all
end

local M = {}

function M.changes(nameStatusZ: string): { Change }
 local parts, changes, i = fields(nameStatusZ), {}, 1
 while i <= #parts do
  local letter = string.sub(parts[i], 1, 1)
  if letter == "R" or letter == "C" then
   table.insert(changes, { path = parts[i + 2], oldPath = if letter == "R" then parts[i + 1] else nil, status = STATUSES[letter] })
   i += 3
  else
   table.insert(changes, { path = parts[i + 1], status = STATUSES[letter] or "modified" })
   i += 2
  end
 end
 return changes
end

-- The paths `git check-attr -z linguist-generated` reports as generated.
function M.generated(checkAttrZ: string): { [string]: boolean }
 local parts, generated = fields(checkAttrZ), {}
 for i = 1, #parts - 2, 3 do
  local value = parts[i + 2]
  if value ~= "unspecified" and value ~= "unset" and value ~= "false" then generated[parts[i]] = true end
 end
 return generated
end

function M.isLockfile(path: string): boolean
 return LOCKFILES[string.match(path, "[^/]*$") :: string] == true
end

-- Each file's rows from `git diff` output, by new path (old path for a deleted file).
function M.patches(diff: string, paths: { string }): { [string]: Patch }
 local known = {}
 for _, path in paths do known[path] = true end
 local patches: { [string]: Patch } = {}
 local patch, oldPath = newPatch(), nil
 -- Line numbers of the next hunk line and how many old/new lines the hunk has left.
 local oldN, newN, oldLeft, newLeft = 0, 0, 0, 0
 local function claim(path: string?)
  if path and not patches[path] then patches[path] = patch end
 end
 for line in string.gmatch(diff, "([^\n]*)\n") do
  local first = string.sub(line, 1, 1)
  if oldLeft > 0 or newLeft > 0 then
   if first == " " then
    table.insert(patch.rows, { kind = "ctx", text = string.sub(line, 2), old = oldN, new = newN } :: Pr.Line)
    oldN, newN, oldLeft, newLeft = oldN + 1, newN + 1, oldLeft - 1, newLeft - 1
   elseif first == "+" then
    table.insert(patch.rows, { kind = "add", text = string.sub(line, 2), new = newN } :: Pr.Line)
    newN, newLeft, patch.adds = newN + 1, newLeft - 1, patch.adds + 1
   elseif first == "-" then
    table.insert(patch.rows, { kind = "del", text = string.sub(line, 2), old = oldN } :: Pr.Line)
    oldN, oldLeft, patch.dels = oldN + 1, oldLeft - 1, patch.dels + 1
   end
  elseif string.sub(line, 1, 11) == "diff --git " then
   patch, oldPath = newPatch(), nil
   claim(gitHeaderPath(string.sub(line, 12), known))
  elseif first == "@" then
   local o, oc, n, nc, label = string.match(line, "^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")
   if o and n then
    oldN, newN = tonumber(o) :: number, tonumber(n) :: number
    oldLeft, newLeft = tonumber(oc) or 1, tonumber(nc) or 1
    table.insert(patch.rows, { kind = "hunk", oldStart = oldN, newStart = newN, label = if label ~= "" then label else nil } :: Pr.Hunk)
   end
  elseif string.sub(line, 1, 4) == "--- " then
   oldPath = headerPath(string.sub(line, 5), "a/")
  elseif string.sub(line, 1, 4) == "+++ " then
   claim(headerPath(string.sub(line, 5), "b/") or oldPath)
  elseif string.sub(line, 1, 10) == "rename to " then
   claim(unquote(string.sub(line, 11)))
  elseif string.sub(line, 1, 13) == "Binary files " then
   patch.binary = true
  end
 end
 return patches
end

-- File contents from `git cat-file --batch`, one object per requested path in order; missing ones
-- are left out.
function M.blobs(batch: string, paths: { string }): { [string]: string }
 local blobs, at = {}, 1
 for _, path in paths do
  local lineEnd = string.find(batch, "\n", at, true)
  if not lineEnd then break end
  local size = string.match(string.sub(batch, at, lineEnd - 1), "^%x+ %a+ (%d+)$")
  at = lineEnd + 1
  if size then
   blobs[path] = string.sub(batch, at, at + (tonumber(size) :: number) - 1)
   at += (tonumber(size) :: number) + 1
  end
 end
 return blobs
end

-- The changed paths whose new side is text, so worth reading whole.
function M.textPaths(changes: { Change }, patches: { [string]: Patch }): { string }
 local paths = {}
 for _, change in changes do
  local patch = patches[change.path]
  if change.status ~= "deleted" and not (patch and patch.binary) then table.insert(paths, change.path) end
 end
 return paths
end

-- The PR's files: each change with its diff rows and, unless deleted or binary, its new-side lines.
function M.files(changes: { Change }, patches: { [string]: Patch }, blobs: { [string]: string }): { Pr.File }
 local files = {}
 for _, change in changes do
  local patch = patches[change.path] or newPatch()
  local blob = blobs[change.path]
  table.insert(files, {
   path = change.path, status = change.status, adds = patch.adds, dels = patch.dels, rows = patch.rows,
   src = if blob then lines(blob) else nil, binary = patch.binary,
  })
 end
 return files
end

return M
