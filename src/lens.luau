--!strict
-- Review lenses: what the AI reviewer pays attention to. A lens is a markdown file: the first
-- `# Heading` names it, the paragraph after that describes it in a line, and the rest is what the
-- reviewer is told. src/fetch.luau reads the files; this module only turns their text into lenses.

export type Lens = { name: string, description: string, instructions: string }

local M = {}

-- The lens a reader starts on, and the one that stands in when a lens can't be found.
M.DEFAULT = "Balanced"

local FALLBACK: Lens = { name = M.DEFAULT, description = "A clear walkthrough of the whole PR.", instructions = "" }

local function lines(text: string): { string }
 local out = {}
 for line in string.gmatch(string.gsub(text, "\r", "") .. "\n", "([^\n]*)\n") do
  table.insert(out, line)
 end
 return out
end

local function blank(line: string): boolean
 return string.match(line, "^%s*$") ~= nil
end

local function heading(line: string): string?
 return string.match(line, "^#%s+(.-)%s*$")
end

-- The lens a file's `text` describes; nil when it doesn't open with a `# Name` line or isn't text.
function M.parse(text: string): Lens?
 if not utf8.len(text) then return nil end
 local rows, at = lines(text), 1
 while rows[at] and blank(rows[at]) do at += 1 end
 local name = if rows[at] then heading(rows[at]) else nil
 if not name or name == "" then return nil end
 at += 1
 while rows[at] and blank(rows[at]) do at += 1 end
 local words = {}
 while rows[at] and not blank(rows[at]) and not string.match(rows[at], "^#+%s") do
  table.insert(words, (string.gsub(rows[at], "^%s+", "")))
  at += 1
 end
 local rest = table.concat(rows, "\n", at)
 return {
  name = name,
  description = (string.gsub(table.concat(words, " "), "%s+", " ")),
  instructions = (string.gsub(rest, "^%s*(.-)%s*$", "%1")),
 }
end

local function parsedAll(texts: { string }): { Lens }
 local found = {}
 for _, text in texts do
  local lens = M.parse(text)
  if lens then table.insert(found, lens) end
 end
 return found
end

local function byName(a: Lens, b: Lens): boolean
 return string.lower(a.name) < string.lower(b.name)
end

-- The lenses to choose from: the built-in ones (Balanced first, then by name), then the reader's
-- own by name. A reader's lens with a built-in's name (in any case) takes its place. Files that
-- aren't lenses are skipped. Balanced is always there.
function M.assemble(builtIn: { string }, own: { string }): { Lens }
 local lenses, at = {}, {}
 local function add(lens: Lens)
  local key = string.lower(lens.name)
  if at[key] then
   lenses[at[key]] = lens
  else
   table.insert(lenses, lens)
   at[key] = #lenses
  end
 end
 local first, others = {}, {}
 for _, lens in parsedAll(builtIn) do
  table.insert(if lens.name == M.DEFAULT then first else others, lens)
 end
 table.sort(others, byName)
 add(first[1] or FALLBACK)
 for _, lens in others do add(lens) end
 local mine = parsedAll(own)
 table.sort(mine, byName)
 for _, lens in mine do add(lens) end
 return lenses
end

-- The lens called `name`, else the first one (Balanced).
function M.pick(lenses: { Lens }, name: string): Lens
 for _, lens in lenses do
  if lens.name == name then return lens end
 end
 return lenses[1] or FALLBACK
end

-- The lens after (`delta` 1) or before (-1) the one called `name`, wrapping round.
function M.step(lenses: { Lens }, name: string, delta: number): Lens
 local at = 1
 for i, lens in lenses do
  if lens.name == name then at = i end
 end
 return lenses[(at - 1 + delta) % math.max(#lenses, 1) + 1] or FALLBACK
end

return M
