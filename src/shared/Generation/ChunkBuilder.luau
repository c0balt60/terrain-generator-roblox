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
	voxel also hold water instead of leaving a seam. Water only fills space
	above the heightmap, so caves stay dry.

	Solidity comes from `sampler.occupancy`, which is the plain heightmap
	unless caves or overhangs are switched on. Material layers count down from
	the column's top surface, so cave walls show the dirt or stone they cut
	through and the ground under an overhang isn't grass.
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
local MIN_ROOF = Sampler.MIN_ROOF

-- Grid with a one-voxel border on every side, so slopes at the chunk edge use
-- real neighbour heights and adjacent chunks agree on their materials.
local B = N + 2

--[[
	Minecraft's speed trick: 3D noise is sampled on a coarse lattice and
	trilinearly interpolated in between, instead of at every voxel. Cells are
	CELL_XZ x CELL_Y x CELL_XZ voxels (8 x 16 x 8 studs, Minecraft's 1:2 aspect).
	The lattice is aligned to the world grid, so neighbouring chunks share their
	border points and agree there.
]]
local CELL_XZ = 2
local CELL_Y = 4
local LX = N // CELL_XZ + 1

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
	-- Heightmap surface of each column, at index (x - 1) * CHUNK_VOXELS + z.
	heights: { number },
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
	local prepare = sampler.prepare
	local noise3 = sampler.noise3
	local solidity = sampler.solidity
	local seaLevel = config.seaLevel
	local overhang = if config.overhangs == "On" then config.overhangStrength else 0

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
	top += overhang
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

	-- Pass 2: slopes, and the height range where any column does something 3D.
	local slopes = table.create(N * N, 0)
	local surfaceHeights = table.create(N * N, 0)
	local low3, high3 = math.huge, -math.huge
	for x = 1, N do
		for z = 1, N do
			local dhx = heights[(x + 1) * B + z + 1] - heights[(x - 1) * B + z + 1]
			local dhz = heights[x * B + z + 2] - heights[x * B + z]
			local slope = math.sqrt(dhx * dhx + dhz * dhz) / (2 * VOXEL)
			local column = columns[(x - 1) * N + z]
			slopes[(x - 1) * N + z] = slope
			surfaceHeights[(x - 1) * N + z] = column.height
			prepare(column, slope)
			if column.reach > 0 or column.caves > 0 then
				low3 = math.min(low3, column.low)
				high3 = math.max(high3, column.height + column.reach)
			end
		end
	end

	-- Pass 3: the noise lattice over that range. Chunks with nothing 3D skip it.
	local kLow, nk = 0, 0
	local warps, chambers, tunnelAs, tunnelBs = {}, {}, {}, {}
	if low3 <= high3 then
		kLow = (math.floor(math.max(low3, WORLD_BOTTOM) / VOXEL) // CELL_Y)
		nk = math.ceil(high3 / VOXEL) // CELL_Y + 2 - kLow
		local size = LX * LX * nk
		warps, chambers = table.create(size, 0), table.create(size, 0)
		tunnelAs, tunnelBs = table.create(size, 0), table.create(size, 0)
		for i = 0, LX - 1 do
			local wx = minX + i * CELL_XZ * VOXEL + VOXEL / 2
			for j = 0, LX - 1 do
				local wz = minZ + j * CELL_XZ * VOXEL + VOXEL / 2
				local base = (i * LX + j) * nk
				for k = 1, nk do
					local wy = (kLow + k - 1) * CELL_Y * VOXEL + VOXEL / 2
					warps[base + k], chambers[base + k], tunnelAs[base + k], tunnelBs[base + k] = noise3(wx, wy, wz)
				end
			end
		end
	end
	local di, dj = LX * nk, nk

	-- Trilinear interpolation of one lattice field from corner index `c`.
	local function lerp3(field: { number }, c: number, tx: number, ty: number, tz: number): number
		local a = field[c] + (field[c + 1] - field[c]) * ty
		local b = field[c + dj] + (field[c + dj + 1] - field[c + dj]) * ty
		local d = field[c + di] + (field[c + di + 1] - field[c + di]) * ty
		local e = field[c + di + dj] + (field[c + di + dj + 1] - field[c + di + dj]) * ty
		a += (b - a) * tz
		d += (e - d) * tz
		return a + (d - a) * tx
	end

	-- Pass 4: fill voxels column by column.
	local solids = table.create(ny, 0)
	for x = 1, N do
		local mx, ox, lx = materials[x], occupancy[x], liquid[x]
		local i0, tx = (x - 1) // CELL_XZ, ((x - 1) % CELL_XZ) / CELL_XZ
		for z = 1, N do
			local j0, tz = (z - 1) // CELL_XZ, ((z - 1) % CELL_XZ) / CELL_XZ
			local h = heights[x * B + z + 1]
			local column = columns[(x - 1) * N + z]
			local slope = slopes[(x - 1) * N + z]
			local surfaceName, subName, deepName = ChunkBuilder.columnMaterials(config, column, slope)
			local surface, sub, deep = pal[surfaceName], pal[subName], pal[deepName]

			-- Nothing is solid at or above `ceiling`; without overhangs it's the heightmap.
			-- Between `low` and `ceiling` the 3D terrain decides.
			local ceiling = h + column.reach
			local low = if column.reach > 0 or column.caves > 0 then column.low else math.huge
			local corner = (i0 * LX + j0) * nk + 1 - kLow
			local topY = h
			local last = 0
			for y = 1, ny do
				local yb = (yVoxBottom + y - 1) * VOXEL
				local ground = math.clamp((h - yb) / VOXEL, 0, 1)
				if ground <= 0 and yb >= ceiling and yb >= seaLevel then
					break -- Above the surface, any overhang and the water line: the rest is air.
				end
				local solid = ground
				if yb + VOXEL > low and yb < ceiling then
					local g = yVoxBottom + y - 1
					local c, ty = corner + g // CELL_Y, (g % CELL_Y) / CELL_Y
					solid = solidity(
						yb,
						column,
						lerp3(warps, c, tx, ty, tz),
						lerp3(chambers, c, tx, ty, tz),
						lerp3(tunnelAs, c, tx, ty, tz),
						lerp3(tunnelBs, c, tx, ty, tz)
					)
				end
				solids[y] = solid
				last = y
				if solid < 1 and ground < 1 and yb < seaLevel then
					lx[y][z] = math.clamp((seaLevel - yb) / VOXEL, 0, 1)
				end
			end

			-- Open roofs too thin to hold together over a cave. Roblox meshes them
			-- as torn strips and films joining the cave mouths. Repeats in case
			-- the layer under an opened roof is thin too.
			if column.caves > 0 then
				local y = last
				while true do
					while y > 1 and solids[y] <= 0 do
						y -= 1
					end
					local roofTop, sum = y, 0
					while y > 1 and solids[y] > 0 do
						sum += solids[y]
						y -= 1
					end
					-- `y` is the first empty voxel under the roof, if any.
					if sum >= MIN_ROOF or solids[y] > 0 or (yVoxBottom + y) * VOXEL > h then
						break
					end
					for k = y + 1, roofTop do
						solids[k] = 0
					end
				end
			end

			-- Material layers count down from the top of the solid ground, which an
			-- overhang can lift.
			if column.reach > 0 then
				for y = last, 1, -1 do
					if solids[y] > 0 then
						topY = (yVoxBottom + y - 1) * VOXEL + solids[y] * VOXEL
						break
					end
				end
			end

			for y = 1, last do
				local solid = solids[y]
				if solid > 0 then
					local depth = topY - ((yVoxBottom + y) * VOXEL)
					if depth < VOXEL then
						mx[y][z] = surface
					elseif depth < SUBSURFACE_DEPTH then
						mx[y][z] = sub
					else
						mx[y][z] = deep
					end
					ox[y][z] = solid
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
		heights = surfaceHeights,
		maxHeight = top,
	}
end

return ChunkBuilder
