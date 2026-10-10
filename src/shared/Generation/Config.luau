--!strict
--[[
	Generator settings: the schema is the single source of truth.

	The server sanitises anything arriving over the network against it, and the
	debug panel builds its widgets from it, so adding a field here is the whole
	job of exposing a new knob.
]]

export type Mode = "Stream" | "Pregenerate"
export type Toggle = "On" | "Off"

export type Config = {
	seed: number,
	mode: Mode,
	viewRadius: number,
	unloadMargin: number,
	pregenRadius: number,

	seaLevel: number,
	continentScale: number,
	coastBias: number,
	oceanDepth: number,
	landHeight: number,
	detailScale: number,
	detailStrength: number,
	hillHeight: number,
	hillScale: number,
	reliefScale: number,
	erosion: number,

	rangeScale: number,
	rangeWidth: number,
	mountainBase: number,
	mountainHeight: number,
	mountainScale: number,

	beachHeight: number,
	beachWidth: number,
	cliffAmount: number,
	cliffHeight: number,

	biomeScale: number,
	biomeBlend: number,
	slopeElevation: number,
	peakElevation: number,
	temperatureBias: number,
	moistureBias: number,

	riverScale: number,
	riverWidth: number,
	riverDepth: number,
	riverMaxElevation: number,

	snowLine: number,
	steepSlope: number,

	caves: Toggle,
	tunnelRadius: number,
	tunnelScale: number,
	caveDepth: number,
	chamberAmount: number,
	chamberRadius: number,
	chamberScale: number,
	overhangs: Toggle,
	overhangStrength: number,
	overhangScale: number,

	treeDensity: number,
	oreDensity: number,
	caveOreDensity: number,
}

export type NumberField = {
	kind: "number",
	key: string,
	label: string,
	group: string,
	default: number,
	min: number,
	max: number,
	step: number,
}

export type ChoiceField = {
	kind: "choice",
	key: string,
	label: string,
	group: string,
	default: string,
	options: { string },
}

export type Field = NumberField | ChoiceField

local function number(
	group: string,
	key: string,
	label: string,
	default: number,
	min: number,
	max: number,
	step: number
): Field
	return {
		kind = "number",
		group = group,
		key = key,
		label = label,
		default = default,
		min = min,
		max = max,
		step = step,
	}
end

local function choice(group: string, key: string, label: string, default: string, options: { string }): Field
	return { kind = "choice", group = group, key = key, label = label, default = default, options = options }
end

local GROUPS = { "World", "Shape", "Mountains", "Coast", "Biomes", "Water", "Materials", "Caves", "Assets" }

