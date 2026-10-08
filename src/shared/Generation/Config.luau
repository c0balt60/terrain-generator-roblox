--!strict
--[[
	Generator settings: the schema is the single source of truth.

	The server sanitises anything arriving over the network against it, and the
	debug panel builds its widgets from it, so adding a field here is the whole
	job of exposing a new knob.
]]

export type Mode = "Stream" | "Pregenerate"

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
	mountainScale: number,
	mountainHeight: number,

	biomeScale: number,
	biomeBlend: number,
	temperatureBias: number,
	moistureBias: number,

	riverScale: number,
	riverWidth: number,
	riverDepth: number,
	riverMaxElevation: number,

	beachHeight: number,
	snowLine: number,
	steepSlope: number,
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

local GROUPS = { "World", "Shape", "Biomes", "Water", "Materials" }

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
	number("Shape", "landHeight", "Land height", 24, 0, 120, 1),
	number("Shape", "detailScale", "Detail scale", 220, 32, 1000, 1),
	number("Shape", "detailStrength", "Detail strength", 1, 0, 3, 0.05),
	number("Shape", "mountainScale", "Mountain scale", 1100, 200, 5000, 10),
	number("Shape", "mountainHeight", "Mountain height", 240, 0, 360, 1),

	number("Biomes", "biomeScale", "Climate scale", 1800, 200, 10000, 10),
	number("Biomes", "biomeBlend", "Blend width", 0.18, 0.02, 0.5, 0.01),
	number("Biomes", "temperatureBias", "Temperature bias", 0, -0.6, 0.6, 0.01),
	number("Biomes", "moistureBias", "Moisture bias", 0, -0.6, 0.6, 0.01),

	number("Water", "riverScale", "River scale", 1400, 200, 6000, 10),
	number("Water", "riverWidth", "River width", 0.035, 0, 0.15, 0.001),
	number("Water", "riverDepth", "River depth", 8, 0, 32, 1),
	number("Water", "riverMaxElevation", "River max elevation", 70, 0, 240, 1),

	number("Materials", "beachHeight", "Beach height", 5, 0, 24, 1),
	number("Materials", "snowLine", "Snow line", 190, 40, 480, 1),
	number("Materials", "steepSlope", "Rock slope", 1.0, 0.2, 3, 0.05),
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
