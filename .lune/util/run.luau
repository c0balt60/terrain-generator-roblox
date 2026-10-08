--[[
	Thin wrapper around `process.exec` that forwards output and fails loudly.

	Several tools in this chain exit 0 while failing (darklua on an unresolved
	require is the usual one), so callers that care should still read output.
	This only guarantees a non-zero exit is never swallowed.
]]

local process = require("@lune/process")

local log = require("./log")

local function run(program: string, args: { string }, allowFailure: boolean?): boolean
	log.info(`> {program} {table.concat(args, " ")}`)
	local result = process.exec(program, args, { stdio = "forward", shell = true })
	if not result.ok and not allowFailure then
		log.error(`{program} exited with code {result.code}`)
		process.exit(result.code)
	end
	return result.ok
end

return run
