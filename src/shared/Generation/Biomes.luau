--!strict
--[[
	Biome table. Each biome sits at a point in (temperature, moisture) space,
	both in [-1, 1]; a column's weights come from its distance to every point,
	so neighbouring biomes blend their height parameters instead of stepping.

	Materials are Enum.Material names, not enums, so this stays loadable in
	Lune. The worker resolves them through a palette.
]]

export type Biome = {
	name: string,
	temperature: number,
	moisture: number,

	-- Height parameters, blended by weight.
	height: number, -- Offset above the continental base.
	roughness: number, -- Amplitude of the detail noise.
	mountains: number, -- 0..1 multiplier on the mountain layer.
	snowLineOffset: number,

	-- Materials, taken from the dominant biome only.
	surface: string,
	subsurface: string,
	steep: string,
	beach: string,
	seabed: string,
}

-- stylua: ignore
local BIOMES: { Biome } = {
	{
		name = "Tundra", temperature = -0.75, moisture = 0.0,
		height = 6, roughness = 10, mountains = 0.8, snowLineOffset = -160,
		surface = "Snow", subsurface = "Ground", steep = "Slate", beach = "Ground", seabed = "Ground",
	},
	{
		name = "Taiga", temperature = -0.35, moisture = 0.45,
		height = 10, roughness = 14, mountains = 0.9, snowLineOffset = -60,
		surface = "Grass", subsurface = "Ground", steep = "Slate", beach = "Ground", seabed = "Ground",
	},
	{
		name = "Plains", temperature = 0.1, moisture = -0.15,
		height = 4, roughness = 5, mountains = 0.45, snowLineOffset = 0,
		surface = "Grass", subsurface = "Ground", steep = "Rock", beach = "Sand", seabed = "Sand",
	},
	{
		name = "Forest", temperature = 0.15, moisture = 0.5,
		height = 12, roughness = 16, mountains = 0.7, snowLineOffset = 0,
		surface = "LeafyGrass", subsurface = "Ground", steep = "Rock", beach = "Sand", seabed = "Sand",
	},
	{
		name = "Swamp", temperature = 0.45, moisture = 0.9,
		height = -1, roughness = 3, mountains = 0.1, snowLineOffset = 40,
		surface = "Mud", subsurface = "Mud", steep = "Ground", beach = "Mud", seabed = "Mud",
	},
	{
		name = "Savanna", temperature = 0.6, moisture = -0.25,
		height = 6, roughness = 8, mountains = 0.4, snowLineOffset = 60,
		surface = "Ground", subsurface = "Sandstone", steep = "Sandstone", beach = "Sand", seabed = "Sand",
	},
	{
		name = "Desert", temperature = 0.8, moisture = -0.75,
		height = 8, roughness = 14, mountains = 0.5, snowLineOffset = 200,
		surface = "Sand", subsurface = "Sandstone", steep = "Sandstone", beach = "Sand", seabed = "Sand",
	},
}

table.freeze(BIOMES)
for _, biome in BIOMES do
	table.freeze(biome)
end

return BIOMES
