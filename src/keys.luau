--!strict
-- What each key does in each mode, as the same actions the page's clicks send.
local Fields = require("./text-field")
local Picker = require("./picker")
local Review = require("./review")
local State = require("./state")

export type Action = { act: string, value: string? }

local SCROLLS: { [string]: string } = { pageup = "page-up", pagedown = "page-down", home = "start", ["end"] = "end" }

local M = {}

local function act(name: string, value: (string | number)?): Action
 return { act = name, value = if value == nil then nil else tostring(value) }
end

local function isQuestionMark(key: Key): boolean
 return key.name == "?" or key.text == "?"
end

local function searchKey(key: Key): Action?
 local name = key.name
 if name == "down" then return act("search-move", 1) end
 if name == "up" then return act("search-move", -1) end
 if name == "enter" then return act("search-pick") end
 if name == "escape" then return act("search-close") end
 return nil
end

local function reviewKey(s: State.State, key: Key): Action?
 local name = key.name
 local typed = key.text or name
 if name == "j" or name == "down" then return act("review-move", 1) end
 if name == "k" or name == "up" then return act("review-move", -1) end
 if name == "x" or name == "space" then return act("toggle-item", s.reviewCursor) end
 if name == "a" then return act("toggle-all") end
 local verdict = Review.verdicts[tonumber(typed) or 0]
 if verdict then return act("verdict", verdict.id) end
 if name == "e" then return act("edit-summary") end
 if name == "enter" and (key.meta or key.ctrl) then return act("submit-review") end
 if name == "escape" or name == "r" then return act("toggle-review") end
 return nil
end

local function readingKey(s: State.State, key: Key): Action?
 local name = key.name
 local step = State.currentStep(s)
 if name == "j" then return act("step", 1) end
 if name == "k" then return act("step", -1) end
 if name == "n" then return act("next-suggestion", 1) end
 if name == "p" then return act("next-suggestion", -1) end
 if name == "enter" and key.shift then return act("mark-change", step.change) end
 if name == "enter" then return act("review-step", step.key) end
 if name == "v" then return act("mark-file", step.file) end
 if name == "a" then return act("decide-current", "added") end
 if name == "d" then return act("decide-current", "dismissed") end
 if name == "c" then return act("comment-step") end
 if name == "r" then return act("open-review") end
 if name == "/" or key.text == "/" then return act("open-search") end
 if name == "g" then return act("open-github") end
 if name == "i" then return act("toggle-description") end
 if name == "m" then return act("mark-all") end
 if (name == "s" and key.shift) or name == "S" then return act("mark-supporting") end
 if name == "s" then return act("toggle-group") end
 if name == "o" then return act("open-all-supporting") end
 if name == "h" or isQuestionMark(key) then return act("toggle-help") end
 if name == "escape" and (s.helpOpen or s.review.focus ~= nil) then return act("dismiss") end
 local scroll = SCROLLS[key.name]
 if scroll then return act("scroll", scroll) end
 return nil
end

-- The action `key` triggers, or nil when it changes nothing or, in a text mode, types into the field.
function M.action(s: State.State, key: Key): Action?
 local mode = State.mode(s)
 if mode == "search" then return searchKey(key) end
 if mode == "composer" or mode == "summary" then return nil end
 if mode == "review" and not isQuestionMark(key) then return reviewKey(s, key) end
 return readingKey(s, key)
end

-- The action `key` triggers on the PR picker, or nil when it types into the filter field. j and k
-- move only while the field is empty, so they can still be typed.
function M.pickerAction(p: Picker.Picker, key: Key): Action?
 local name = key.name
 local empty = p.field.text == "" and not (key.ctrl or key.meta or key.alt or key.shift)
 if name == "down" or (empty and name == "j") then return act("picker-move", 1) end
 if name == "up" or (empty and name == "k") then return act("picker-move", -1) end
 if name == "enter" then return act("picker-open") end
 if name == "escape" then return act("picker-clear") end
 return nil
end

-- The action that follows a key typed into a text mode's field.
function M.afterTyping(mode: State.Mode, outcome: Fields.Outcome): Action?
 if mode == "search" then
  return if outcome == "changed" then act("search-run") else nil
 elseif mode == "composer" then
  if outcome == "submit" then return act("comment-save") end
  if outcome == "cancel" then return act("comment-cancel") end
 elseif mode == "summary" then
  if outcome == "submit" or outcome == "cancel" then return act("done-summary") end
 end
 return nil
end

return M
