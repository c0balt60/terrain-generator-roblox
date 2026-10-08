--!strict
--!native
--!optimize 2
--[[
	Column sampler: turns a world (x, z) into everything the chunk builder needs
	to know about that column. Terrain comes first and biomes follow it, so a
	biome never decides how high the land is. The layers, in order:

	1. Continentalness: very low-frequency noise splitting ocean from land.
	2. Coast: a fixed profile across the shoreline (shelf, beach, then the land
	   ramps in), so every coast gets a beach. Cliff stretches rise sharply
	   behind a narrow beach.
	3. Land: plains and eroded fractal hills, mixed by a low-frequency relief noise.
	4. Mountains: ranges follow the zero lines of warped low-frequency noise, so
	   they come out as long chains: a broad uplift with eroded ridged peaks on top.
	5. Biomes: temperature and humidity bands plus a terrain band from the
	   elevation (wet ground, lowland, slopes, peaks) look the biome up in the
	   tables in Biomes, blending across band edges. Each biome adds only a small
	   surface form (dunes, mesas, ...).
	6. Rivers: thin bands where low-frequency noise crosses zero are carved
	   down below sea level, fading out as the land rises.

	The returned height is continuous, so occupancy can be derived from it
	directly and the result is smooth terrain rather than stair steps.
]]

local Biomes = require("./Biomes")
local Config = require("./Config")
local Constants = require("./Constants")
local Noise = require("./Noise")

local fbm = Noise.fbm
local ridged = Noise.ridged
local erodedFbm = Noise.erodedFbm
local erodedRidged = Noise.erodedRidged

-- Salts keep each layer's permutation independent for the same world seed.
local SALT_CONTINENT = 1
local SALT_DETAIL = 2
local SALT_MOUNTAIN = 3
local SALT_RANGE = 4
local SALT_TEMPERATURE = 5
local SALT_MOISTURE = 6
local SALT_RIVER = 7
local SALT_RANGE_WARP = 8
local SALT_RANGE_PRESENCE = 9
local SALT_CLIFF = 10
local SALT_PATCH = 11
local SALT_HILLS = 12
local SALT_RELIEF = 13
local SALT_SHAPE = 14
local SALT_SHAPE_ALT = 15

local MIN_HEIGHT = Constants.WORLD_BOTTOM + 8
local MAX_HEIGHT = Constants.WORLD_TOP - 8

-- Dry land, river banks and wetlands settle this far above sea level.
local BANK_HEIGHT = 2
-- Biome forms with less weight than this are skipped. The rest are rescaled
-- from this cut, so skipping them doesn't leave a seam.
local SHAPE_CUTOFF = 0.02
-- Depth of the continental shelf, as a fraction of the ocean depth.
local SHELF_DEPTH = 0.3
-- Half-width, in studs of elevation, of the blend between terrain bands.
local TERRAIN_BLEND = 16
-- Top of the wet low ground where swamps form, in studs above sea level.
local WETLAND_TOP = 10
-- Snow line shift per unit of temperature: colder climates snow lower down.
local SNOW_PER_TEMPERATURE = 110
-- The snow line never comes lower than this far above the start of the slopes,
-- so outside the snow biomes only mountains carry snow.
local SNOW_FLOOR = 40
-- Range line warp amplitude, in range-noise units. Kept gentle: a strong warp
-- squeezes the noise and turns ranges into walls.
local RANGE_WARP = 0.2
-- Typical slope of the range noise per range-noise unit, measured. Dividing by
-- it turns |noise| into an approximate distance to the range line.
local RANGE_SLOPE = 2.5
-- Continentalness over which land ramps in behind the beach, plus a little
-- more for every stud of height it has to climb.
local INLAND_RAMP = 0.22
local INLAND_RAMP_PER_STUD = 0.002
-- Width of the peaked spine as a fraction of the whole range width.
local SPINE_WIDTH = 0.45
-- How far the detail noise shifts the elevation used to pick biomes, so band
-- edges wander instead of tracing contour lines.
local ELEVATION_JITTER = 20

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	Finds the band `x` falls in among the sorted `edges` (band 1 is below the
	first edge). Within `halfWidth` of an edge it returns the bands on both sides
	and the weight of the upper one; otherwise the same band twice and 0. Bands
	are wider than 2 * halfWidth, so only one edge is ever in reach.
]]
local function findBand(edges: { number }, x: number, halfWidth: number): (number, number, number)
	local i = 1
	local count = #edges
	while i <= count and x >= edges[i] do
		i += 1
	end
	if i <= count and edges[i] - x < halfWidth then
		return i, i + 1, smoothstep(-halfWidth, halfWidth, x - edges[i])
	elseif i > 1 and x - edges[i - 1] < halfWidth then
		return i - 1, i, smoothstep(-halfWidth, halfWidth, x - edges[i - 1])
	end
	return i, i, 0
