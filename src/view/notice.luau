--!strict
-- The page while there is no review or PR list to show: what loading is doing, or why it stopped.
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

export type Notice = { title: string, text: string, error: boolean }

local M = {}

local function pr(name: string): string
 return if name ~= "" then "PR " .. name else "the PR"
end

function M.loading(name: string, stage: string): Notice
 return { title = "Fetching " .. pr(name) .. "…", text = stage, error = false }
end

function M.failed(name: string, failure: string): Notice
 return { title = "Couldn't open " .. pr(name), text = failure, error = true }
end

function M.findingRepo(): Notice
 return { title = "Review a pull request", text = "Finding the repository…", error = false }
end

function M.view(notice: Notice): Node
 return el("div", {}, { el("div", { class = "gp-root gp-page", key = "page" }, {
  el("div", { class = "gp-notice", key = "notice" }, {
   span("gp-notice-title", notice.title),
   span("gp-notice-text" .. (if notice.error then " gp-notice-error" else ""), notice.text),
  }),
 }) })
end

return M
