--!strict
--[[
	Biome table, laid out the way Minecraft's multi-noise biomes are.

	Biomes never set the terrain's height: the sampler builds the land first,
	then looks the biome up from three things:

	- Temperature band (frozen, cold, temperate, warm, hot) and humidity band
	  (arid, dry, normal, humid, wet), from two large-scale climate noises. The
	  bands are wide, so a climate zone covers a region and hot zones never touch
	  frozen ones: the noise has to pass through the bands in between.
	- Terrain band, from the elevation: wet low ground (swamps), lowland, mountain
	  slopes and peaks. Lowland biomes ride up the lower flanks of a range, so
	  mountains lift them rather than replace them.

	Each terrain band has its own [temperature][humidity] table. Near a band edge
	the neighbouring bands blend, which only affects the small surface forms
	(dunes, mesas, ...); materials come from the dominant biome.

	Snow is not a biome property except for the dedicated snow biomes. Everywhere
	else it falls above a snow line that drops in colder climates and never
	reaches the lowland.

	Materials are Enum.Material names, not enums, so this stays loadable in
	Lune. The worker resolves them through a palette.
]]

-- Names of the per-biome surface forms implemented in Sampler.
export type Shape = "meadow" | "ridges" | "knolls" | "forest" | "hummocks" | "mesas" | "dunes" | "crags"

export type Biome = {
	name: string,

	-- Surface parameters, blended by weight.
	shape: Shape, -- Biome-specific surface form.
	lowland: number, -- 0..1 pull toward the bank height (wetlands). Only meaningful low down.

	-- Materials, taken from the dominant biome only.
	surface: string,
	patchHigh: string, -- Replaces surface where the patch noise is high.
	patchLow: string, -- Replaces surface where the patch noise is low.
	subsurface: string,
	steep: string, -- Cliffs and steep slopes.
	beach: string,
	seabed: string,

	-- Assets, also from the dominant biome.
	treeDensity: number, -- 0..1 fraction of Config.treeDensity.
	trees: { string }, -- Tree species (template names), picked uniformly.
}

-- Lookup tables, one per terrain band: rows are temperature bands (coldest
-- first), columns humidity bands (driest first). Entries are indices into `list`.
export type Table = { { number } }

-- stylua: ignore
local LIST: { Biome } = {
	{
		-- The dedicated snow biome: the only lowland that is white.
		name = "Snowy Plains", shape = "knolls", lowland = 0,
		surface = "Snow", patchHigh = "Glacier", patchLow = "Snow",
		subsurface = "Ground", steep = "Slate", beach = "Pebble", seabed = "Pebble",
		treeDensity = 0.008, trees = { "SnowySpruce" },
	},
	{
		name = "Snowy Taiga", shape = "forest", lowland = 0,
		surface = "Snow", patchHigh = "Snow", patchLow = "Ground",
		subsurface = "Ground", steep = "Slate", beach = "Pebble", seabed = "Ground",
		treeDensity = 1, trees = { "SnowySpruce" },
	},
	{
		name = "Taiga", shape = "forest", lowland = 0,
		surface = "Grass", patchHigh = "LeafyGrass", patchLow = "Ground",
		subsurface = "Ground", steep = "Slate", beach = "Pebble", seabed = "Ground",
		treeDensity = 1, trees = { "Spruce" },
	},
	{
		name = "Grasslands", shape = "meadow", lowland = 0,
		surface = "Grass", patchHigh = "LeafyGrass", patchLow = "Grass",
		subsurface = "Ground", steep = "Rock", beach = "Sand", seabed = "Sand",
		treeDensity = 0.02, trees = { "Oak", "Birch" },
	},
	{
		name = "Forest", shape = "forest", lowland = 0,
		surface = "LeafyGrass", patchHigh = "Grass", patchLow = "Mud",
		subsurface = "Ground", steep = "Rock", beach = "Sand", seabed = "Sand",
		treeDensity = 1, trees = { "Oak", "Birch" },
	},
	{
		name = "Swamp", shape = "hummocks", lowland = 0.9,
		surface = "Mud", patchHigh = "LeafyGrass", patchLow = "Ground",
		subsurface = "Mud", steep = "Ground", beach = "Mud", seabed = "Mud",
		treeDensity = 0.5, trees = { "SwampOak" },
	},
	{
		name = "Savanna", shape = "mesas", lowland = 0,
		surface = "Ground", patchHigh = "Grass", patchLow = "Sand",
		subsurface = "Sandstone", steep = "Sandstone", beach = "Sand", seabed = "Sand",
		treeDensity = 0.14, trees = { "Acacia" },
	},
	{
		name = "Desert", shape = "dunes", lowland = 0,
		surface = "Sand", patchHigh = "Sandstone", patchLow = "Salt",
		subsurface = "Sandstone", steep = "Sandstone", beach = "Sand", seabed = "Sand",
		treeDensity = 0, trees = {},
	},
	{
		-- Grassy upper flanks of a range, with bare rock showing through.
		name = "Meadow", shape = "ridges", lowland = 0,
		surface = "Grass", patchHigh = "LeafyGrass", patchLow = "Rock",
		subsurface = "Ground", steep = "Rock", beach = "Pebble", seabed = "Pebble",
		treeDensity = 0.07, trees = { "Spruce" },
	},
	{
		name = "Snowy Slopes", shape = "ridges", lowland = 0,
		surface = "Snow", patchHigh = "Glacier", patchLow = "Rock",
		subsurface = "Rock", steep = "Rock", beach = "Pebble", seabed = "Pebble",
		treeDensity = 0.05, trees = { "SnowySpruce" },
	},
	{
		-- Hot, dry mountains: slopes and peaks alike.
		name = "Badlands", shape = "mesas", lowland = 0,
		surface = "Sandstone", patchHigh = "Limestone", patchLow = "Ground",
		subsurface = "Sandstone", steep = "Rock", beach = "Sand", seabed = "Sand",
		treeDensity = 0, trees = {},
	},
	{
		name = "Peaks", shape = "crags", lowland = 0,
		surface = "Rock", patchHigh = "Slate", patchLow = "Pebble",
		subsurface = "Rock", steep = "Slate", beach = "Pebble", seabed = "Pebble",
		treeDensity = 0, trees = {},
	},
}

