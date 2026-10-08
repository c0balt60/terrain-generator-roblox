--!strict
--!native
--!optimize 2
--[[
	Column sampler: turns a world (x, z) into everything the chunk builder needs
	to know about that column. The layers, in order:

	1. Continentalness: very low-frequency noise splitting ocean from land.
	2. Climate: temperature and moisture pick blended biome weights.
	3. Land detail: per-biome rolling hills plus masked ridged mountains.
	4. Rivers: thin bands where low-frequency noise crosses zero are carved
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

-- Salts keep each layer's permutation independent for the same world seed.
local SALT_CONTINENT = 1
local SALT_DETAIL = 2
local SALT_MOUNTAIN = 3
local SALT_MOUNTAIN_MASK = 4
local SALT_TEMPERATURE = 5
local SALT_MOISTURE = 6
local SALT_RIVER = 7

local MIN_HEIGHT = Constants.WORLD_BOTTOM + 8
local MAX_HEIGHT = Constants.WORLD_TOP - 8

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	Returns, for a world column:
	  height     surface Y in studs
	  biome      index into Biomes of the dominant biome
	  continent  continentalness, < 0 is ocean
	  river      0..1 river carving strength
	  snowLine   Y above which flat ground turns to snow
]]
export type SampleFn = (x: number, z: number) -> (number, number, number, number, number)

export type Sampler = {
	config: Config.Config,
	sample: SampleFn,
	height: (x: number, z: number) -> number,
}

local Sampler = {}

function Sampler.new(config: Config.Config): Sampler
	local seed = config.seed

	local continentNoise = Noise.simplex2(seed, SALT_CONTINENT)
	local detailNoise = Noise.simplex2(seed, SALT_DETAIL)
	local mountainNoise = Noise.simplex2(seed, SALT_MOUNTAIN)
	local maskNoise = Noise.simplex2(seed, SALT_MOUNTAIN_MASK)
	local temperatureNoise = Noise.simplex2(seed, SALT_TEMPERATURE)
	local moistureNoise = Noise.simplex2(seed, SALT_MOISTURE)
	local riverNoise = Noise.simplex2(seed, SALT_RIVER)

	local invContinent = 1 / config.continentScale
	local invDetail = 1 / config.detailScale
	local invMountain = 1 / config.mountainScale
	local invBiome = 1 / config.biomeScale
	local invRiver = 1 / config.riverScale

	local seaLevel = config.seaLevel
	local coastBias = config.coastBias
	local oceanDepth = config.oceanDepth
	local landHeight = config.landHeight
	local detailStrength = config.detailStrength
	local mountainHeight = config.mountainHeight
	local invBlend2 = 1 / (config.biomeBlend * config.biomeBlend)
	local temperatureBias = config.temperatureBias
	local moistureBias = config.moistureBias
	local riverWidth = config.riverWidth
	local riverDepth = config.riverDepth
	local riverMaxElevation = config.riverMaxElevation
	local snowLine = config.snowLine

	local biomeCount = #Biomes
	local distances = table.create(biomeCount, 0)

	local function sample(x: number, z: number): (number, number, number, number, number)
		-- 1. Continent
		local continent = fbm(continentNoise, x * invContinent, z * invContinent, 5) * 1.6 + coastBias
		local base
		if continent < 0 then
			base = -oceanDepth * smoothstep(0, 0.45, -continent)
		else
			base = landHeight * smoothstep(0, 0.4, continent)
		end
		local landFactor = smoothstep(-0.04, 0.2, continent)

		-- 2. Climate -> biome weights. Distances are shifted by the minimum so the
		-- nearest biome always has weight 1 and far corners can't underflow to 0/0.
		local bx, bz = x * invBiome, z * invBiome
		local temperature = math.clamp(fbm(temperatureNoise, bx, bz, 3) * 1.8 + temperatureBias, -1, 1)
		local moisture = math.clamp(fbm(moistureNoise, bx, bz, 3) * 1.8 + moistureBias, -1, 1)

		local nearest = math.huge
		local dominant = 1
		for i = 1, biomeCount do
			local biome = Biomes[i]
			local dt = temperature - biome.temperature
			local dm = moisture - biome.moisture
			local d2 = dt * dt + dm * dm
			distances[i] = d2
			if d2 < nearest then
				nearest = d2
				dominant = i
			end
		end

		local total, bHeight, bRough, bMountain, bSnow = 0, 0, 0, 0, 0
		for i = 1, biomeCount do
			local w = math.exp(-(distances[i] - nearest) * invBlend2)
			local biome = Biomes[i]
			total += w
			bHeight += biome.height * w
			bRough += biome.roughness * w
			bMountain += biome.mountains * w
			bSnow += biome.snowLineOffset * w
		end
		bHeight /= total
		bRough /= total
		bMountain /= total
		bSnow /= total

		-- 3. Land detail and mountains
		local detail = fbm(detailNoise, x * invDetail, z * invDetail, 4)
		local mask =
			smoothstep(0.42, 0.68, fbm(maskNoise, x * invMountain * 0.35, z * invMountain * 0.35, 3) * 0.5 + 0.5)
		local mountain = 0
		if mask > 0 and bMountain > 0 then
			local ridge = ridged(mountainNoise, x * invMountain, z * invMountain, 5)
			mountain = mountainHeight * mask * bMountain * ridge * ridge
		end

		local height = seaLevel
			+ base
			+ landFactor * (bHeight + detail * bRough * detailStrength + mountain)
			+ (1 - landFactor) * detail * 6

		-- 4. Rivers. A wide valley first lowers the land toward the banks, then a
		-- narrow channel is cut below sea level, so banks slope instead of cliffing.
		local river = 0
		if riverWidth > 0 and landFactor > 0 then
			local band = math.abs(fbm(riverNoise, x * invRiver, z * invRiver, 3))
			local valley = 1 - smoothstep(0, riverWidth * 4, band)
			if valley > 0 then
				local fade = 1 - smoothstep(riverMaxElevation * 0.5, riverMaxElevation, height - seaLevel)
				local strength = fade * landFactor
				local bank = seaLevel + 2
				if height > bank then
					height += (bank - height) * valley * strength
				end

				local channel = 1 - smoothstep(riverWidth * 0.35, riverWidth, band)
				river = channel * strength
				local bed = seaLevel - riverDepth
				if height > bed then
					height += (bed - height) * river
				end
			end
		end

		height = math.clamp(height, MIN_HEIGHT, MAX_HEIGHT)
		return height, dominant, continent, river, snowLine + bSnow + detail * 24
	end

	local function height(x: number, z: number): number
		return (sample(x, z))
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