-- stylua: ignore
local FIELDS: { Field } = {
	number("World", "seed", "Seed", 1337, 0, 2147483646, 1),
	choice("World", "mode", "Mode", "Stream", { "Stream", "Pregenerate" }),
	number("World", "viewRadius", "View radius (chunks)", 8, 2, 32, 1),
	number("World", "unloadMargin", "Unload margin (chunks)", 2, 0, 8, 1),
	number("World", "pregenRadius", "Pregen radius (chunks)", 12, 1, 64, 1),

	number("Shape", "seaLevel", "Sea level", 0, -64, 128, 4),
	number("Shape", "continentScale", "Continent scale", 2400, 300, 12000, 50),
	number("Shape", "coastBias", "Land bias", 0.1, -0.6, 0.6, 0.01),
	number("Shape", "oceanDepth", "Ocean depth", 70, 8, 120, 1),
	number("Shape", "landHeight", "Land height", 10, 0, 120, 1),
	number("Shape", "detailScale", "Detail scale", 220, 32, 1000, 1),
	number("Shape", "detailStrength", "Detail strength", 1, 0, 3, 0.05),
	number("Shape", "hillHeight", "Hill height", 40, 0, 160, 1),
	number("Shape", "hillScale", "Hill scale", 800, 100, 4000, 10),
	number("Shape", "reliefScale", "Hills vs plains scale", 2600, 400, 12000, 50),
	number("Shape", "erosion", "Erosion", 0.15, 0, 1, 0.01),

	number("Mountains", "rangeScale", "Range spacing", 3600, 600, 12000, 50),
	number("Mountains", "rangeWidth", "Range width (studs)", 1400, 200, 4000, 10),
	number("Mountains", "mountainBase", "Range uplift", 130, 0, 240, 1),
	number("Mountains", "mountainHeight", "Peak height", 320, 0, 480, 1),
	number("Mountains", "mountainScale", "Peak scale", 1300, 200, 5000, 10),

	number("Coast", "beachHeight", "Beach height", 5, 0, 16, 1),
	number("Coast", "beachWidth", "Beach width", 0.05, 0.01, 0.2, 0.005),
	number("Coast", "cliffAmount", "Cliff amount", 0.3, 0, 1, 0.01),
	number("Coast", "cliffHeight", "Cliff height", 28, 0, 120, 1),

	number("Biomes", "biomeScale", "Climate scale", 4000, 500, 16000, 10),
	number("Biomes", "biomeBlend", "Blend width", 0.08, 0.02, 0.15, 0.01),
	number("Biomes", "slopeElevation", "Slopes start", 150, 60, 300, 1),
	number("Biomes", "peakElevation", "Peaks start", 240, 120, 480, 1),
	number("Biomes", "temperatureBias", "Temperature bias", 0, -0.6, 0.6, 0.01),
	number("Biomes", "moistureBias", "Moisture bias", 0, -0.6, 0.6, 0.01),

	number("Water", "riverScale", "River scale", 1400, 200, 6000, 10),
	number("Water", "riverWidth", "River width", 0.035, 0, 0.15, 0.001),
	number("Water", "riverDepth", "River depth", 8, 0, 32, 1),
	number("Water", "riverMaxElevation", "River max elevation", 70, 0, 240, 1),

	number("Materials", "snowLine", "Snow line (temperate)", 290, 120, 500, 1),
	number("Materials", "steepSlope", "Rock slope", 1.0, 0.2, 3, 0.05),

	-- 3D terrain. With both switched off the world is the plain heightmap.
	choice("Caves", "caves", "Caves", "On", { "On", "Off" }),
	-- A character is about 5 studs tall; tunnels much under 6 studs radius get hard to walk.
	number("Caves", "tunnelRadius", "Tunnel radius (studs)", 9, 0, 24, 0.5),
	number("Caves", "tunnelScale", "Tunnel spacing", 240, 64, 800, 1),
	number("Caves", "caveDepth", "Cave band depth (studs)", 96, 16, 160, 4),
	-- Roughly the share of tunnel length that swells into chambers.
	number("Caves", "chamberAmount", "Chamber amount", 0.3, 0, 1, 0.01),
	number("Caves", "chamberRadius", "Chamber extra radius (studs)", 14, 0, 40, 1),
	number("Caves", "chamberScale", "Chamber scale", 160, 48, 600, 1),
	choice("Caves", "overhangs", "Overhangs", "On", { "On", "Off" }),
	number("Caves", "overhangStrength", "Overhang strength (studs)", 32, 0, 64, 1),
	number("Caves", "overhangScale", "Overhang scale", 96, 24, 400, 1),

	-- Groves and clearings move trees around, so forests average about 8 per chunk at 12.
	number("Assets", "treeDensity", "Tree density (forest)", 12, 0, 32, 0.5),
	number("Assets", "oreDensity", "Ore nodes per chunk (mountains)", 1, 0, 4, 0.05),
	number("Assets", "caveOreDensity", "Ore nodes per cave chunk", 4, 0, 16, 0.25),
}

local byKey: { [string]: Field } = {}
for _, field in FIELDS do
	byKey[field.key] = field
end

local Config = {}

Config.GROUPS = GROUPS
Config.FIELDS = FIELDS

function Config.field(key: string): Field?
	return byKey[key]
end

function Config.defaults(): Config
	local out: { [string]: any } = {}
	for _, field in FIELDS do
		out[field.key] = field.default
	end
	return (out :: any) :: Config
end

local function snap(field: NumberField, value: number): number
	local clamped = math.clamp(value, field.min, field.max)
	if field.step >= 1 then
		return math.clamp(math.round(clamped / field.step) * field.step, field.min, field.max)
	end
	return clamped
end

--[[
	Builds a complete, valid Config from untrusted input.

	Unknown keys are dropped, wrong types and NaN fall back to the default (or to
	`base` when given, so a partial update only touches the fields it names), and
	numbers are clamped and snapped to their step.
]]
function Config.sanitize(input: unknown, base: Config?): Config
	local source: { [any]: any } = if type(input) == "table" then input :: any else {}
	local fallback: { [string]: any } = (base or Config.defaults()) :: any
	local out: { [string]: any } = {}

	for _, field in FIELDS do
		local value = source[field.key]
		if field.kind == "number" then
			if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
				out[field.key] = snap(field, value)
			else
				out[field.key] = fallback[field.key]
			end
		else
			if type(value) == "string" and table.find(field.options, value) then
				out[field.key] = value
			else
				out[field.key] = fallback[field.key]
			end
		end
	end

	return (out :: any) :: Config
end

return Config
