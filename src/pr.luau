--!strict
export type Hunk = { kind: "hunk", oldStart: number, newStart: number, label: string? }
export type Line = { kind: "ctx" | "add" | "del", text: string, old: number?, new: number? }
export type Row = Hunk | Line

export type File = {
 path: string,
 status: string,
 adds: number,
 dels: number,
 -- Parsed diff rows in file order.
 rows: { Row },
 -- The new-side file lines; absent for a deleted or binary file.
 src: { string }?,
 -- Git shows no lines for a binary file.
 binary: boolean?,
}

export type PR = {
 repo: string,
 number: number,
 title: string,
 url: string,
 author: string,
 baseRef: string,
 -- The PR's head commit.
 head: string,
 files: { File },
}

local M = {}

-- Reads the bundled sample PR, shown when the block opens without a PR.
function M.sample(): PR
 local raw = tern.json.decode(tern.fs.read("fixtures/pr-350.json"))
 local pr = raw.pr
 pr.files = raw.files
 return pr
end

return M
