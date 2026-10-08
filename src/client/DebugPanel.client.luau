--!strict
--[[
	Iris panel for tuning the generator live. F4 toggles it.

	Widgets are generated from Config.FIELDS, so new config fields show up here
	automatically. Edits stay local until Apply, which sends the whole config;
	the server sanitises it, regenerates, and broadcasts the result back through
	TerrainState, which resyncs every open panel.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require("@generation/Config")
local Iris = require("@packages/Iris")

local TOGGLE_KEY = Enum.KeyCode.F4

local player = Players.LocalPlayer
if player:GetAttribute("TerrainDebug") == nil then
	player:GetAttributeChangedSignal("TerrainDebug"):Wait()
end
if player:GetAttribute("TerrainDebug") ~= true then
	return
end

local state = ReplicatedStorage:WaitForChild("TerrainState")
local remote = ReplicatedStorage:WaitForChild("TerrainDebug") :: RemoteEvent

Iris.Init(nil, nil, false)

-- Iris states must outlive the per-frame callback, so they're all created up front.
local isOpened = Iris.State(true)
local windowSize = Iris.State(Vector2.new(380, 560))
local headerStates: { [string]: any } = {}
for index, group in Config.GROUPS do
	headerStates[group] = Iris.State(index == 1)
end
local fieldStates: { [string]: any } = {}
for _, field in Config.FIELDS do
	fieldStates[field.key] = Iris.State(field.default)
end

local function decodeServerConfig(): { [string]: any }
	local encoded = state:GetAttribute("Config")
	if type(encoded) ~= "string" then
		return Config.defaults() :: any
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
	return if ok then decoded else Config.defaults() :: any
end

local applied = decodeServerConfig()

local function load(values: { [string]: any })
	for key, fieldState in fieldStates do
		if values[key] ~= nil then
			fieldState:set(values[key])
		end
	end
end

local function collect(): { [string]: any }
	local out = {}
	for key, fieldState in fieldStates do
		out[key] = fieldState:get()
	end
	return out
end

local function isDirty(): boolean
	for key, fieldState in fieldStates do
		if applied[key] ~= fieldState:get() then
			return true
		end
	end
	return false
end

load(applied)
state:GetAttributeChangedSignal("Config"):Connect(function()
	applied = decodeServerConfig()
	load(applied)
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == TOGGLE_KEY then
		isOpened:set(not isOpened:get())
	end
end)

local function stat(name: string): string
	local value = state:GetAttribute(name)
	return if value == nil then "-" else tostring(value)
end

Iris:Connect(function()
	Iris.Window({ "Terrain Generator" }, { isOpened = isOpened, size = windowSize })

	Iris.Text({ `Mode {stat("Mode")} · epoch {stat("Epoch")} · F4 toggles` })
	Iris.Text({ `Chunks loaded {stat("Loaded")} · pending {stat("Pending")}` })
	Iris.Text({ `Build {stat("BuildMs")} ms · write {stat("WriteMs")} ms (per chunk)` })
	local progress = state:GetAttribute("Progress")
	if type(progress) == "number" then
		Iris.Text({ `Pregenerated {math.floor(progress * 100)}%` })
	end

	Iris.Separator()

	for _, group in Config.GROUPS do
		Iris.CollapsingHeader({ group }, { isUncollapsed = headerStates[group] })
		for _, field in Config.FIELDS do
			if field.group ~= group then
				continue
			end
			if field.kind == "choice" then
				Iris.ComboArray({ field.label }, { index = fieldStates[field.key] }, field.options)
			elseif field.key == "seed" then
				Iris.InputNum(
					{ field.label, field.step, field.min, field.max, "%d" },
					{ number = fieldStates[field.key] }
				)
			else
				local format = if field.step >= 1 then "%d" else "%.3f"
				Iris.SliderNum(
					{ field.label, field.step, field.min, field.max, format },
					{ number = fieldStates[field.key] }
				)
			end
		end
		Iris.End()
	end

	Iris.Separator()

	Iris.SameLine()
	if Iris.Button({ "Apply" }).clicked() then
		remote:FireServer("Apply", collect())
	end
	if Iris.Button({ "Random seed" }).clicked() then
		fieldStates.seed:set(math.random(0, 2147483646))
		remote:FireServer("Apply", collect())
	end
	if Iris.Button({ "Revert" }).clicked() then
		load(applied)
	end
	if Iris.Button({ "Defaults" }).clicked() then
		load(Config.defaults() :: any)
	end
	Iris.End()

	if isDirty() then
		Iris.Text({ "Unapplied changes", false, Color3.fromRGB(255, 200, 80) })
	end

	Iris.End()
end)
