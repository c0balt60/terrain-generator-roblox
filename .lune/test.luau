--[[
	Headless test runner for the Roblox-API-free generation core.

	Each `tests/*.spec.luau` returns `function(test)`, and calls
	`test(name, fn)` for every case. A case fails if `fn` errors.
	`pesde run test -- noise` only runs spec files whose name contains "noise".
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local log = require("./util/log")

local filter = process.args[1]

local files = {}
for _, name in fs.readDir("tests") do
	if name:match("%.spec%.luau$") and (filter == nil or name:find(filter, 1, true)) then
		table.insert(files, name)
	end
end
table.sort(files)

local passed, failed = 0, 0

for _, file in files do
	log.info(file)
	local spec = (require :: any)(`../tests/{file:gsub("%.luau$", "")}`)
	spec(function(name: string, fn: () -> ())
		local start = os.clock()
		local ok, err = pcall(fn)
		local ms = (os.clock() - start) * 1000
		if ok then
			passed += 1
			print(`  ok   {name} ({string.format("%.1f", ms)} ms)`)
		else
			failed += 1
			log.error(`  FAIL {name}\n       {err}`)
		end
	end)
end

if failed > 0 then
	log.error(`{failed} failed, {passed} passed`)
	process.exit(1)
end
log.success(`{passed} passed`)
