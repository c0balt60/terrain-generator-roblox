--!strict
--[[
	Fixed pool of Actor workers, one job each at a time.

	Jobs go out with Actor:SendMessage and come back through the shared
	ChunkDone BindableEvent. A job that never reports (a worker error in the
	parallel phase, for example) is reaped after JOB_TIMEOUT so its actor isn't
	lost for good.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Config = require("@generation/Config")

local JOB_TIMEOUT = 15

export type Result = {
	ok: boolean,
	buildTime: number,
	writeTime: number,
}

type Pending = {
	actor: Actor,
	startedAt: number,
	callback: (Result) -> (),
}

export type WorkerPool = {
	submit: (
		self: WorkerPool,
		epoch: number,
		cx: number,
		cz: number,
		config: Config.Config,
		callback: (Result) -> ()
	) -> boolean,
	idleCount: (self: WorkerPool) -> number,
	busyCount: (self: WorkerPool) -> number,
	reap: (self: WorkerPool) -> (),

	_idle: { Actor },
	_pending: { [number]: Pending },
	_nextId: number,
}

local WorkerPool = {}
WorkerPool.__index = WorkerPool

function WorkerPool.new(runtime: Instance, count: number): WorkerPool
	local template = ServerStorage:WaitForChild("TerrainWorker") :: Actor
	local folder = Instance.new("Folder")
	folder.Name = "TerrainWorkers"

	local self = setmetatable({
		_idle = {},
		_pending = {},
		_nextId = 0,
	}, WorkerPool) :: any

	for i = 1, count do
		local actor = template:Clone()
		actor.Name = `Worker{i}`
		actor.Parent = folder
		table.insert(self._idle, actor)
	end
	folder.Parent = ServerScriptService

	local done = runtime:WaitForChild("ChunkDone") :: BindableEvent
	done.Event:Connect(function(id: number, ok: boolean, buildTime: number, writeTime: number)
		local pending = self._pending[id]
		if pending == nil then
			return -- Already reaped.
		end
		self._pending[id] = nil
		table.insert(self._idle, pending.actor)
		pending.callback({ ok = ok, buildTime = buildTime, writeTime = writeTime })
	end)

	return self :: WorkerPool
end

-- Hands a chunk to an idle worker. Returns false when every worker is busy.
function WorkerPool.submit(
	self: WorkerPool,
	epoch: number,
	cx: number,
	cz: number,
	config: Config.Config,
	callback: (Result) -> ()
): boolean
	local actor = table.remove(self._idle)
	if actor == nil then
		return false
	end

	self._nextId += 1
	local id = self._nextId
	self._pending[id] = { actor = actor, startedAt = os.clock(), callback = callback }
	actor:SendMessage("Build", { id = id, epoch = epoch, cx = cx, cz = cz, config = config })
	return true
end

function WorkerPool.idleCount(self: WorkerPool): number
	return #self._idle
end

function WorkerPool.busyCount(self: WorkerPool): number
	local count = 0
	for _ in self._pending do
		count += 1
	end
	return count
end

function WorkerPool.reap(self: WorkerPool)
	local now = os.clock()
	for id, pending in self._pending do
		if now - pending.startedAt > JOB_TIMEOUT then
			warn(`[Terrain] {pending.actor.Name} timed out on job {id}; returning it to the pool`)
			self._pending[id] = nil
			table.insert(self._idle, pending.actor)
			pending.callback({ ok = false, buildTime = 0, writeTime = 0 })
		end
	end
end

return WorkerPool
