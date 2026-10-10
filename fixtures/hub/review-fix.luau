--!strict
-- Hand-written, frozen two-file/three-hunk fix, including a take-both rule and unrelated commit changes.
local AgentFix = require("../../src/hub/agent-fix")
local Cards: any = require("./agent-cards")

local M = { asOf = 1791590400, asOfIso = "2026-10-10T00:00:00Z", prs = {}, agents = {} }
M.key = "acme/web#1803"
M.fix = {
	worktree = "/pool/acme/web/wt-review", branch = "topic", base = "main",
	headOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", commit = "cccccccccccccccccccccccccccccccccccccccc",
	summary = "Merge main and preserve branch behavior", usedAgent = true,
	hunks = {
		{
			id = "fonts-loader", path = "src/fonts.ts", start = 2,
			base = { "shared", "old loader" }, ours = { "shared", "branch range" }, theirs = { "shared", "main manifest" },
			context = { before = { "// loader" }, after = { "// end loader" } }, subjects = { ours = { "Add range" }, theirs = { "Use manifest" } },
			resolved = { by = "agent", lines = {
				{ tag = "base", text = "shared" }, { tag = "theirs", text = "main manifest" },
				{ tag = "ours", text = "branch range" }, { tag = "agent", text = "  combine(range, manifest);" },
			} },
		},
		{
			id = "fonts-cache", path = "src/fonts.ts", start = 9,
			base = { "old cache" }, ours = { "branch cache" }, theirs = { "main cache" },
			context = { before = { "// cache" }, after = { "// end cache" } }, subjects = { ours = {}, theirs = {} },
			resolved = { by = "agent", lines = { { tag = "agent", text = "const cache = combineCaches();" } } },
		},
		{
			id = "note-props", path = "src/note.ts", start = 2,
			base = { "title: string;" }, ours = { "title: string;", "script?: string;" }, theirs = { "title: string;", "lessonId: string;" },
			context = { before = { "type Props = {" }, after = { "};" } }, subjects = { ours = {}, theirs = {} },
			resolved = { by = "rule", lines = {
				{ tag = "base", text = "title: string;" }, { tag = "ours", text = "script?: string;" }, { tag = "theirs", text = "lessonId: string;" },
			} },
		},
	},
} :: AgentFix.Fix
M.files = {
	["src/fonts.ts"] = "// loader\nshared\nmain manifest\nbranch range\n  combine(range, manifest);\n// end loader\n\n// cache\nconst cache = combineCaches();\n// end cache\nconst unrelated = true;\n",
	["src/note.ts"] = "type Props = {\ntitle: string;\nscript?: string;\nlessonId: string;\n};\nexport const unrelated = 42;\n",
}
M.details = {
	key = M.key, headOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", fetchedAt = "2026-10-10T00:00:00Z",
	reviews = {}, threads = {}, checks = {}, changedPaths = { "src/fonts.ts", "src/note.ts" },
	conflicts = {
		{ path = "src/fonts.ts", hunks = {
			{ start = 2, branch = { "shared", "branch range" }, main = { "shared", "main manifest" } },
			{ start = 9, branch = { "branch cache" }, main = { "main cache" } },
		} },
		{ path = "src/note.ts", hunks = { { start = 2, branch = { "title: string;", "script?: string;" }, main = { "title: string;", "lessonId: string;" } } } },
	},
}
local pr = table.clone(Cards.prs[3])
pr.headOid, pr.title = M.fix.headOid, "Review the merged font loader and note props while preserving the branch's glyph range and cache behavior"
M.prs = { pr }
M.agents = { [M.key] = { kind = "ready", fix = M.fix, reviewed = {} } }

return M
