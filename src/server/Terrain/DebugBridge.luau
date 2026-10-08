--!strict
--[[
	Server end of the Iris debug panel.

	Only trusted players may change the world: anyone in Studio, or the owner
	of a user-owned place. They're flagged with the `TerrainDebug` attribute,
	which the client checks before building the panel. Every request is
	re-checked here and sanitised against the config schema.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ChunkManager = require("./ChunkManager")
local Config = require("@generation/Config")

local APPLY_COOLDOWN = 1

local DebugBridge = {}

local function isTrusted(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

function DebugBridge.start(manager: ChunkManager.ChunkManager)
	local remote = Instance.new("RemoteEvent")
	remote.Name = "TerrainDebug"
	remote.Parent = ReplicatedStorage

	local lastApply: { [Player]: number } = {}

	local function onPlayerAdded(player: Player)
		player:SetAttribute("TerrainDebug", isTrusted(player))
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastApply[player] = nil
	end)

	remote.OnServerEvent:Connect(function(player: Player, action: unknown, payload: unknown)
		if not isTrusted(player) or action ~= "Apply" then
			return
		end
		local now = os.clock()
		if now - (lastApply[player] or 0) < APPLY_COOLDOWN then
			return
		end
		lastApply[player] = now

		manager:setConfig(Config.sanitize(payload, manager.config))
	end)
end

return DebugBridge
