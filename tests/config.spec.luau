local Config = require("@generation/Config")
local expect = require("./expect")

return function(test)
	test("defaults survive sanitize unchanged", function()
		local defaults = Config.defaults()
		local clean = Config.sanitize(defaults) :: any
		for _, field in Config.FIELDS do
			expect.equal(clean[field.key], (defaults :: any)[field.key], field.key)
		end
	end)

	test("every default sits inside its own bounds", function()
		for _, field in Config.FIELDS do
			if field.kind == "number" then
				expect.between(field.default, field.min, field.max, field.key)
			else
				expect.truthy(table.find(field.options, field.default), field.key)
			end
		end
	end)

	test("every field belongs to a listed group", function()
		for _, field in Config.FIELDS do
			expect.truthy(table.find(Config.GROUPS, field.group), field.key)
		end
	end)

	test("non-table input yields defaults", function()
		local clean = Config.sanitize("nope")
		expect.equal(clean.seed, Config.defaults().seed, "seed")
	end)

	test("numbers are clamped and integer steps snapped", function()
		local clean = Config.sanitize({ viewRadius = 1000, seaLevel = 13, riverWidth = -5, seed = 12.7 })
		expect.equal(clean.viewRadius, 32, "viewRadius clamped")
		expect.equal(clean.seaLevel, 12, "seaLevel snapped to step 4")
		expect.equal(clean.riverWidth, 0, "riverWidth clamped")
		expect.equal(clean.seed, 13, "seed rounded")
	end)

	test("bad types, NaN and infinity fall back", function()
		local base = Config.sanitize({ seed = 55 })
		local clean =
			Config.sanitize({ seed = 0 / 0, viewRadius = math.huge, mode = "Teleport", landHeight = "12" }, base)
		expect.equal(clean.seed, 55, "NaN keeps base")
		expect.equal(clean.viewRadius, base.viewRadius, "inf keeps base")
		expect.equal(clean.mode, base.mode, "unknown choice keeps base")
		expect.equal(clean.landHeight, base.landHeight, "string keeps base")
	end)

	test("unknown keys are dropped and choices accepted", function()
		local clean = Config.sanitize({ mode = "Pregenerate", evil = true }) :: any
		expect.equal(clean.mode, "Pregenerate", "mode")
		expect.equal(clean.evil, nil, "unknown key")
	end)
end
