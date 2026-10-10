--!strict
--[[
	Asset placement: trees and surface ore nodes for one chunk.

	Like the rest of Generation this only returns names and transforms; the
	worker clones the matching templates. Candidates sit on a global jittered
	grid, and every grid cell seeds its own stream from a hash of its
	coordinates, so a chunk places the same assets whatever order chunks load in.

	Trees: each biome sets a density (a fraction of `treeDensity`) and its
	species. A grove noise redistributes them, so dense biomes get clearings and
	sparse ones get groves instead of an even scatter.

	Ores: rarer in the lowland, more common in the mountains, with richer ores
	higher up. Badlands carry extra gold. Ores are placed first and block the
	tree cell they land in.

	Cave ores (`placeInCaves`) stud cave floors, walls and ceilings, tilted to
	the surface. They're found in a built chunk's voxels rather than the noise,
	so they sit on the terrain that was actually written. Richer ores lie
	deeper, with the same mountain and Badlands bonus as on the surface.
]]

local Biomes = require("./Biomes")
local ChunkBuilder = require("./ChunkBuilder")
local Config = require("./Config")
local Constants = require("./Constants")
local Noise = require("./Noise")
local Prng = require("./Prng")
local Sampler = require("./Sampler")

local VOXEL = Constants.VOXEL_SIZE
local CHUNK_STUDS = Constants.CHUNK_STUDS

local SALT_TREE = 101
local SALT_ORE = 102
local SALT_GROVE = 103
local SALT_CAVE_ORE = 104

-- Grid cell sizes in studs; both divide CHUNK_STUDS, so every cell belongs to one chunk.
local TREE_CELL = 16
local ORE_CELL = 32
-- Candidates stay this far inside their cell, so neighbours never touch.
local CELL_MARGIN = 3
local GROVE_SCALE = 260
-- Tree chance is base ^ exponent, the exponent going from CLEARING (grove
-- noise low) to GROVE (high). Dense bases saturate into forest with clearings;
-- sparse ones only show up where the noise is high, as groves.
local CLEARING_EXPONENT = 3
local GROVE_EXPONENT = 0.25
-- River channel strength above which nothing is placed.
local RIVER_LIMIT = 0.05
-- Lowland ores are this fraction of the mountain rate.
local LOWLAND_ORES = 0.25
-- Each cave surface voxel gets an ore at odds caveOreDensity / this. Measured so
-- a chunk with a typical amount of cave ends up with about caveOreDensity ores
-- after spacing (see assets.spec).
local CAVE_SURFACE_PER_CHUNK = 150
-- Cave ores need at least this much rock above them, so cave mouths stay bare.
local CAVE_ORE_DEPTH = 8
-- Minimum distance between cave ores in one chunk.
local CAVE_ORE_SPACING = 12

local ORES = { "Coal", "Iron", "Gold", "Diamond" }
local BADLANDS = Biomes.index("Badlands")

export type Placement = {
	kind: "Tree" | "Ore",
	name: string, -- Template name.
	x: number,
	y: number, -- Surface height at (x, z), or the cave surface.
	z: number,
	-- Unit vector the model's up axis points along: straight up, except in caves.
	nx: number,
	ny: number,
	nz: number,
	yaw: number, -- Radians, around that up axis.
	scale: number,
}

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- 32-bit multiply that stays exact in doubles: split `a` into 16-bit halves.
local function mul32(a: number, b: number): number
	local lo = bit32.band(a, 0xFFFF)
	local hi = bit32.rshift(a, 16)
	return bit32.band(lo * b + bit32.lshift(bit32.band(hi * b, 0xFFFF), 16), 0xFFFFFFFF)
end

-- lowbias32 integer hash. Prng.hash is linear in its salt, so neighbouring
-- cells would get correlated streams; this mixes the coordinates first.
local function mix(x: number): number
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x7feb352d)
	x = bit32.bxor(x, bit32.rshift(x, 15))
	x = mul32(x, 0x846ca68b)
	return bit32.bxor(x, bit32.rshift(x, 16))
end

-- Every template name the generator can ask for.
local NAMES: { string } = table.clone(ORES)
for _, biome in Biomes.list do
	for _, name in biome.trees do
		if not table.find(NAMES, name) then
			table.insert(NAMES, name)
		end
	end
end

-- Rolls one of ORES with the given weights.
local function rollOre(rng: Prng.Prng, weights: { number }): string
	local total = 0
	for _, w in weights do
		total += w
	end
	local roll = rng:nextNumber() * total
	for i, w in weights do
		roll -= w
		if roll < 0 then
			return ORES[i]
		end
	end
	return ORES[1]
end

local function pickOre(rng: Prng.Prng, elevation: number, config: Config.Config, badlands: boolean): string
	local slopes = config.slopeElevation
	return rollOre(rng, {
		10,
		if elevation >= slopes * 0.4 then 6 else 0,
		(if elevation >= slopes then 3 else 0) + (if badlands then 6 else 0),
		if elevation >= config.peakElevation then 1 else 0,
	})
