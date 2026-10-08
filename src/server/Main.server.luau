--!strict
-- Server entry point: wires the worker pool, chunk manager, spawning and debug bridge together.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ChunkManager = require("@server/Terrain/ChunkManager")
local Config = require("@generation/Config")
local DebugBridge = require("@server/Terrain/DebugBridge")
local Spawning = require("@server/Terrain/Spawning")
local WorkerPool = require("@server/Terrain/WorkerPool")

local WORKER_COUNT = 8
local STEP_INTERVAL = 0.1

-- Server-only plumbing shared with the workers: the epoch and the completion event.
local runtime = Instance.new("Folder")
runtime.Name = "TerrainRuntime"
local chunkDone = Instance.new("BindableEvent")
chunkDone.Name = "ChunkDone"
chunkDone.Parent = runtime
runtime.Parent = ServerStorage

-- Replicated read-only state for the debug panel: current config and live stats.
local state = Instance.new("Folder")
state.Name = "TerrainState"
state.Parent = ReplicatedStorage

local pool = WorkerPool.new(runtime, WORKER_COUNT)
local manager = ChunkManager.new(pool, runtime, state)
manager:setConfig(Config.defaults())

DebugBridge.start(manager)
Spawning.start(manager)

while true do
	local positions: { Vector3 } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(positions, character:GetPivot().Position)
		end
	end
	manager:step(positions)
	task.wait(STEP_INTERVAL)
end
