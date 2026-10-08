--!strict
--[[
	Decides which chunks should exist and feeds them to the worker pool.

	Stream mode keeps a disc of `viewRadius` chunks around every player (plus a
	small one around spawn) and clears chunks that fall `unloadMargin` beyond
	that. Pregenerate mode builds a fixed disc of `pregenRadius` chunks around
	the origin, nearest first, and never unloads.

	Every config change bumps the epoch: terrain is cleared, results from jobs
	started under an older epoch are dropped, and workers skip writing them.
]]

local HttpService = game:GetService("HttpService")

local ChunkGrid = require("@generation/ChunkGrid")
local Config = require("@generation/Config")
local Constants = require("@generation/Constants")
local Sampler = require("@generation/Sampler")
local WorkerPool = require("./WorkerPool")

local CHUNK_STUDS = Constants.CHUNK_STUDS
local SPAWN_RADIUS = 2
local MAX_UNLOADS_PER_STEP = 16
local TIMING_SMOOTHING = 0.1

type Entry = {
	cx: number,
	cz: number,
	loaded: boolean,
}

type Focus = {
	cx: number,
	cz: number,
	radius: number,
}

export type ChunkManager = {
	config: Config.Config,
	sampler: Sampler.Sampler,
	epoch: number,
	spawn: Vector3,
	changed: RBXScriptSignal,

	setConfig: (self: ChunkManager, config: Config.Config) -> (),
	step: (self: ChunkManager, positions: { Vector3 }) -> (),
	isLoaded: (self: ChunkManager, cx: number, cz: number) -> boolean,
	isAreaLoaded: (self: ChunkManager, x: number, z: number, radius: number) -> boolean,
	isInWorld: (self: ChunkManager, x: number, z: number) -> boolean,

	_pool: WorkerPool.WorkerPool,
	_runtime: Instance,
	_state: Instance,
	_assets: Instance,
	_chunks: { [string]: Entry },
	_pregenList: { ChunkGrid.Coord }?,
	_pregenCursor: number,
	_changedEvent: BindableEvent,
	_buildMs: number,
	_writeMs: number,
}

local offsetsByRadius: { [number]: { ChunkGrid.Coord } } = {}
local function offsets(radius: number): { ChunkGrid.Coord }
	local cached = offsetsByRadius[radius]
	if cached == nil then
		cached = ChunkGrid.inRadius(0, 0, radius)
		offsetsByRadius[radius] = cached
	end
	return cached
end

local function chunkRegion(cx: number, cz: number): Region3
	local min = Vector3.new(cx * CHUNK_STUDS, Constants.WORLD_BOTTOM, cz * CHUNK_STUDS)
	local max = Vector3.new((cx + 1) * CHUNK_STUDS, Constants.WORLD_TOP, (cz + 1) * CHUNK_STUDS)
	return Region3.new(min, max)
end

local ChunkManager = {}
ChunkManager.__index = ChunkManager

function ChunkManager.new(pool: WorkerPool.WorkerPool, runtime: Instance, state: Instance): ChunkManager
	-- Placed assets, one Folder per chunk named by its key. The workers fill it.
	local assets = Instance.new("Folder")
	assets.Name = "TerrainAssets"
	assets.Parent = workspace

	local changedEvent = Instance.new("BindableEvent")
	local self = setmetatable({
		epoch = 0,
		spawn = Vector3.zero,
		changed = changedEvent.Event,

		_pool = pool,
		_runtime = runtime,
		_state = state,
		_assets = assets,
		_chunks = {},
		_pregenList = nil,
		_pregenCursor = 1,
		_changedEvent = changedEvent,
		_buildMs = 0,
		_writeMs = 0,
	}, ChunkManager) :: any
	return self :: ChunkManager
end

function ChunkManager.setConfig(self: ChunkManager, config: Config.Config)
	self.config = config
	self.epoch += 1
	self._runtime:SetAttribute("Epoch", self.epoch)

	workspace.Terrain:Clear()
	self._assets:ClearAllChildren()
	table.clear(self._chunks)

	self.sampler = Sampler.new(config)
	local isPregen = config.mode == "Pregenerate"
	local spawnLimit = if isPregen then math.max(CHUNK_STUDS, (config.pregenRadius - 1) * CHUNK_STUDS) else nil
	local sx, sz, sy = Sampler.findSpawn(self.sampler, spawnLimit)
	self.spawn = Vector3.new(sx, sy, sz)

	self._pregenList = if isPregen then ChunkGrid.inRadius(0, 0, config.pregenRadius) else nil
	self._pregenCursor = 1

	self._state:SetAttribute("Config", HttpService:JSONEncode(config))
	self._state:SetAttribute("Epoch", self.epoch)
	self._state:SetAttribute("Mode", config.mode)
	self._changedEvent:Fire()
end

function ChunkManager.isLoaded(self: ChunkManager, cx: number, cz: number): boolean
	local entry = self._chunks[ChunkGrid.key(cx, cz)]
	return entry ~= nil and entry.loaded
end

