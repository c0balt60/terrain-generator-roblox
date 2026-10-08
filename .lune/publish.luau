--[[
	Builds the prod place and publishes it to Roblox through Open Cloud (rbxcloud).

	Env: RBXCLOUD_API_KEY (key with universe-places:write on the experience),
	UNIVERSE_ID, PLACE_ID. rbxcloud reads the key from the env itself, so it
	never appears on a logged command line.
	Pass `--saved` to upload a saved version without publishing it live.
]]

local process = require("@lune/process")

local log = require("./util/log")
local run = require("./util/run")

local env = process.env
local isSaved = table.find(process.args, "--saved") ~= nil

if not env.RBXCLOUD_API_KEY then
	log.error("Missing env var RBXCLOUD_API_KEY")
	process.exit(1)
end
for _, name in { "UNIVERSE_ID", "PLACE_ID" } do
	if not (env[name] and env[name]:match("^%d+$")) then
		log.error(`Env var {name} must be a numeric id`)
		process.exit(1)
	end
end

run("lune", { "run", ".lune/build", "--prod" })
run("rbxcloud", {
	"experience",
	"publish",
	"--filename",
	"build/terrain-generator.rbxl",
	"--universe-id",
	env.UNIVERSE_ID,
	"--place-id",
	env.PLACE_ID,
	"--version-type",
	if isSaved then "saved" else "published",
})
log.success(if isSaved then "Saved place version" else "Published place")
