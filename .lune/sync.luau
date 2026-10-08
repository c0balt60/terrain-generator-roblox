--[[
	Watch mode: keeps `sourcemap.json` and `out/` up to date, then serves
	`out.project.json` to the Rojo Studio plugin.
]]

local process = require("@lune/process")

local log = require("./util/log")
local prepare = require("./util/prepare")

prepare()

log.info("Starting watch mode...")

process.create("rojo", {
	"sourcemap",
	"default.project.json",
	"-o",
	"sourcemap.json",
	"--watch",
}, { stdio = "forward", shell = true })

process.create("darklua", {
	"process",
	"--watch",
	"src",
	"out",
	"--config",
	".darklua/dev.darklua.json",
}, { stdio = "forward", shell = true })

process.exec("rojo", { "serve", "out.project.json" }, { stdio = "forward", shell = true })