function ChunkManager.isAreaLoaded(self: ChunkManager, x: number, z: number, radius: number): boolean
	local cx, cz = ChunkGrid.chunkOf(x, z)
	for _, offset in offsets(radius) do
		if not self:isLoaded(cx + offset.cx, cz + offset.cz) then
			return false
		end
	end
	return true
end

-- Pregenerated worlds have an edge; streamed worlds don't.
function ChunkManager.isInWorld(self: ChunkManager, x: number, z: number): boolean
	if self.config.mode ~= "Pregenerate" then
		return true
	end
	local cx, cz = ChunkGrid.chunkOf(x, z)
	return ChunkGrid.distance2(cx, cz, 0, 0) <= self.config.pregenRadius ^ 2
end

local function dispatch(self: ChunkManager, cx: number, cz: number): boolean
	local key = ChunkGrid.key(cx, cz)
	local epoch = self.epoch
	local accepted = self._pool:submit(epoch, cx, cz, self.config, function(result)
		if epoch ~= self.epoch then
			return
		end
		local entry = self._chunks[key]
		if entry == nil then
			return
		end
		if result.ok then
			entry.loaded = true
			self._buildMs += (result.buildTime * 1000 - self._buildMs) * TIMING_SMOOTHING
			self._writeMs += (result.writeTime * 1000 - self._writeMs) * TIMING_SMOOTHING
		else
			self._chunks[key] = nil
			if self._pregenList then
				self._pregenCursor = 1 -- Rescan so the failed chunk is retried.
			end
		end
	end)
	if accepted then
		self._chunks[key] = { cx = cx, cz = cz, loaded = false }
	end
	return accepted
end

local function stepPregenerate(self: ChunkManager, list: { ChunkGrid.Coord })
	local chunks = self._chunks
	while self._pregenCursor <= #list and self._pool:idleCount() > 0 do
		local coord = list[self._pregenCursor]
		if chunks[ChunkGrid.key(coord.cx, coord.cz)] == nil then
			if not dispatch(self, coord.cx, coord.cz) then
				break
			end
		end
		self._pregenCursor += 1
	end
end

local function stepStream(self: ChunkManager, focuses: { Focus })
	local chunks = self._chunks
	local config = self.config

	-- Load: nearest missing chunks first, measured from whichever focus wants them.
	local idle = self._pool:idleCount()
	if idle > 0 then
		local candidates: { ChunkGrid.Coord } = {}
		local seen: { [string]: boolean } = {}
		for _, focus in focuses do
			for _, offset in offsets(focus.radius) do
				local cx, cz = focus.cx + offset.cx, focus.cz + offset.cz
				local key = ChunkGrid.key(cx, cz)
				if chunks[key] == nil and not seen[key] then
					seen[key] = true
					table.insert(candidates, { cx = cx, cz = cz, distance2 = offset.distance2 })
				end
			end
		end
		table.sort(candidates, function(a, b)
			return a.distance2 < b.distance2
		end)
		for i = 1, math.min(idle, #candidates) do
			if not dispatch(self, candidates[i].cx, candidates[i].cz) then
				break
			end
		end
	end

	-- Unload: loaded chunks outside every focus's radius plus the margin.
	local unloaded = 0
	for key, entry in chunks do
		if not entry.loaded then
			continue
		end
		local keep = false
		for _, focus in focuses do
			local limit = focus.radius + config.unloadMargin
			if ChunkGrid.distance2(entry.cx, entry.cz, focus.cx, focus.cz) <= limit * limit then
				keep = true
				break
			end
		end
		if not keep then
			workspace.Terrain:FillRegion(chunkRegion(entry.cx, entry.cz), Constants.VOXEL_SIZE, Enum.Material.Air)
			local folder = self._assets:FindFirstChild(key)
			if folder then
				folder:Destroy()
			end
			chunks[key] = nil
			unloaded += 1
			if unloaded >= MAX_UNLOADS_PER_STEP then
				break
			end
		end
	end
end

-- Called on a fixed interval with the positions that need terrain around them.
function ChunkManager.step(self: ChunkManager, positions: { Vector3 })
	self._pool:reap()

	local pregenList = self._pregenList
	if pregenList then
		stepPregenerate(self, pregenList)
	else
		local spawnCx, spawnCz = ChunkGrid.chunkOf(self.spawn.X, self.spawn.Z)
		local focuses: { Focus } = { { cx = spawnCx, cz = spawnCz, radius = SPAWN_RADIUS } }
		for _, position in positions do
			local cx, cz = ChunkGrid.chunkOf(position.X, position.Z)
			table.insert(focuses, { cx = cx, cz = cz, radius = self.config.viewRadius })
		end
		stepStream(self, focuses)
	end

	local loaded, pending = 0, 0
	for _, entry in self._chunks do
		if entry.loaded then
			loaded += 1
		else
			pending += 1
		end
	end

	local state = self._state
	state:SetAttribute("Loaded", loaded)
	state:SetAttribute("Pending", pending)
	state:SetAttribute("BuildMs", math.round(self._buildMs * 100) / 100)
	state:SetAttribute("WriteMs", math.round(self._writeMs * 100) / 100)
	state:SetAttribute("Progress", if pregenList then loaded / #pregenList else nil)
end

return ChunkManager
