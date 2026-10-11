--!strict
-- The page while there is no review or PR list to show: what loading is doing, or why it stopped.
-- Loading lists the stages it has finished, ticked, then the one it is on, over a bar that sweeps
-- for as long as the wait lasts. No percentage: the stages' lengths are not known in advance.
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

export type Notice = {
 title: string,
 -- The stage under way, or why loading stopped.
 text: string,
 error: boolean,
 -- Stages finished so far, oldest first.
 done: { string },
 -- A message with nothing loading: no stages and no sweeping bar.
 plain: boolean?,
}

local M = {}

local function pr(name: string): string
 return if name ~= "" then "PR " .. name else "the PR"
end

-- Loading `name`, now at `stage`. Given the notice shown until now, the stage it was at counts as finished.
function M.loading(name: string, stage: string, previous: Notice?): Notice
 local done = {}
 if previous and not previous.error then
  for _, text in previous.done do table.insert(done, text) end
  if previous.text ~= "" and previous.text ~= stage then table.insert(done, previous.text) end
 end
 return { title = "Fetching " .. pr(name) .. "…", text = stage, error = false, done = done }
end

-- A plain message that is neither progress nor a failure: `text` under `title`, in the usual text color.
function M.message(title: string, text: string): Notice
 return { title = title, text = text, error = false, done = {}, plain = true }
end

function M.failed(name: string, failure: string): Notice
 return { title = "Couldn't open " .. pr(name), text = failure, error = true, done = {} }
end

function M.findingRepo(): Notice
 return { title = "Review a pull request", text = "Finding the repository…", error = false, done = {} }
end

local function stage(n: number, text: string, finished: boolean): Node
 return el("div", { class = "gp-st" .. (if finished then " gp-st-done" else " gp-st-now"), key = "s" .. n }, {
  if finished then el("span", { class = "gp-st-tick" }, { Ui.icon("check") }) else span("gp-st-spin", ""),
  span("gp-st-text", text),
 })
end

function M.view(notice: Notice): Node
 local kids = { span("gp-notice-title", notice.title) }
 if notice.error or notice.plain then
  table.insert(kids, span("gp-notice-text" .. (if notice.error then " gp-notice-error" else ""), notice.text))
 else
  local stages = {}
  for n, text in notice.done do table.insert(stages, stage(n, text, true)) end
  if notice.text ~= "" then table.insert(stages, stage(#notice.done + 1, notice.text, false)) end
  table.insert(kids, el("div", { class = "gp-st-list", key = "stages" }, stages))
  table.insert(kids, el("span", { class = "gp-st-bar", key = "bar" }, { el("span", { class = "gp-st-sweep", key = "sweep" }) }))
 end
 return el("div", {}, { el("div", { class = "gp-root gp-page", key = "page" }, {
  el("div", { class = "gp-notice", key = "notice" }, kids),
 }) })
end

return M
