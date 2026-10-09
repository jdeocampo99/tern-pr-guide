--!strict
-- Runs every test module. A failed assert names its module and exits non-zero.
-- Tests require only pure modules, never fetch, block, window or a view.

local modules: { { name: string, run: () -> () } } = {
	{ name = "model_test", run = require("./model_test") },
	{ name = "state_test", run = require("./state_test") },
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
