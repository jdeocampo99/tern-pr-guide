--!strict
local M = {}

function M.baseName(path: string): string
 return string.match(path, "[^/]+$") or path
end

function M.dirName(path: string): string
 return string.match(path, "^(.*/)") or ""
end

function M.extension(path: string): string
 return string.match(path, "%.(%w+)$") or ""
end

-- A node key built from a path: letters and digits only.
function M.keyOf(text: string): string
 return (string.gsub(text, "[^%w]", "_"))
end

function M.lineSpan(from: number, to: number): string
 return if from == to then "line " .. to else "lines " .. from .. "–" .. to
end

function M.location(file: string, from: number, to: number): string
 return M.baseName(file) .. ":" .. (if from == to then tostring(to) else from .. "–" .. to)
end

-- One-line plain preview: code ticks dropped, whitespace collapsed, cut at a word boundary.
function M.preview(text: string, max: number): string
 local plain = string.gsub(string.gsub(text, "`", ""), "%s+", " ")
 if #plain <= max then return plain end
 return (string.match(string.sub(plain, 1, max), "^(.*)%s") or string.sub(plain, 1, max)) .. "…"
end

-- Rows a text takes when wrapped at `perLine` characters; blank lines count as one.
function M.wrappedLines(text: string, perLine: number): number
 local n = 0
 for paragraph in string.gmatch(text .. "\n", "([^\n]*)\n") do
  n += math.max(1, math.ceil(#paragraph / perLine))
 end
 return n
end

-- The first character of `name`, upper-cased.
function M.initial(name: string): string
 return string.upper(string.match(name, utf8.charpattern) or "?")
end

-- A raised error as one readable line: its first line, without Luau's `runtime error:` and
-- source position prefixes.
function M.errorLine(err: any): string
 local line = string.gsub(string.match(tostring(err), "^[^\n]*") :: string, "^runtime error: ", "")
 return (string.gsub(line, "^[^:]*%.luau:%d+: ", ""))
end

return M
