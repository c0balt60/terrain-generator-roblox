local fs = require("@lune/fs")

local log = require("./log")
local run = require("./run")

export type Options = {
	install: boolean?,
	darkluaConfig: string?,
}

-- Installs tools and packages, regenerates the sourcemap, and transpiles
-- `src` into `out` (which is what Rojo actually serves).
local function prepare(options: Options?)
	local opts: Options = options or {}

	if fs.isDir("out") then
		log.info("Removing existing out...")
		fs.removeDir("out")
	end

	if opts.install ~= false then
		run("rokit", { "install" })
		run("pesde", { "install" })
	end

	run("rojo", { "sourcemap", "default.project.json", "-o", "sourcemap.json" })

	log.info("Generating out...")
	run("darklua", {
		"process",
		"src",
		"out",
		"--config",
		opts.darkluaConfig or ".darklua/dev.darklua.json",
	})

	log.success("Prepared")
end

return prepare
