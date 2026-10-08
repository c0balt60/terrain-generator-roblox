local Biomes = require("@generation/Biomes")
local ChunkBuilder = require("@generation/ChunkBuilder")
local Config = require("@generation/Config")
local Constants = require("@generation/Constants")
local Sampler = require("@generation/Sampler")
local expect = require("./expect")

local biomeIndex = Biomes.index

local function biomeSet(names: { string }): { [number]: boolean }
	local set = {}
	for _, name in names do
		set[biomeIndex(name)] = true
	end
	return set
end

local SNOW_BIOMES = biomeSet({ "Snowy Plains", "Snowy Taiga", "Snowy Slopes" })

-- Walks rows of the world and returns the surface material of the land column
-- at every sea/land crossing, tallied as "beach", "steep" or the material name.
local function shorelines(sampler: Sampler.Sampler, config: Config.Config): ({ [string]: number }, number)
	local h = sampler.height
	local seaLevel = config.seaLevel
	local column = Sampler.newColumn()
	local counts, total = {}, 0
	for z = -9000, 9000, 450 do
		local previous = h(-9000, z)
		for x = -8996, 9000, 4 do
			local current = h(x, z)
			if (previous <= seaLevel) ~= (current <= seaLevel) then
				local lx = if current > seaLevel then x else x - 4
				sampler.sample(lx, z, column)
				local dx = h(lx + 4, z) - h(lx - 4, z)
				local dz = h(lx, z + 4) - h(lx, z - 4)
				local slope = math.sqrt(dx * dx + dz * dz) / 8
				local surface = ChunkBuilder.columnMaterials(config, column, slope)
				local biome = Biomes.list[column.biome]
				local kind = if surface == biome.beach
					then "beach"
					elseif surface == biome.steep then "steep"
					else surface
				counts[kind] = (counts[kind] or 0) + 1
				total += 1
			end
			previous = current
		end
	end
	return counts, total
end

