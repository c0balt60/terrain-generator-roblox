--!strict
-- Chunk coordinate helpers. Chunks are CHUNK_STUDS square columns indexed by (cx, cz).

local Constants = require("./Constants")

local CHUNK_STUDS = Constants.CHUNK_STUDS

export type Coord = { cx: number, cz: number, distance2: number }

local ChunkGrid = {}

function ChunkGrid.key(cx: number, cz: number): string
	return `{cx},{cz}`
end

function ChunkGrid.chunkOf(x: number, z: number): (number, number)
	return x // CHUNK_STUDS, z // CHUNK_STUDS
end

-- Centre of a chunk in studs.
function ChunkGrid.center(cx: number, cz: number): (number, number)
	return (cx + 0.5) * CHUNK_STUDS, (cz + 0.5) * CHUNK_STUDS
end

-- Every chunk whose centre lies within `radius` chunks of (cx, cz), nearest first.
function ChunkGrid.inRadius(cx: number, cz: number, radius: number): { Coord }
	local out = {}
	local r = math.floor(radius)
	local r2 = radius * radius
	for dx = -r, r do
		for dz = -r, r do
			local d2 = dx * dx + dz * dz
			if d2 <= r2 then
				table.insert(out, { cx = cx + dx, cz = cz + dz, distance2 = d2 })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.distance2 < b.distance2
	end)
	return out
end

-- Squared distance in chunks between two chunk coordinates.
function ChunkGrid.distance2(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = ax - bx, az - bz
	return dx * dx + dz * dz
end

return ChunkGrid
