--!strict
-- The reader's own AI agent (OMP) writing a guide: the model it reviews with and the files a run
-- reads. src/fetch.luau finds the agent and runs it.
local Pr = require("./pr")

-- `omp` as the login shell finds it, that shell's PATH (`omp` runs on an interpreter found there),
-- the model of its review role, and that model without its provider for display.
export type Agent = { command: string, path: string, model: string, name: string }

-- Writing a guide for the page's PR: whether a run is going, the seconds it has taken so far, and
-- the first line of why the last run failed.
export type Run = { agent: Agent, running: boolean, seconds: number, error: string? }

local MARKS = { ctx = " ", add = "+", del = "-" }

local M = {}

-- OMP's settings, under the home directory.
M.CONFIG = "/.omp/agent/config.yml"

function M.new(command: string, path: string, model: string): Agent
 return { command = command, path = path, model = model, name = string.match(model, "[^/]+$") or model }
end

-- A YAML scalar without its quotes or trailing comment.
local function scalar(raw: string): string
 local quoted = string.match(raw, "^\"([^\"]*)\"") or string.match(raw, "^'([^']*)'")
 if quoted then return quoted end
 return (string.gsub(raw, "%s+#.*$", ""))
end

-- The model of OMP's `review` role, else its `default` one, from the `modelRoles:` block of its
-- config.yml; nil when neither is set.
function M.reviewModel(config: string): string?
 local roles: { [string]: string } = {}
 local inRoles = false
 for line in string.gmatch(config .. "\n", "([^\n]*)\n") do
  line = string.gsub(line, "%s+$", "")
  if line == "" or string.match(line, "^%s*#") then continue end
  if string.match(line, "^%S") then
   inRoles = string.match(line, "^modelRoles:%s*$") ~= nil or string.match(line, "^modelRoles:%s+#") ~= nil
  elseif inRoles then
   local key, value = string.match(line, "^  ([%w_%-]+):%s*(.*)$")
   if key and value then roles[key] = scalar(value) end
  end
 end
 for _, role in { "review", "default" } do
  if roles[role] and roles[role] ~= "" then return roles[role] end
 end
 return nil
end

-- Where a run for `pr` keeps the diff and prompt it reads.
function M.workDir(pr: Pr.PR): string
 return "/tmp/prguide-" .. string.gsub(pr.repo, "/", "-") .. "-" .. pr.number
end

-- Every changed file's diff with the new-file line number in front of each line that has one, so
-- the agent can point at lines without counting.
function M.numberedDiff(files: { Pr.File }): string
 local out = {}
 for _, file in files do
  table.insert(out, "=== " .. file.path .. " (" .. file.status .. ")")
  if file.binary then table.insert(out, "(binary, no lines)") end
  for _, row in file.rows do
   if row.kind == "hunk" then
    table.insert(out, "")
    table.insert(out, "@@ -" .. row.oldStart .. " +" .. row.newStart .. " @@" .. (if row.label then " " .. row.label else ""))
   else
    local number = if row.kind ~= "del" and row.new then tostring(row.new) else ""
    table.insert(out, string.format("%6s %s %s", number, MARKS[row.kind], row.text))
   end
  end
  table.insert(out, "")
 end
 return table.concat(out, "\n")
end

-- The prompt template with its `{{placeholders}}` filled in.
function M.prompt(template: string, values: { [string]: string }): string
 return (string.gsub(template, "{{(%w+)}}", function(name: string): string
  return values[name] or "{{" .. name .. "}}"
 end))
end

-- The one message `omp -p` gets.
function M.request(promptPath: string): string
 return "Read " .. promptPath .. " and follow it exactly."
end

return M
