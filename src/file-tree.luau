--!strict
-- Changed files as a folder tree, laid out the way GitHub lists them: folders before files, each
-- sorted by name, and a folder holding only one folder shown as one row ("src/service").
local Pr = require("./pr")

export type Row = { kind: "folder", name: string, depth: number, path: string } | { kind: "file", file: Pr.File, depth: number }

type Folder = { folders: { [string]: Folder }, files: { Pr.File } }

local function newFolder(): Folder
 return { folders = {}, files = {} }
end

local function before(a: string, b: string): boolean
 local la, lb = string.lower(a), string.lower(b)
 if la ~= lb then return la < lb end
 return a < b
end

local function baseName(path: string): string
 return string.match(path, "[^/]+$") or path
end

local function emit(folder: Folder, depth: number, prefix: string, rows: { Row })
 local names = {}
 for name in folder.folders do table.insert(names, name) end
 table.sort(names, before)
 for _, name in names do
  local child, label = folder.folders[name], name
  while #child.files == 0 do
   local only = next(child.folders)
   if only == nil or next(child.folders, only) ~= nil then break end
   label ..= "/" .. only
   child = child.folders[only]
  end
  local path = prefix .. label
  table.insert(rows, { kind = "folder", name = label, depth = depth, path = path })
  emit(child, depth + 1, path .. "/", rows)
 end
 local files = table.clone(folder.files)
 table.sort(files, function(a: Pr.File, b: Pr.File): boolean return before(baseName(a.path), baseName(b.path)) end)
 for _, file in files do table.insert(rows, { kind = "file", file = file, depth = depth }) end
end

local M = {}

function M.rows(files: { Pr.File }): { Row }
 local root = newFolder()
 for _, file in files do
  local folder = root
  for part in string.gmatch(file.path, "([^/]+)/") do
   folder.folders[part] = folder.folders[part] or newFolder()
   folder = folder.folders[part]
  end
  table.insert(folder.files, file)
 end
 local rows = {}
 emit(root, 0, "", rows)
 return rows
end

-- `files` in the order the tree lists them.
function M.order(files: { Pr.File }): { Pr.File }
 local ordered = {}
 for _, row in M.rows(files) do
  if row.kind == "file" then table.insert(ordered, row.file) end
 end
 return ordered
end

return M
