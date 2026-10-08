--[[
	Builds a standalone place file at `build/terrain-generator.rbxl`.

	Open it in Studio once, then use `pesde run sync` to live-sync changes into it.
	Pass `--prod` to transpile with the production darklua config.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local log = require("./util/log")
local prepare = require("./util/prepare")
local run = require("./util/run")

local isProd = table.find(process.args, "--prod") ~= nil

prepare({
	darkluaConfig = if isProd then ".darklua/prod.darklua.json" else ".darklua/dev.darklua.json",
})

if not fs.isDir("build") then
	fs.writeDir("build")
end

run("rojo", { "build", "out.project.json", "-o", "build/terrain-generator.rbxl" })
log.success("Built build/terrain-generator.rbxl")
