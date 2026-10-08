--[[
	Static gate: sourcemap + darklua, selene, StyLua check, luau-lsp type
	analysis against Roblox definitions, then the headless Lune tests.

	This proves the code builds and type-checks and that the pure generator
	behaves. It does not prove anything about Terrain writes; that needs Studio.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")

local log = require("./util/log")
local prepare = require("./util/prepare")
local run = require("./util/run")

local DEFINITIONS_URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau"
local DEFINITIONS_PATH = ".typedefs/globalTypes.d.luau"

prepare({ install = false })

if not fs.isFile(DEFINITIONS_PATH) then
	log.info("Downloading Roblox type definitions...")
	if not fs.isDir(".typedefs") then
		fs.writeDir(".typedefs")
	end
	local response = net.request(DEFINITIONS_URL)
	if not response.ok then
		log.error(`Failed to download definitions: {response.statusCode}`)
		process.exit(1)
	end
	fs.writeFile(DEFINITIONS_PATH, response.body)
end

local failures = {}

local function check(name: string, program: string, args: { string })
	if not run(program, args, true) then
		table.insert(failures, name)
	end
end

check("selene", "selene", { "src" })
check("stylua", "stylua", { "--check", "src", "tests", ".lune" })

-- luau-lsp reports on stderr and exits non-zero on errors.
check("luau-lsp", "luau-lsp", {
	"analyze",
	`--definitions=@roblox={DEFINITIONS_PATH}`,
	"--sourcemap=sourcemap.json",
	"--base-luaurc=.luaurc",
	"--platform=roblox",
	"--ignore=**/roblox_packages/**",
	"--ignore=**/_Index/**",
	"src",
})

check("tests", "lune", { "run", ".lune/test" })

if #failures > 0 then
	log.error(`verify failed: {table.concat(failures, ", ")}`)
	process.exit(1)
end
log.success("verify passed: builds, lints, type-checks, tests pass")