end

-- Cave ores by depth below the surface: coal thins out going down while iron,
-- gold and diamond come in. The land above adds the surface tiers on top.
local function pickCaveOre(
	rng: Prng.Prng,
	depth: number,
	elevation: number,
	config: Config.Config,
	badlands: boolean
): string
	local band = config.caveDepth
	local slopes = config.slopeElevation
	return rollOre(rng, {
		10 * (1 - 0.6 * math.min(depth / band, 1)),
		if depth >= band * 0.15 or elevation >= slopes * 0.4 then 6 else 0,
		(if depth >= band * 0.5 or elevation >= slopes then 3 else 0) + (if badlands then 6 else 0),
		(if depth >= band * 0.8 then 1.5 else 0) + (if elevation >= config.peakElevation then 1 else 0),
	})
end

local Assets = {}

Assets.NAMES = table.freeze(NAMES)

function Assets.place(sampler: Sampler.Sampler, cx: number, cz: number): { Placement }
	local config = sampler.config
	local seed = config.seed
	local seaLevel = config.seaLevel
	local dry = seaLevel + config.beachHeight + 1
	local steep = config.steepSlope
	local slopes = config.slopeElevation
	local sample = sampler.sample
	local height = sampler.height
	local prepare = sampler.prepare
	local surfaceAt = sampler.surface
	local column = Sampler.newColumn()
	local groveNoise = Noise.simplex2(seed, SALT_GROVE)
	local out: { Placement } = {}

	local function slopeAt(x: number, z: number): number
		local dx = height(x + VOXEL, z) - height(x - VOXEL, z)
		local dz = height(x, z + VOXEL) - height(x, z - VOXEL)
		return math.sqrt(dx * dx + dz * dz) / (2 * VOXEL)
	end

	-- The cell's random stream and a jittered point inside it.
	local function candidate(salt: number, size: number, gx: number, gz: number): (Prng.Prng, number, number)
		local rng = Prng.new(mix(seed + mix(gx + mix(gz + salt))))
		local span = size - 2 * CELL_MARGIN
		return rng, gx * size + CELL_MARGIN + rng:nextNumber() * span, gz * size + CELL_MARGIN + rng:nextNumber() * span
	end

	-- Where an asset at (x, z) should stand: the top of the ground, which an
	-- overhang can lift. Nil over a cave mouth, where it would float.
	local function standAt(x: number, z: number, slope: number): number?
		prepare(column, slope)
		local y = surfaceAt(x, z, column)
		return if y < column.height - VOXEL then nil else y
	end

	local blocked: { [string]: boolean } = {}

	local oreCells = CHUNK_STUDS // ORE_CELL
	local orePeak = config.oreDensity / (oreCells * oreCells)
	for i = 0, oreCells - 1 do
		for j = 0, oreCells - 1 do
			local rng, x, z = candidate(SALT_ORE, ORE_CELL, cx * oreCells + i, cz * oreCells + j)
			local chance = rng:nextNumber()
			if chance >= orePeak then
				continue -- Can't pass at any elevation; skip the sample.
			end
			sample(x, z, column)
			local h = column.height
			local elevation = h - seaLevel
			local p = orePeak * (LOWLAND_ORES + (1 - LOWLAND_ORES) * smoothstep(slopes * 0.5, slopes, elevation))
			if chance >= p or h < dry or column.river >= RIVER_LIMIT then
				continue
			end
			local slope = slopeAt(x, z)
			local y = if slope <= steep * 1.5 then standAt(x, z, slope) else nil
			if y then
				table.insert(out, {
					kind = "Ore",
					name = pickOre(rng, elevation, config, column.biome == BADLANDS),
					x = x,
					y = y,
					z = z,
					nx = 0,
					ny = 1,
					nz = 0,
					yaw = rng:nextNumber() * 2 * math.pi,
					scale = 0.8 + rng:nextNumber() * 0.4,
				})
				blocked[`{x // TREE_CELL},{z // TREE_CELL}`] = true
			end
		end
	end

	local treeCells = CHUNK_STUDS // TREE_CELL
	local treeBase = config.treeDensity / (treeCells * treeCells)
	for i = 0, treeCells - 1 do
		for j = 0, treeCells - 1 do
			local gx, gz = cx * treeCells + i, cz * treeCells + j
			if blocked[`{gx},{gz}`] then
				continue
			end
			local rng, x, z = candidate(SALT_TREE, TREE_CELL, gx, gz)
			local chance = rng:nextNumber()
			sample(x, z, column)
			local biome = Biomes.list[column.biome]
			local base = math.min(treeBase * biome.treeDensity, 1)
			if base <= 0 then
				continue
			end
			local grove = smoothstep(-0.5, 0.5, Noise.fbm(groveNoise, x / GROVE_SCALE, z / GROVE_SCALE, 2))
			local p = base ^ (CLEARING_EXPONENT + (GROVE_EXPONENT - CLEARING_EXPONENT) * grove)
			local h = column.height
			if chance >= p or h < dry or h >= column.snowLine or column.river >= RIVER_LIMIT or column.shore >= 0.5 then
				continue
			end
			local slope = slopeAt(x, z)
			local y = if slope <= steep * 0.8 then standAt(x, z, slope) else nil
			if y then
				table.insert(out, {
					kind = "Tree",
					name = biome.trees[rng:nextInt(#biome.trees) + 1],
					x = x,
					y = y,
					z = z,
					nx = 0,
					ny = 1,
					nz = 0,
					yaw = rng:nextNumber() * 2 * math.pi,
					scale = 0.8 + rng:nextNumber() * 0.5,
				})
			end
		end
	end

	return out
end

--[[
	Ore nodes on the cave surfaces of a built chunk. Every empty, buried voxel
	touching rock is a candidate, with odds from a hash of its world voxel
	coordinates, so the result doesn't depend on load order. The node's up axis
	follows the occupancy gradient out of the rock, and its base is moved from
	the voxel centre to where the terrain surface roughly is.

	Voxels on the chunk's side faces are skipped, since half their neighbours
	live in the next chunk.
]]
function Assets.placeInCaves(sampler: Sampler.Sampler, chunk: ChunkBuilder.Chunk): { Placement }
	local config = sampler.config
	local out: { Placement } = {}
	if config.caves ~= "On" or config.caveOreDensity <= 0 then
		return out
	end

	local seed = config.seed
	local seaLevel = config.seaLevel
	-- Odds per candidate voxel as a 32-bit hash threshold.
	local threshold = config.caveOreDensity / CAVE_SURFACE_PER_CHUNK * 2 ^ 32
	local occupancy, liquid, heights = chunk.occupancy, chunk.liquid, chunk.heights
	local ny = chunk.sizeY // VOXEL
	local N = Constants.CHUNK_VOXELS
	local gx0, gy0, gz0 = chunk.minX // VOXEL - 1, chunk.minY // VOXEL - 1, chunk.minZ // VOXEL - 1
	local column = Sampler.newColumn()

	for x = 2, N - 1 do
		local o, ol, oh = occupancy[x], occupancy[x - 1], occupancy[x + 1]
		for z = 2, N - 1 do
			local h = heights[(x - 1) * N + z]
			local wx = chunk.minX + (x - 0.5) * VOXEL
			local wz = chunk.minZ + (z - 0.5) * VOXEL
			for y = 2, ny - 1 do
				local wy = chunk.minY + (y - 0.5) * VOXEL
				if wy > h - CAVE_ORE_DEPTH then
					break
				end
				local row = o[y]
				if row[z] ~= 0 or liquid[x][y][z] ~= 0 then
					continue
				end
				-- Gradient of occupancy; it points into the rock.
				local dx = oh[y][z] - ol[y][z]
				local dy = o[y + 1][z] - o[y - 1][z]
				local dz = row[z + 1] - row[z - 1]
				local g = math.sqrt(dx * dx + dy * dy + dz * dz)
				if g < 0.5 then
					continue -- No rock next to this voxel (or rock all round).
				end
				if mix(seed + mix(gx0 + x + mix(gy0 + y + mix(gz0 + z + SALT_CAVE_ORE)))) >= threshold then
					continue
				end

				-- Occupancy climbs by about g over two voxels, so the 0.5 surface
				-- is about VOXEL / g from this (empty) voxel's centre.
				local nx, nyy, nz = -dx / g, -dy / g, -dz / g
				local t = math.clamp(VOXEL / g, VOXEL * 0.5, VOXEL * 1.5)
				local px, py, pz = wx - nx * t, wy - nyy * t, wz - nz * t

				local crowded = false
				for _, other in out do
					local ex, ey, ez = other.x - px, other.y - py, other.z - pz
					if ex * ex + ey * ey + ez * ez < CAVE_ORE_SPACING * CAVE_ORE_SPACING then
						crowded = true
						break
					end
				end
				if crowded then
					continue
				end

				local rng = Prng.new(mix(seed + mix(gx0 + x + mix(gy0 + y + mix(gz0 + z + SALT_CAVE_ORE + 1)))))
				sampler.sample(wx, wz, column)
				table.insert(out, {
					kind = "Ore",
					name = pickCaveOre(rng, h - py, h - seaLevel, config, column.biome == BADLANDS),
					x = px,
					y = py,
					z = pz,
					nx = nx,
					ny = nyy,
					nz = nz,
					yaw = rng:nextNumber() * 2 * math.pi,
					scale = 0.8 + rng:nextNumber() * 0.4,
				})
			end
		end
	end
	return out
end

return Assets