return function(test)
	local config = Config.defaults()
	local sampler = Sampler.new(config)

	test("sampling is deterministic", function()
		local other = Sampler.new(Config.defaults())
		local a, b = Sampler.newColumn(), Sampler.newColumn()
		for i = 1, 200 do
			local x, z = i * 97.3, i * -41.9
			sampler.sample(x, z, a)
			other.sample(x, z, b)
			for key, value in a :: any do
				expect.equal(value, (b :: any)[key], key)
			end
		end
	end)

	test("heights stay inside the world and the world has land, sea and variety", function()
		local land, total = 0, 0
		local seen = {}
		local lo, hi = math.huge, -math.huge
		local column = Sampler.newColumn()
		for x = -12000, 12000, 200 do
			for z = -12000, 12000, 200 do
				local h = sampler.sample(x, z, column).height
				expect.between(h, Constants.WORLD_BOTTOM, Constants.WORLD_TOP, "height")
				lo, hi = math.min(lo, h), math.max(hi, h)
				total += 1
				if h > config.seaLevel then
					land += 1
					seen[column.biome] = (seen[column.biome] or 0) + 1
				end
			end
		end
		local names = {}
		for index, count in seen do
			table.insert(names, `{Biomes.list[index].name} {string.format("%.0f", count / land * 100)}%`)
		end
		table.sort(names)
		print(
			`    land {string.format("%.0f", land / total * 100)}%, height {math.floor(lo)}..{math.floor(hi)}`
				.. `, biomes: {table.concat(names, ", ")}`
		)
		expect.between(land / total, 0.25, 0.9, "land fraction")
		expect.truthy(hi > 300, "has tall mountains")
		expect.truthy(lo < -30, "has ocean floor")
		expect.truthy(lo > -config.oceanDepth - 12, "ocean floor near oceanDepth")
		expect.truthy(#names >= 6, "biome variety")
		expect.between((seen[biomeIndex("Grasslands")] or 0) / land, 0.3, 0.6, "grasslands share")
	end)

	test("mountains form ranges, not lone peaks", function()
		-- Along a long transect, high ground should come in runs: a range is
		-- wider than a single spike, and there is more than one of them.
		local runs, longest, current = 0, 0, 0
		for x = -40000, 40000, 32 do
			if sampler.height(x, 1500) > 150 then
				current += 1
				if current == 1 then
					runs += 1
				end
				longest = math.max(longest, current)
			else
				current = 0
			end
		end
		expect.truthy(runs >= 2, `found {runs} high runs`)
		expect.truthy(longest * 32 >= 300, `widest high run {longest * 32} studs`)
	end)

	test("height is continuous (no seams)", function()
		for i = 1, 4000 do
			local x, z = i * 13.7 - 30000, i * 7.1 - 12000
			local a = sampler.height(x, z)
			local b = sampler.height(x + 0.05, z)
			local c = sampler.height(x, z + 0.05)
			expect.truthy(math.abs(a - b) < 1 and math.abs(a - c) < 1, `jump at {x},{z}: {a} -> {b}, {c}`)
		end
	end)

	test("shorelines are beaches, with rock only on cliffs", function()
		local counts, total = shorelines(sampler, config)
		local beach = counts.beach or 0
		expect.truthy(total > 100, "found shorelines")
		expect.truthy(beach / total > 0.9, `beach at {beach} of {total} crossings`)
		for kind in counts do
			expect.truthy(kind == "beach" or kind == "steep", `unexpected shoreline material {kind}`)
		end
	end)

	test("without cliffs, shorelines are nearly all beach", function()
		local flat = Config.sanitize({ cliffAmount = 0 })
		local counts, total = shorelines(Sampler.new(flat), flat)
		expect.truthy((counts.beach or 0) / total > 0.96, `beach at {counts.beach} of {total} crossings`)
	end)

	test("rivers carve below sea level", function()
		local carved = 0
		local column = Sampler.newColumn()
		for x = -8000, 8000, 32 do
			for z = -4000, 4000, 256 do
				sampler.sample(x, z, column)
				if column.river > 0.9 and column.continent > 0.2 and column.height < config.seaLevel then
					carved += 1
				end
			end
		end
		expect.truthy(carved > 0, "found river channels")
	end)

	test("biomes use their alternate materials", function()
		local high, low, land = 0, 0, 0
		local column = Sampler.newColumn()
		for x = -8000, 8000, 64 do
			for z = -8000, 8000, 64 do
				sampler.sample(x, z, column)
				if column.height > config.seaLevel + 8 then
					land += 1
					local surface = ChunkBuilder.columnMaterials(config, column, 0)
					local biome = Biomes.list[column.biome]
					if surface == biome.surface then
						continue
					elseif surface == biome.patchHigh then
						high += 1
					elseif surface == biome.patchLow then
						low += 1
					end
				end
			end
		end
		expect.between(high / land, 0.05, 0.3, "high patches")
		-- Grasslands, the biggest biome, has no low patches.
		expect.between(low / land, 0.01, 0.2, "low patches")
	end)

	test("biomes follow elevation: wetland, lowland, slopes, then peaks", function()
		local heights: { [number]: { number } } = {}
		local column = Sampler.newColumn()
		for x = -16000, 16000, 160 do
			for z = -16000, 16000, 160 do
				sampler.sample(x, z, column)
				if column.height > config.seaLevel then
					local list = heights[column.biome] or {}
					heights[column.biome] = list
					table.insert(list, column.height - config.seaLevel)
				end
			end
		end
		local function median(name: string): number
			local list = heights[biomeIndex(name)]
			expect.truthy(list and #list > 20, `{name} present`)
			table.sort(list)
			return list[#list // 2 + 1]
		end
		local swamp, grass, meadow, peaks = median("Swamp"), median("Grasslands"), median("Meadow"), median("Peaks")
		expect.truthy(swamp < grass and grass < meadow and meadow < peaks, `{swamp} {grass} {meadow} {peaks}`)
		-- Grasslands sit close to the sea; only mountain flanks lift them higher.
		expect.truthy(grass < 40, `grasslands median {grass} studs above sea`)
	end)

	test("snow only falls on mountains, outside the snow biomes", function()
		local snowBiome, lowest = 0, math.huge
		local column = Sampler.newColumn()
		for x = -16000, 16000, 96 do
			for z = -16000, 16000, 480 do
				sampler.sample(x, z, column)
				if column.height > config.seaLevel and ChunkBuilder.columnMaterials(config, column, 0) == "Snow" then
					if SNOW_BIOMES[column.biome] then
						snowBiome += 1
					else
						lowest = math.min(lowest, column.height - config.seaLevel)
					end
				end
			end
		end
		expect.truthy(snowBiome > 100, "snow biomes are white")
		expect.truthy(lowest > config.slopeElevation, `snow outside snow biomes at {lowest} studs`)
	end)

	test("climate zones are regions, and hot ones never touch frozen ones", function()
		local hot = biomeSet({ "Desert", "Badlands" })
		local touching, runs, run = 0, {}, 0
		local a, b = Sampler.newColumn(), Sampler.newColumn()
		for z = -16000, 16000, 800 do
			for x = -16000, 16000, 64 do
				sampler.sample(x, z, a)
				sampler.sample(x + 300, z, b)
				if (SNOW_BIOMES[a.biome] and hot[b.biome]) or (hot[a.biome] and SNOW_BIOMES[b.biome]) then
					touching += 1
				end
				if SNOW_BIOMES[a.biome] then
					run += 64
				elseif run > 0 then
					table.insert(runs, run)
					run = 0
				end
			end
		end
		table.sort(runs)
		expect.equal(touching, 0, "hot biomes within 300 studs of snow")
		expect.truthy(#runs > 10, "found snow regions")
		expect.truthy(runs[#runs // 2 + 1] >= 500, `median snow region crossing {runs[#runs // 2 + 1]} studs`)
	end)

	test("biome borders don't step in height", function()
		-- Biomes don't set the land's height, so crossing a border should be no
		-- steeper than ordinary ground. 32-stud slopes, sampled across borders.
		local slopes = {}
		local a, b = Sampler.newColumn(), Sampler.newColumn()
		for x = -12000, 12000, 96 do
			for z = -12000, 12000, 96 do
				sampler.sample(x, z, a)
				sampler.sample(x + 32, z, b)
				if a.height > config.seaLevel + 4 and a.biome ~= b.biome then
					table.insert(slopes, math.abs(b.height - a.height) / 32)
				end
			end
		end
		table.sort(slopes)
		local p90, p99 = slopes[math.floor(#slopes * 0.9)], slopes[math.floor(#slopes * 0.99)]
		expect.truthy(#slopes > 500, "found borders")
		expect.truthy(p90 < 1.6 and p99 < 3, `border slope p90 {p90}, p99 {p99}`)
	end)

	test("mountains and coasts rise as slopes, not walls", function()
		local slopes = {}
		for i = 1, 20000 do
			local x, z = i * 13.7 - 90000, i * 7.1 - 40000
			table.insert(slopes, math.abs(sampler.height(x + 4, z) - sampler.height(x, z)) / 4)
		end
		table.sort(slopes)
		local p99, p999 = slopes[math.floor(#slopes * 0.99)], slopes[math.floor(#slopes * 0.999)]
		expect.truthy(p99 < 2.5 and p999 < 5, `4-stud slope p99 {p99}, p99.9 {p999}`)
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