end

-- Polynomial smooth maximum: max(a, b) with the corner rounded over width k.
local function smoothMax(a: number, b: number, k: number): number
	local h = math.clamp(0.5 + 0.5 * (a - b) / k, 0, 1)
	return b + (a - b) * h + k * h * (1 - h)
end

--[[
	Everything known about one world column. `sample` fills one in place, so a
	chunk build reuses a single table instead of allocating per column.
]]
export type Column = {
	height: number, -- Surface Y in studs.
	biome: number, -- Index into Biomes of the dominant biome.
	continent: number, -- Continentalness, < 0 is ocean.
	river: number, -- 0..1 river channel strength.
	shore: number, -- 0..1, 1 on beaches, shallows and river banks.
	patch: number, -- Roughly -1..1 noise choosing material patches.
	snowLine: number, -- Y above which flat ground turns to snow.
}

export type Sampler = {
	config: Config.Config,
	sample: (x: number, z: number, column: Column) -> Column,
	height: (x: number, z: number) -> number,
}

local Sampler = {}

function Sampler.newColumn(): Column
	return {
		height = 0,
		biome = 1,
		continent = 0,
		river = 0,
		shore = 0,
		patch = 0,
		snowLine = 0,
	}
end

-- Maps the 0..1 cliff amount to a threshold on the cliff noise. The noise is
-- close to uniform over about [-0.5, 0.5], so the amount is roughly the
-- fraction of coastline that is cliffed.
local function cliffThreshold(amount: number): number
	return (0.5 - amount) * 1.05 - 0.06
end

