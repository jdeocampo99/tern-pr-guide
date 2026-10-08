--!strict
-- The reader's own AI agent (OMP) writing a guide: the model and effort it reviews with, the models
-- it can pick from, and the files a run reads. src/fetch.luau finds the agent and runs it.
local Pr = require("./pr")

-- One model `omp models` lists: what `--model` takes, its display name, and the thinking levels
-- `--thinking` takes for it (none when it can't think).
export type Model = { selector: string, name: string, efforts: { string } }

-- `omp` as the login shell finds it, that shell's PATH (`omp` runs on an interpreter found there),
-- the model and effort a run uses, and the models there are to choose from (empty until listed).
export type Agent = { command: string, path: string, model: string, effort: string?, models: { Model } }

-- Writing a guide for the page's PR: whether a run is going, the seconds it has taken so far, and
-- the first line of why the last run failed.
export type Run = { agent: Agent, running: boolean, seconds: number, error: string? }

local MARKS = { ctx = " ", add = "+", del = "-" }

-- Every thinking level `omp --thinking` takes.
local EFFORTS: { [string]: boolean } = { off = true, minimal = true, low = true, medium = true, high = true, xhigh = true, max = true, auto = true }
-- The effort a newly picked model gets when it can't keep the current one.
local DEFAULT_EFFORT = "high"

local M = {}

-- OMP's settings, under the home directory.
M.CONFIG = "/.omp/agent/config.yml"

-- `raw` as OMP writes a model role ("provider/id:effort"), split into the model and its effort.
function M.parseChoice(raw: string): (string, string?)
 local model, effort = string.match(raw, "^(.*):(%a+)$")
 if model and EFFORTS[effort :: string] then return model, effort end
 return raw, nil
end

function M.new(command: string, path: string, model: string, effort: string?): Agent
 return { command = command, path = path, model = model, effort = effort, models = {} }
end

-- The model without its provider, as the page names it.
function M.name(agent: Agent): string
 return string.match(agent.model, "[^/]+$") or agent.model
end

-- The model and effort, as the model button shows them.
function M.label(agent: Agent): string
 return M.name(agent) .. (if agent.effort then " · " .. agent.effort else "")
end

-- The chat models in `omp models --json` output, decoded; empty when it isn't that shape.
function M.parseModels(raw: any): { Model }
 local models = {}
 if type(raw) ~= "table" or type(raw.models) ~= "table" then return models end
 for _, item in raw.models do
  if type(item) == "table" and type(item.selector) == "string" and (item.kind == nil or item.kind == "chat") then
   local efforts = {}
   if type(item.thinking) == "table" then
    for _, level in item.thinking do
     if type(level) == "string" then table.insert(efforts, level) end
    end
   end
   table.insert(models, { selector = item.selector, name = if type(item.name) == "string" then item.name else item.selector, efforts = efforts })
  end
 end
 return models
end

-- The models whose name or selector contains `query`, ignoring case, in list order.
function M.matching(models: { Model }, query: string): { Model }
 local needle = string.lower(query)
 if needle == "" then return models end
 local found = {}
 for _, model in models do
  if string.find(string.lower(model.name), needle, 1, true) or string.find(string.lower(model.selector), needle, 1, true) then
   table.insert(found, model)
  end
 end
 return found
end

-- The effort `model` runs with when `wanted` was asked for: `wanted` when it takes it, else high,
-- else its strongest; nil for a model that can't think.
function M.effortFor(model: Model, wanted: string?): string?
 if #model.efforts == 0 then return nil end
 if wanted and table.find(model.efforts, wanted) then return wanted end
 if table.find(model.efforts, DEFAULT_EFFORT) then return DEFAULT_EFFORT end
 return model.efforts[#model.efforts]
end

-- The `omp` command that has `agent` follow the prompt at `promptPath`.
function M.argv(agent: Agent, promptPath: string): { string }
 local argv = { agent.command, "-p", "--model", agent.model }
 if agent.effort then
  table.insert(argv, "--thinking")
  table.insert(argv, agent.effort)
 end
 table.insert(argv, M.request(promptPath))
 return argv
end

-- The first `omp` in the directories of `path` (a colon-separated PATH value) that `exists`.
function M.findOnPath(path: string, exists: (string) -> boolean): string?
 for dir in string.gmatch(path, "[^:]+") do
  local candidate = dir .. "/omp"
  if exists(candidate) then return candidate end
 end
 return nil
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
