local Biomes = require("@generation/Biomes")
local Config = require("@generation/Config")
local Constants = require("@generation/Constants")
local Sampler = require("@generation/Sampler")
local expect = require("./expect")

return function(test)
	local config = Config.defaults()
	local sampler = Sampler.new(config)

	test("sampling is deterministic", function()
		local other = Sampler.new(Config.defaults())
		for i = 1, 200 do
			local x, z = i * 97.3, i * -41.9
			local h1, b1 = sampler.sample(x, z)
			local h2, b2 = other.sample(x, z)
			expect.equal(h1, h2, "height")
			expect.equal(b1, b2, "biome")
		end
	end)

	test("heights stay inside the world and the world has land, sea and variety", function()
		local land, total = 0, 0
		local seen = {}
		local lo, hi = math.huge, -math.huge
		for x = -12000, 12000, 200 do
			for z = -12000, 12000, 200 do
				local h, biome = sampler.sample(x, z)
				expect.between(h, Constants.WORLD_BOTTOM, Constants.WORLD_TOP, "height")
				lo, hi = math.min(lo, h), math.max(hi, h)
				total += 1
				if h > config.seaLevel then
					land += 1
					seen[biome] = (seen[biome] or 0) + 1
				end
			end
		end
		local names = {}
		for index, count in seen do
			table.insert(names, `{Biomes[index].name} {count}`)
		end
		table.sort(names)
		print(
			`    land {string.format("%.0f", land / total * 100)}%, height {math.floor(lo)}..{math.floor(hi)}`
				.. `, biomes: {table.concat(names, ", ")}`
		)
		expect.between(land / total, 0.25, 0.9, "land fraction")
		expect.truthy(hi > 120, "has mountains")
		expect.truthy(lo < -30, "has ocean floor")
		expect.truthy(#names >= 5, "biome variety")
	end)

	test("adjacent columns are continuous (no seams)", function()
		for i = 1, 2000 do
			local x, z = i * 13.7 - 9000, i * 7.1 - 4000
			local a = sampler.height(x, z)
			local b = sampler.height(x + 4, z)
			expect.truthy(math.abs(a - b) < 24, `step at {x},{z}: {a} -> {b}`)
		end
	end)

	test("rivers carve below sea level", function()
		local carved = 0
		for x = -8000, 8000, 32 do
			for z = -4000, 4000, 256 do
				local h, _, continent, river = sampler.sample(x, z)
				if river > 0.9 and continent > 0.2 and h < config.seaLevel then
					carved += 1
				end
			end
		end
		expect.truthy(carved > 0, "found river channels")
	end)

	test("findSpawn returns dry, flat ground", function()
		local x, z, y = Sampler.findSpawn(sampler)
		expect.truthy(y > config.seaLevel + 2, "above sea")
		expect.near(sampler.height(x, z), y, 0.001, "height matches")
	end)

	test("different seeds produce different worlds", function()
		local other = Sampler.new(Config.sanitize({ seed = 2 }))
		local same = 0
		for i = 1, 100 do
			if math.abs(sampler.height(i * 300, 0) - other.height(i * 300, 0)) < 0.01 then
				same += 1
			end
		end
		expect.truthy(same < 10, "worlds differ")
	end)
end
