--!strict
--!native
--!optimize 2
--[[
	Builds the voxel channels for one chunk column.

	Output is the exact shape `Terrain:WriteVoxelChannels` takes: three
	[x][y][z] arrays (SolidMaterial, SolidOccupancy, LiquidOccupancy). Material
	names go through `palette`, so on Roblox the arrays hold Enum.Material
	values and here in Lune they hold plain strings.

	Water is a separate liquid channel, which lets a partially solid shoreline
	voxel also hold water instead of leaving a seam.
]]

local Biomes = require("./Biomes")
local Config = require("./Config")
local Constants = require("./Constants")
local Sampler = require("./Sampler")

local VOXEL = Constants.VOXEL_SIZE
local N = Constants.CHUNK_VOXELS
local CHUNK_STUDS = Constants.CHUNK_STUDS
local WORLD_BOTTOM = Constants.WORLD_BOTTOM
local WORLD_TOP = Constants.WORLD_TOP
local SUBSURFACE_DEPTH = Constants.SUBSURFACE_DEPTH

-- Grid with a one-voxel border on every side, so slopes at the chunk edge use
-- real neighbour heights and adjacent chunks agree on their materials.
local B = N + 2

export type Palette = { [string]: any }

export type Chunk = {
	cx: number,
	cz: number,
	-- Region minimum corner and size in studs; Y spans WORLD_BOTTOM..top.
	minX: number,
	minY: number,
	minZ: number,
	sizeY: number,
	materials: { { { any } } },
	occupancy: { { { number } } },
	liquid: { { { number } } },
	maxHeight: number,
}

local identity: Palette = setmetatable({}, {
	__index = function(_, name: string)
		return name
	end,
}) :: any

local ChunkBuilder = {}

-- Underwater ground this close to the surface near a shore uses the beach material.
local SHALLOWS = 6
-- Patch noise thresholds for a biome's alternate surface materials.
local PATCH_HIGH = 0.3
local PATCH_LOW = -0.4

-- Returns surface, subsurface and deep material names for one column.
function ChunkBuilder.columnMaterials(
	config: Config.Config,
	column: Sampler.Column,
	slope: number
): (string, string, string)
	local biome = Biomes.list[column.biome]
	local seaLevel = config.seaLevel
	local steep = config.steepSlope
	local height = column.height
	local patch = column.patch
	local deep = biome.steep

	if height < seaLevel - 1 then
		if height > seaLevel - SHALLOWS and column.shore > 0.3 then
			return biome.beach, biome.beach, deep
		end
		return biome.seabed, biome.subsurface, deep
	elseif
		height < seaLevel + config.beachHeight + 1.5 + patch * 1.5
		and (column.shore > 0.5 or height < seaLevel + 1.5)
		and slope < steep * 2.5
	then
		-- Low ground at the water stays beach even on steepish banks; cliffs rise
		-- above it and turn to rock. The patch noise keeps the beach's inland
		-- edge from tracing a contour line.
		return biome.beach, biome.beach, deep
	elseif slope > steep then
		return biome.steep, biome.steep, deep
	elseif height > column.snowLine and slope < steep * 0.8 then
		return "Snow", biome.subsurface, deep
	elseif slope > steep * 0.8 then
		return biome.subsurface, biome.subsurface, deep
	elseif patch > PATCH_HIGH then
		return biome.patchHigh, biome.subsurface, deep
	elseif patch < PATCH_LOW then
		return biome.patchLow, biome.subsurface, deep
	end
	return biome.surface, biome.subsurface, deep
end

function ChunkBuilder.build(sampler: Sampler.Sampler, cx: number, cz: number, palette: Palette?): Chunk
	local pal = palette or identity
	local config = sampler.config
	local sample = sampler.sample
	local seaLevel = config.seaLevel

	local minX = cx * CHUNK_STUDS
	local minZ = cz * CHUNK_STUDS

	-- Pass 1: sample every column (plus border) at voxel centres. Border columns
	-- only need their height, so they share one scratch table.
	local heights = table.create(B * B, 0)
	local columns: { Sampler.Column } = table.create(N * N)
	local border = Sampler.newColumn()

	local top = seaLevel
	for i = 0, B - 1 do
		local wx = minX + (i - 1) * VOXEL + VOXEL / 2
		local interiorX = i >= 1 and i <= N
		for j = 0, B - 1 do
			local wz = minZ + (j - 1) * VOXEL + VOXEL / 2
			if interiorX and j >= 1 and j <= N then
				local column = sample(wx, wz, Sampler.newColumn())
				local h = column.height
				columns[(i - 1) * N + j] = column
				heights[i * B + j + 1] = h
				if h > top then
					top = h
				end
			else
				heights[i * B + j + 1] = sample(wx, wz, border).height
			end
		end
	end

	-- Region only reaches as high as this chunk needs; everything above is air already.
	local yVoxBottom = WORLD_BOTTOM // VOXEL
	local yVoxTop = math.min(math.ceil(top / VOXEL) + 1, WORLD_TOP // VOXEL)
	local ny = yVoxTop - yVoxBottom

	local air = pal.Air
	local materials = table.create(N)
	local occupancy = table.create(N)
	local liquid = table.create(N)
	for x = 1, N do
		local mx, ox, lx = table.create(ny), table.create(ny), table.create(ny)
		for y = 1, ny do
			mx[y] = table.create(N, air)
			ox[y] = table.create(N, 0)
			lx[y] = table.create(N, 0)
		end
		materials[x], occupancy[x], liquid[x] = mx, ox, lx
	end

	-- Pass 2: fill voxels column by column.
	for x = 1, N do
		local mx, ox, lx = materials[x], occupancy[x], liquid[x]
		for z = 1, N do
			local h = heights[x * B + z + 1]
			local dhx = heights[(x + 1) * B + z + 1] - heights[(x - 1) * B + z + 1]
			local dhz = heights[x * B + z + 2] - heights[x * B + z]
			local slope = math.sqrt(dhx * dhx + dhz * dhz) / (2 * VOXEL)

			local surfaceName, subName, deepName = ChunkBuilder.columnMaterials(config, columns[(x - 1) * N + z], slope)
			local surface, sub, deep = pal[surfaceName], pal[subName], pal[deepName]

			for y = 1, ny do
				local yb = (yVoxBottom + y - 1) * VOXEL
				local solid = math.clamp((h - yb) / VOXEL, 0, 1)
				if solid > 0 then
					local depth = h - (yb + VOXEL)
					if depth < VOXEL then
						mx[y][z] = surface
					elseif depth < SUBSURFACE_DEPTH then
						mx[y][z] = sub
					else
						mx[y][z] = deep
					end
					ox[y][z] = solid
				end
				if solid < 1 and yb < seaLevel then
					lx[y][z] = math.clamp((seaLevel - yb) / VOXEL, 0, 1)
				elseif solid <= 0 then
					break -- Above both the surface and the water line: the rest is air.
				end
			end
		end
	end

	return {
		cx = cx,
		cz = cz,
		minX = minX,
		minY = yVoxBottom * VOXEL,
		minZ = minZ,
		sizeY = ny * VOXEL,
		materials = materials,
		occupancy = occupancy,
		liquid = liquid,
		maxHeight = top,
	}
end

return ChunkBuilder
