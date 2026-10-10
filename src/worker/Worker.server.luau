--!strict
--[[
	Parallel chunk worker. The template lives in ServerStorage.TerrainWorker
	(an Actor) and never runs there; WorkerPool clones it into
	ServerScriptService once per worker thread.

	Noise and voxel arrays are built in the parallel phase. Writing to Terrain
	happens after task.synchronize(), and only if the world epoch hasn't moved
	on, so a regenerate never gets stale chunks written over it.
]]

local ServerStorage = game:GetService("ServerStorage")

local Assets = require("@generation/Assets")
local ChunkBuilder = require("@generation/ChunkBuilder")
local ChunkGrid = require("@generation/ChunkGrid")
local Config = require("@generation/Config")
local Constants = require("@generation/Constants")
local Sampler = require("@generation/Sampler")

local actor = script:GetActor()
if actor == nil then
	return
end

export type Job = {
	id: number,
	epoch: number,
	cx: number,
	cz: number,
	config: Config.Config,
}

local runtime = ServerStorage:WaitForChild("TerrainRuntime")
local done = runtime:WaitForChild("ChunkDone") :: BindableEvent
local terrain = workspace.Terrain
local templates = ServerStorage:WaitForChild("AssetTemplates")
local assetRoot = workspace:WaitForChild("TerrainAssets")

local palette: ChunkBuilder.Palette = {}
for _, material in Enum.Material:GetEnumItems() do
	palette[material.Name] = material
end

local CHUNK_STUDS = Constants.CHUNK_STUDS

local cachedEpoch = -1
local sampler: Sampler.Sampler? = nil

actor:BindToMessageParallel("Build", function(job: Job)
	local current = sampler
	if current == nil or job.epoch ~= cachedEpoch then
		current = Sampler.new(Config.sanitize(job.config))
		sampler = current
		cachedEpoch = job.epoch
	end
	assert(current, "sampler not initialised")

	local buildStart = os.clock()
	local chunk = ChunkBuilder.build(current, job.cx, job.cz, palette)
	local placements = Assets.place(current, job.cx, job.cz)
	for _, placement in Assets.placeInCaves(current, chunk) do
		table.insert(placements, placement)
	end
	local buildTime = os.clock() - buildStart

	task.synchronize()

	if runtime:GetAttribute("Epoch") ~= job.epoch then
		done:Fire(job.id, false, buildTime, 0)
		return
	end

	local writeStart = os.clock()
	local min = Vector3.new(chunk.minX, chunk.minY, chunk.minZ)
	local region = Region3.new(min, min + Vector3.new(CHUNK_STUDS, chunk.sizeY, CHUNK_STUDS))
	terrain:WriteVoxelChannels(region, Constants.VOXEL_SIZE, {
		SolidMaterial = chunk.materials,
		SolidOccupancy = chunk.occupancy,
		LiquidOccupancy = chunk.liquid,
	})

	if #placements > 0 then
		local folder = Instance.new("Folder")
		folder.Name = ChunkGrid.key(job.cx, job.cz)
		for _, placement in placements do
			local template = templates:FindFirstChild(placement.name) :: Model?
			if template == nil then
				continue -- AssetTemplates.ensure already warned about it.
			end
			local model = template:Clone()
			model:ScaleTo(placement.scale)
			-- Stand the model along its up vector. Straight up gives the identity
			-- rotation, so surface assets just spin by yaw.
			local up = Vector3.new(placement.nx, placement.ny, placement.nz)
			local right = (Vector3.xAxis - up * up.X).Unit
			if up.X > 0.99 or up.X < -0.99 then
				right = (Vector3.zAxis - up * up.Z).Unit
			end
			local position = Vector3.new(placement.x, placement.y, placement.z)
			local stand = CFrame.fromMatrix(position, right, up, right:Cross(up))
			model:PivotTo(stand * CFrame.Angles(0, placement.yaw, 0))
			model:SetAttribute("Kind", placement.kind)
			model.Parent = folder
		end
		folder.Parent = assetRoot
	end

	done:Fire(job.id, true, buildTime, os.clock() - writeStart)
end)
