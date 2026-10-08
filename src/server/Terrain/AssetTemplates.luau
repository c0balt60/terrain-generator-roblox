--!strict
--[[
	Placeholder asset models, built from Parts.

	`ensure` fills ServerStorage.AssetTemplates with a placeholder for every name
	in Assets.NAMES that has no model there yet, so a real model with the same
	name always wins. Templates must be Models with their pivot at the ground
	contact point: the worker scales them with ScaleTo and places them with
	PivotTo.
]]

local ServerStorage = game:GetService("ServerStorage")

local Assets = require("@generation/Assets")

local BARK = Color3.fromRGB(105, 74, 48)
local BARK_DARK = Color3.fromRGB(74, 52, 38)
local BIRCH_BARK = Color3.fromRGB(226, 222, 208)
local SPRUCE = Color3.fromRGB(46, 92, 60)
local OAK = Color3.fromRGB(78, 140, 62)
local BIRCH = Color3.fromRGB(140, 180, 80)
local SWAMP = Color3.fromRGB(70, 96, 52)
local VINE = Color3.fromRGB(56, 78, 40)
local ACACIA = Color3.fromRGB(128, 140, 58)
local SNOW = Color3.fromRGB(240, 244, 248)
local STONE = Color3.fromRGB(110, 110, 112)

local function part(
	model: Model,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	shape: Enum.PartType?,
	collide: boolean?
)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = collide == true
	p.CanTouch = false
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Parent = model
end

local function trunk(model: Model, width: number, height: number, color: Color3)
	part(
		model,
		Vector3.new(width, height, width),
		CFrame.new(0, height / 2 - 1, 0),
		color,
		Enum.Material.Wood,
		nil,
		true
	)
end

local function spruce(snowy: boolean): (Model) -> ()
	return function(model)
		trunk(model, 1.2, 9, BARK_DARK)
		for i, width in { 9, 7, 5, 3 } do
			local cf = CFrame.new(0, 2.5 + i * 2.4, 0) * CFrame.Angles(0, i * math.pi / 4, 0)
			part(model, Vector3.new(width, 3, width), cf, SPRUCE, Enum.Material.SmoothPlastic)
			if snowy then
				part(
					model,
					Vector3.new(width * 0.8, 0.6, width * 0.8),
					cf * CFrame.new(0, 1.7, 0),
					SNOW,
					Enum.Material.Snow
				)
			end
		end
	end
end

local function ore(color: Color3, material: Enum.Material): (Model) -> ()
	return function(model)
		part(
			model,
			Vector3.new(5, 4, 4.5),
			CFrame.new(0, 1.2, 0) * CFrame.Angles(0.2, 0.5, 0.1),
			STONE,
			Enum.Material.Slate,
			nil,
			true
		)
		part(
			model,
			Vector3.new(3, 3, 3),
			CFrame.new(2.2, 0.8, 1.2) * CFrame.Angles(0.4, 0.2, 0.3),
			STONE,
			Enum.Material.Slate,
			nil,
			true
		)
		for _, offset in
			{
				Vector3.new(0.6, 3.2, 0.3),
				Vector3.new(-2, 2.2, 1.2),
				Vector3.new(0.8, 2, -2),
				Vector3.new(2.8, 2.3, 1.6),
			}
		do
			part(model, Vector3.one * 1.2, CFrame.new(offset) * CFrame.Angles(0.6, 0.8, 0), color, material)
		end
	end
end

local BUILDERS: { [string]: (Model) -> () } = {
	Spruce = spruce(false),
	SnowySpruce = spruce(true),

	Oak = function(model)
		trunk(model, 1.6, 8, BARK)
		part(model, Vector3.one * 9, CFrame.new(0, 9, 0), OAK, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		part(model, Vector3.one * 6, CFrame.new(2, 11.5, 1), OAK, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end,

	Birch = function(model)
		trunk(model, 1, 10, BIRCH_BARK)
		part(model, Vector3.new(6, 5, 6), CFrame.new(0, 10, 0), BIRCH, Enum.Material.SmoothPlastic)
		local top = CFrame.new(0, 13, 0) * CFrame.Angles(0, math.pi / 4, 0)
		part(model, Vector3.new(4, 3, 4), top, BIRCH, Enum.Material.SmoothPlastic)
	end,

	SwampOak = function(model)
		trunk(model, 2, 8, BARK_DARK)
		part(model, Vector3.new(13, 2.5, 13), CFrame.new(0, 7.5, 0), SWAMP, Enum.Material.SmoothPlastic)
		for _, corner in { Vector3.new(5, 0, 5), Vector3.new(-5, 0, 4), Vector3.new(4, 0, -5), Vector3.new(-4, 0, -4) } do
			part(
				model,
				Vector3.new(0.4, 4, 0.4),
				CFrame.new(corner + Vector3.new(0, 4.5, 0)),
				VINE,
				Enum.Material.SmoothPlastic
			)
		end
	end,

	Acacia = function(model)
		trunk(model, 1, 9, BARK)
		part(
			model,
			Vector3.new(0.8, 5, 0.8),
			CFrame.new(1.4, 7, 0) * CFrame.Angles(0, 0, -0.6),
			BARK,
			Enum.Material.Wood
		)
		part(model, Vector3.new(11, 1.5, 11), CFrame.new(0, 8.5, 0), ACACIA, Enum.Material.SmoothPlastic)
		part(model, Vector3.new(6, 1.2, 6), CFrame.new(3.5, 9.3, 0), ACACIA, Enum.Material.SmoothPlastic)
	end,

	Coal = ore(Color3.fromRGB(30, 30, 32), Enum.Material.SmoothPlastic),
	Iron = ore(Color3.fromRGB(216, 175, 147), Enum.Material.SmoothPlastic),
	Gold = ore(Color3.fromRGB(245, 205, 48), Enum.Material.SmoothPlastic),
	Diamond = ore(Color3.fromRGB(85, 230, 230), Enum.Material.Neon),
}

local AssetTemplates = {}

function AssetTemplates.ensure(): Instance
	local folder = ServerStorage:FindFirstChild("AssetTemplates") or Instance.new("Folder")
	folder.Name = "AssetTemplates"
	for _, name in Assets.NAMES do
		if folder:FindFirstChild(name) then
			continue
		end
		local build = BUILDERS[name]
		if build == nil then
			warn(`[Terrain] asset {name} has no model in ServerStorage.AssetTemplates and no placeholder`)
			continue
		end
		local model = Instance.new("Model")
		model.Name = name
		build(model)
		model.WorldPivot = CFrame.identity
		model.Parent = folder
	end
	folder.Parent = ServerStorage
	return folder
end

return AssetTemplates
