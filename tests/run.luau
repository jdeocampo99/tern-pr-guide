--!strict
-- Runs every test module. A failed assert names its module and exits non-zero.
-- Tests require pure modules. summary_test also loads block and fetch, with `tern` stubbed in block's
-- environment and every process effect a recorded callback; no other test touches a host module.

local modules: { { name: string, run: () -> () } } = {
	{ name = "model_test", run = require("./model_test") },
	{ name = "github_test", run = require("./github_test") },
	{ name = "state_test", run = require("./state_test") },
	{ name = "sync_test", run = require("./sync_test") },
	{ name = "links_test", run = require("./links_test") },
	{ name = "merge_test", run = require("./merge_test") },
	{ name = "fixes_test", run = require("./fixes_test") },
	{ name = "selection_test", run = require("./selection_test") },
	{ name = "flake_test", run = require("./flake_test") },
	{ name = "rereview_test", run = require("./rereview_test") },
	{ name = "agent_fix_test", run = require("./agent_fix_test") },
	{ name = "agent_state_test", run = require("./agent_state_test") },
	{ name = "review_fix_test", run = require("./review_fix_test") },
	{ name = "summary_test", run = require("./summary_test") },
	{ name = "tandem_test", run = require("./tandem_test") },
}

local failed = 0
for _, module in modules do
	local ok, err = pcall(module.run)
	if ok then
		print("ok   " .. module.name)
	else
		failed += 1
		print("FAIL " .. module.name .. ": " .. tostring(err))
	end
end
if failed > 0 then error(failed .. " test module(s) failed", 0) end
print("all " .. #modules .. " test module(s) passed")