-- stylua: ignore
local LAYOUT: { [string]: { { string } } } = {
	wetland = {
		{ "Snowy Plains", "Snowy Plains", "Snowy Plains", "Snowy Taiga", "Snowy Taiga" },
		{ "Grasslands",   "Grasslands",   "Grasslands",   "Taiga",       "Taiga" },
		{ "Grasslands",   "Grasslands",   "Grasslands",   "Swamp",       "Swamp" },
		{ "Savanna",      "Savanna",      "Grasslands",   "Swamp",       "Swamp" },
		{ "Desert",       "Desert",       "Desert",       "Savanna",     "Savanna" },
	},
	lowland = {
		{ "Snowy Plains", "Snowy Plains", "Snowy Plains", "Snowy Taiga", "Snowy Taiga" },
		{ "Grasslands",   "Grasslands",   "Grasslands",   "Taiga",       "Taiga" },
		{ "Grasslands",   "Grasslands",   "Grasslands",   "Forest",      "Forest" },
		{ "Savanna",      "Savanna",      "Grasslands",   "Forest",      "Forest" },
		{ "Desert",       "Desert",       "Desert",       "Savanna",     "Savanna" },
	},
	slopes = {
		{ "Snowy Slopes", "Snowy Slopes", "Snowy Slopes", "Snowy Slopes", "Snowy Slopes" },
		{ "Meadow",       "Meadow",       "Meadow",       "Meadow",       "Meadow" },
		{ "Meadow",       "Meadow",       "Meadow",       "Meadow",       "Meadow" },
		{ "Meadow",       "Meadow",       "Meadow",       "Meadow",       "Meadow" },
		{ "Badlands",     "Badlands",     "Badlands",     "Badlands",     "Badlands" },
	},
	peaks = {
		{ "Peaks",        "Peaks",        "Peaks",        "Peaks",        "Peaks" },
		{ "Peaks",        "Peaks",        "Peaks",        "Peaks",        "Peaks" },
		{ "Peaks",        "Peaks",        "Peaks",        "Peaks",        "Peaks" },
		{ "Peaks",        "Peaks",        "Peaks",        "Peaks",        "Peaks" },
		{ "Badlands",     "Badlands",     "Badlands",     "Badlands",     "Badlands" },
	},
}

local indexOf: { [string]: number } = {}
for i, biome in LIST do
	indexOf[biome.name] = i
	table.freeze(biome)
end
table.freeze(LIST)

local function resolve(layout: { { string } }): Table
	local out = table.create(#layout)
	for t, row in layout do
		local resolved = table.create(#row)
		for h, name in row do
			resolved[h] = assert(indexOf[name], `unknown biome {name}`)
		end
		out[t] = table.freeze(resolved)
	end
	return table.freeze(out)
end

return table.freeze({
	list = LIST,

	-- Band edges on the climate values the sampler computes (noise scaled to
	-- roughly [-1, 1]). They split the world into about 15/20/38/14/13% by
	-- temperature and 15/22/30/18/15% by humidity.
	TEMPERATURE_EDGES = table.freeze({ -0.58, -0.22, 0.36, 0.65 }),
	HUMIDITY_EDGES = table.freeze({ -0.55, -0.15, 0.32, 0.62 }),

	-- Terrain bands, lowest first; the sampler supplies the elevation edges.
	tables = table.freeze({
		resolve(LAYOUT.wetland),
		resolve(LAYOUT.lowland),
		resolve(LAYOUT.slopes),
		resolve(LAYOUT.peaks),
	}),

	index = function(name: string): number
		return assert(indexOf[name], `unknown biome {name}`)
	end,
})