function Sampler.new(config: Config.Config): Sampler
	local seed = config.seed

	local continentNoise = Noise.simplex2(seed, SALT_CONTINENT)
	local detailNoise = Noise.simplex2(seed, SALT_DETAIL)
	local mountainNoise = Noise.simplex2d(seed, SALT_MOUNTAIN)
	local rangeNoise = Noise.simplex2(seed, SALT_RANGE)
	local rangeWarpNoise = Noise.simplex2(seed, SALT_RANGE_WARP)
	local presenceNoise = Noise.simplex2(seed, SALT_RANGE_PRESENCE)
	local temperatureNoise = Noise.simplex2(seed, SALT_TEMPERATURE)
	local moistureNoise = Noise.simplex2(seed, SALT_MOISTURE)
	local riverNoise = Noise.simplex2(seed, SALT_RIVER)
	local cliffNoise = Noise.simplex2(seed, SALT_CLIFF)
	local patchNoise = Noise.simplex2(seed, SALT_PATCH)
	local hillNoise = Noise.simplex2d(seed, SALT_HILLS)
	local reliefNoise = Noise.simplex2(seed, SALT_RELIEF)
	local shapeNoise = Noise.simplex2(seed, SALT_SHAPE)
	local shapeAltNoise = Noise.simplex2(seed, SALT_SHAPE_ALT)

	local invContinent = 1 / config.continentScale
	local invDetail = 1 / config.detailScale
	local invHill = 1 / config.hillScale
	local invRelief = 1 / config.reliefScale
	local invRange = 1 / config.rangeScale
	local rangeDistance = config.rangeScale / RANGE_SLOPE
	local invMountain = 1 / config.mountainScale
	local invBiome = 1 / config.biomeScale
	local invRiver = 1 / config.riverScale

	local seaLevel = config.seaLevel
	local coastBias = config.coastBias
	local oceanDepth = config.oceanDepth
	local landHeight = config.landHeight
	local detailStrength = config.detailStrength
	local hillHeight = config.hillHeight
	local erosion = config.erosion
	local rangeWidth = config.rangeWidth
	local mountainBase = config.mountainBase
	local mountainHeight = config.mountainHeight
	local beachHeight = config.beachHeight
	local beachWidth = config.beachWidth
	local cliffAmount = config.cliffAmount
	local cliffEdge = cliffThreshold(cliffAmount)
	local cliffHeight = config.cliffHeight
	local climateBlend = config.biomeBlend
	local temperatureBias = config.temperatureBias
	local moistureBias = config.moistureBias
	local riverWidth = config.riverWidth
	local riverDepth = config.riverDepth
	local riverMaxElevation = config.riverMaxElevation
	local snowLine = config.snowLine

	-- Terrain band edges. Each band is kept wider than the blend between them.
	local slopeEdge = math.max(config.slopeElevation, WETLAND_TOP + 2 * TERRAIN_BLEND + 1)
	local peakEdge = math.max(config.peakElevation, slopeEdge + 2 * TERRAIN_BLEND + 1)
	local terrainEdges = { WETLAND_TOP, slopeEdge, peakEdge }
	local snowFloor = slopeEdge + SNOW_FLOOR

	-- Biome surface forms. Each returns a continuous offset in studs on top of
	-- the land; the coordinate offsets stop forms that share a noise from lining up.
	local shapes: { [Biomes.Shape]: (x: number, z: number) -> number } = {
		-- Gentle undulation; the land's own hills do the rest.
		meadow = function(x: number, z: number): number
			return fbm(shapeNoise, x / 600, z / 600, 2) * 6 + fbm(shapeAltNoise, x / 140, z / 140, 2) * 3
		end,
		-- Uneven ridgelines.
		ridges = function(x: number, z: number): number
			return ridged(shapeNoise, x / 360 + 41.7, z / 360 - 12.3, 3) * 28 - 8
		end,
		-- Low rocky knolls.
		knolls = function(x: number, z: number): number
			local n = ridged(shapeAltNoise, x / 200 - 73.1, z / 200 + 5.9, 3)
			return n * n * 20 - 3
		end,
		-- Busy, medium-scale hills.
		forest = function(x: number, z: number): number
			return fbm(shapeNoise, x / 300 - 19.4, z / 300 + 88.2, 4) * 16
		end,
		-- Small bumps and shallow pools that dip below sea level.
		hummocks = function(x: number, z: number): number
			local pools = smoothstep(0.1, 0.4, fbm(shapeAltNoise, x / 150 + 7.7, z / 150 + 61.3, 2))
			return fbm(shapeNoise, x / 40, z / 40, 2) * 2.5 - pools * 6
		end,
		-- Two-tier flat-topped mesas with steep sides.
		mesas = function(x: number, z: number): number
			local n = fbm(shapeAltNoise, x / 420 + 33.3, z / 420 - 47.5, 3) * 0.5 + 0.5
			return smoothstep(0.56, 0.6, n) * 26
				+ smoothstep(0.68, 0.71, n) * 18
				+ fbm(shapeNoise, x / 200 + 5.1, z / 200 + 5.1, 2) * 5
		end,
		-- Wind-aligned dunes: a long windward rise and a short, steeper lee face.
		dunes = function(x: number, z: number): number
			local warp = fbm(shapeNoise, x / 500 - 60.6, z / 500 + 2.2, 2) * 1.2
			local v = (x * 0.8 + z * 0.6) / 120 + warp
			local f = v - math.floor(v)
			local p = if f < 0.8 then f / 0.8 else (1 - f) / 0.2
			p = p * p * (3 - 2 * p)
			return p * (8 + 10 * (fbm(shapeAltNoise, x / 700 - 9.9, z / 700 - 9.9, 2) * 0.5 + 0.5))
		end,
		-- Sharp, broken rock on the high peaks.
		crags = function(x: number, z: number): number
			local n = ridged(shapeAltNoise, x / 110 + 27.4, z / 110 - 93.6, 3)
			return n * n * 16 - 4
		end,
	}

	local list = Biomes.list
	local tables = Biomes.tables
	local temperatureEdges = Biomes.TEMPERATURE_EDGES
	local humidityEdges = Biomes.HUMIDITY_EDGES
	local shapeOf = table.create(#list)
	for i, biome in list do
		shapeOf[i] = shapes[biome.shape]
	end

	-- Per-biome weight of the column being sampled, and which entries are set.
	local weights = table.create(#list, 0)
	local touched = table.create(8, 0)
	local touchedCount = 0
	local t0, t1, tw, h0, h1, hw = 1, 1, 0, 1, 1, 0

	local function addBiome(biome: number, w: number)
		if w > 0 then
			if weights[biome] == 0 then
				touchedCount += 1
				touched[touchedCount] = biome
			end
			weights[biome] += w
		end
	end

	-- Adds the four climate corners of one terrain band.
	local function addBand(terrain: number, w: number)
		if w > 0 then
			local lookup = tables[terrain]
			local cold, warm = lookup[t0], lookup[t1]
			addBiome(cold[h0], w * (1 - tw) * (1 - hw))
			addBiome(cold[h1], w * (1 - tw) * hw)
			addBiome(warm[h0], w * tw * (1 - hw))
			addBiome(warm[h1], w * tw * hw)
		end
	end

	local function sample(x: number, z: number, column: Column): Column
		local detail = fbm(detailNoise, x * invDetail, z * invDetail, 4)

		-- 1. Continent
		local continent = fbm(continentNoise, x * invContinent, z * invContinent, 5) * 1.6 + coastBias

		-- Rivers run where this band is near zero (carved in step 6).
		local riverBand = if riverWidth > 0 then math.abs(fbm(riverNoise, x * invRiver, z * invRiver, 3)) else 1

		-- 2. Coast. `shore` is the profile relative to sea level: the beach
		-- slope carries on underwater down to a shelf, then the ocean floor
		-- takes over once it is deeper. Cliffs open up where a river reaches the
		-- sea, so it cuts a gap instead of ending in a wall.
		local cliff = 0
		if cliffAmount > 0 then
			cliff = smoothstep(cliffEdge, cliffEdge + 0.12, fbm(cliffNoise, x / 900, z / 900, 2))
				* smoothstep(riverWidth * 2, riverWidth * 7, riverBand)
		end
		local beachC = beachWidth * (1 - 0.6 * cliff)
		local beachSlope = 2 * beachHeight / beachC
		local shore
		if continent < 0 then
			local shelf = math.min(beachSlope * -continent, oceanDepth * SHELF_DEPTH)
			shore = -math.max(shelf, oceanDepth * smoothstep(0, 0.45, -continent))
			shore += detail * 6 * smoothstep(0.05, 0.2, -continent)
		else
			local t = math.min(continent / beachC, 1)
			shore = beachHeight * (1 - (1 - t) * (1 - t))
		end
		local inlandStart = beachC * 0.7
		local cliffRise = cliffHeight * cliff * smoothstep(beachC * 0.8, beachC * 2.2, continent)

		-- 3. Land: plains where the relief noise is low, eroded hills where it is high.
		local land = landHeight * smoothstep(0, 0.4, continent)
		local relief = smoothstep(-0.35, 0.45, fbm(reliefNoise, x * invRelief, z * invRelief, 2))
		if relief > 0 and hillHeight > 0 then
			local hills = erodedFbm(hillNoise, x * invHill, z * invHill, 4, erosion) * 0.5 + 0.5
			land += hillHeight * relief * hills
		end

		-- 4. Mountain ranges follow the line where warped noise crosses zero. |f|
		-- over the noise's typical slope approximates the distance to that line in
		-- studs, so `rangeWidth` sets how far the foothills spread.
		local mountain = 0
		if mountainBase > 0 or mountainHeight > 0 then
			local rx, rz = x * invRange, z * invRange
			local presence = smoothstep(-0.15, 0.25, fbm(presenceNoise, rx * 0.5, rz * 0.5, 2))
			if presence > 0 then
				local wx = rx + fbm(rangeWarpNoise, rx * 0.5, rz * 0.5, 2) * RANGE_WARP
				local wz = rz + fbm(rangeWarpNoise, rx * 0.5 + 17.3, rz * 0.5 - 9.1, 2) * RANGE_WARP
				local distance = math.abs(fbm(rangeNoise, wx, wz, 2)) * rangeDistance

				local foothills = 1 - smoothstep(0, rangeWidth, distance)
				foothills *= foothills
				local spine = 1 - smoothstep(0, rangeWidth * SPINE_WIDTH, distance)
				mountain = mountainBase * foothills
				if spine > 0 then
					local ridge = erodedRidged(mountainNoise, x * invMountain, z * invMountain, 5, erosion)
					mountain += mountainHeight * spine * ridge * ridge
				end
				mountain *= presence
			end
		end

		-- Fine detail grows rougher with height: low ground stays smooth, peaks get craggy.
		local raised = land + mountain
		raised += detail * detailStrength * (2 + 8 * smoothstep(40, 300, raised))
		-- Dry land is kept above the bank height so no stray lakes form behind the beach.
		raised = smoothMax(raised, BANK_HEIGHT, 4)
		-- Land ramps in behind the beach. Higher ground takes a longer stretch, so
		-- hills and ranges meet the sea as slopes instead of walls.
		local inland = smoothstep(inlandStart, inlandStart + INLAND_RAMP + raised * INLAND_RAMP_PER_STUD, continent)
		local elevation = shore + inland * raised + cliffRise

		-- 5. Biomes: climate bands and the terrain band pick up to eight table
		-- entries, weighted by how close the column is to each band edge.
		local bx, bz = x * invBiome, z * invBiome
		local temperature = fbm(temperatureNoise, bx, bz, 2) * 1.8 + temperatureBias
		local humidity = fbm(moistureNoise, bx, bz, 3) * 1.8 + moistureBias
		local e = elevation + detail * ELEVATION_JITTER

		t0, t1, tw = findBand(temperatureEdges, temperature, climateBlend)
		h0, h1, hw = findBand(humidityEdges, humidity, climateBlend)
		local e0, e1, ew = findBand(terrainEdges, e, TERRAIN_BLEND)
		touchedCount = 0
		addBand(e0, 1 - ew)
		addBand(e1, ew)

		local dominant, best = 1, 0
		local bLowland, shape, shapeTotal = 0, 0, 0
		for k = 1, touchedCount do
			local i = touched[k]
			local w = weights[i]
			weights[i] = 0
			if w > best then
				best = w
				dominant = i
			end
			bLowland += list[i].lowland * w
			local sw = w - SHAPE_CUTOFF
			if sw > 0 then
				shapeTotal += sw
				shape += sw * shapeOf[i](x, z)
			end
		end
		shape /= shapeTotal

		-- Biome forms sit on top of the land, which stays above the bank height.
		-- Wetlands then pull toward it, which is only a few studs away since they
		-- only occur low down, and their pools dip below it.
		raised = smoothMax(raised + shape, BANK_HEIGHT, 4)
		raised += (BANK_HEIGHT + shape - raised) * bLowland
		local height = seaLevel + shore + inland * raised + cliffRise

		-- 6. Rivers. A wide valley first lowers the land toward the banks, then a
		-- narrow channel is cut below sea level, so banks slope instead of cliffing.
		local river, riverShore = 0, 0
		if riverWidth > 0 and continent > -0.03 then
			local band = riverBand
			local valley = 1 - smoothstep(riverWidth * 0.6, riverWidth * 5, band)
			if valley > 0 then
				local fade = 1 - smoothstep(riverMaxElevation * 0.5, riverMaxElevation, height - seaLevel)
				local strength = fade * smoothstep(-0.03, beachWidth * 2, continent)
				local bank = seaLevel + BANK_HEIGHT
				if height > bank then
					height += (bank - height) * valley * strength
				end

				local channel = 1 - smoothstep(riverWidth * 0.3, riverWidth * 1.3, band)
				river = channel * strength
				local bed = seaLevel - riverDepth
				if height > bed then
					height += (bed - height) * river
				end

				riverShore = (1 - smoothstep(riverWidth * 1.8, riverWidth * 2.8, band)) * strength
			end
		end

		local coastShore = 1 - smoothstep(beachC * 1.2, beachC * 2.5, continent)

		column.height = math.clamp(height, MIN_HEIGHT, MAX_HEIGHT)
		column.biome = dominant
		column.continent = continent
		column.river = river
		column.shore = math.max(coastShore, riverShore)
		column.patch = fbm(patchNoise, x / 80, z / 80, 3) + detail * 0.2
		column.snowLine = seaLevel + math.max(snowLine + temperature * SNOW_PER_TEMPERATURE, snowFloor) + detail * 24
		return column
	end

	local scratch = Sampler.newColumn()
	local function height(x: number, z: number): number
		return sample(x, z, scratch).height
	end

	return {
		config = config,
		sample = sample,
		height = height,
	}
end

--[[
	Finds a dry, fairly flat column near the origin by walking outward rings.
	Returns x, z and the surface height there. Falls back to the origin.
]]
function Sampler.findSpawn(sampler: Sampler, maxRadius: number?): (number, number, number)
	local seaLevel = sampler.config.seaLevel
	local h = sampler.height
	local limit = maxRadius or 4096

	local function suitable(x: number, z: number): (boolean, number)
		local y = h(x, z)
		if y < seaLevel + 3 then
			return false, y
		end
		local dx = math.abs(h(x + 4, z) - h(x - 4, z))
		local dz = math.abs(h(x, z + 4) - h(x, z - 4))
		return dx < 3 and dz < 3, y
	end

	local ok, y = suitable(0, 0)
	if ok then
		return 0, 0, y
	end

	for radius = 32, limit, 32 do
		local steps = math.max(8, math.floor(2 * math.pi * radius / 32))
		for i = 0, steps - 1 do
			local angle = i / steps * 2 * math.pi
			local x = math.round(math.cos(angle) * radius)
			local z = math.round(math.sin(angle) * radius)
			local found, height = suitable(x, z)
			if found then
				return x, z, height
			end
		end
	end

	return 0, 0, math.max(h(0, 0), seaLevel)
end

return Sampler
