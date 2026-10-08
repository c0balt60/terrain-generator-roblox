--!strict
--[[
	Character spawning for a world that doesn't exist yet.

	CharacterAutoLoads is off (see default.project.json), so nobody spawns
	until the terrain under the spawn point is written. After a regenerate,
	existing characters are frozen in place until the ground under them is
	back, then set down on the new surface.
]]

local Players = game:GetService("Players")

local ChunkManager = require("./ChunkManager")

local SETTLE_TIMEOUT = 20
local DROP_HEIGHT = 6

local Spawning = {}

local function waitForGround(manager: ChunkManager.ChunkManager, x: number, z: number, epoch: number): boolean
	local deadline = os.clock() + SETTLE_TIMEOUT
	while not manager:isAreaLoaded(x, z, 1) do
		if manager.epoch ~= epoch or os.clock() > deadline then
			return false
		end
		task.wait(0.1)
	end
	return true
end

local function surfaceAt(manager: ChunkManager.ChunkManager, x: number, z: number): number
	return math.max(manager.sampler.height(x, z), manager.config.seaLevel) + DROP_HEIGHT
end

local function spawnPlayer(manager: ChunkManager.ChunkManager, player: Player)
	while player.Parent do
		local epoch = manager.epoch
		local spawn = manager.spawn
		if waitForGround(manager, spawn.X, spawn.Z, epoch) and epoch == manager.epoch then
			break
		end
	end
	if player.Parent == nil then
		return
	end

	player:LoadCharacterAsync()
	local character = player.Character
	if character then
		local spawn = manager.spawn
		character:PivotTo(CFrame.new(spawn.X, surfaceAt(manager, spawn.X, spawn.Z), spawn.Z))
	end
end

-- Holds a character still until the regenerated ground under it exists.
local function resettle(manager: ChunkManager.ChunkManager, character: Model)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root == nil then
		return
	end

	local epoch = manager.epoch
	local position = root.Position
	local x, z = position.X, position.Z
	if not manager:isInWorld(x, z) then
		x, z = manager.spawn.X, manager.spawn.Z
	end

	root.Anchored = true
	waitForGround(manager, x, z, epoch)
	if root.Parent and epoch == manager.epoch then
		character:PivotTo(CFrame.new(x, surfaceAt(manager, x, z), z) * root.CFrame.Rotation)
	end
	root.Anchored = false
end

function Spawning.start(manager: ChunkManager.ChunkManager)
	local function onPlayerAdded(player: Player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			humanoid.Died:Once(function()
				task.wait(Players.RespawnTime)
				if player.Parent and player.Character == character then
					spawnPlayer(manager, player)
				end
			end)
		end)
		spawnPlayer(manager, player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	manager.changed:Connect(function()
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character then
				task.spawn(resettle, manager, character)
			end
		end
	end)
end

return Spawning
