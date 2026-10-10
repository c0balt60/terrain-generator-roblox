local Assets = require("@generation/Assets")
local ChunkBuilder = require("@generation/ChunkBuilder")
local ChunkGrid = require("@generation/ChunkGrid")
local Config = require("@generation/Config")
local Constants = require("@generation/Constants")
local Sampler = require("@generation/Sampler")
local expect = require("./expect")

local CHUNK_STUDS = Constants.CHUNK_STUDS
local N = Constants.CHUNK_VOXELS
local VOXEL = Constants.VOXEL_SIZE

return function(test)
	local config = Config.defaults()
	local sampler = Sampler.new(config)

	test("placements are dry, inside their chunk and use known names", function()
		local counts = { Tree = 0, Ore = 0 }
		for cx = -40, 40, 4 do
			for cz = -40, 40, 4 do
				for _, p in Assets.place(sampler, cx, cz) do
					counts[p.kind] += 1
					expect.truthy(table.find(Assets.NAMES, p.name), `known name {p.name}`)
					expect.between(p.x, cx * CHUNK_STUDS, (cx + 1) * CHUNK_STUDS, "x in chunk")
					expect.between(p.z, cz * CHUNK_STUDS, (cz + 1) * CHUNK_STUDS, "z in chunk")
					expect.truthy(p.y >= config.seaLevel + config.beachHeight + 1, "above the beach")
				end
			end
		end
		print(`    {counts.Tree} trees, {counts.Ore} ores over 441 chunks`)
		expect.truthy(counts.Tree > 0, "some trees")
		expect.truthy(counts.Ore > 0, "some ores")
	end)

	test("placement is deterministic", function()
		local a = Assets.place(sampler, 7, -3)
		local b = Assets.place(Sampler.new(config), 7, -3)
		expect.equal(#a, #b, "count")
		for i, p in a do
			expect.equal(p.name, b[i].name, "name")
			expect.equal(p.x, b[i].x, "x")
			expect.equal(p.z, b[i].z, "z")
		end
	end)

	-- Built chunks with plenty of cave: a block of hilly land, where the cave
	-- band is fully open.
	local caveChunks = {}
	do
		local ox, oz
		for x = 0, 9000, 300 do
			local h = sampler.height(x, -x * 0.53)
			if h > config.seaLevel + 40 and h < config.seaLevel + 120 then
				ox, oz = ChunkGrid.chunkOf(x, -x * 0.53)
				break
			end
		end
		assert(ox and oz, "no hilly land found")
		for i = 0, 5 do
			for j = 0, 5 do
				local chunk = ChunkBuilder.build(sampler, ox + i, oz + j)
				local carved = 0
				for x = 1, N do
					for z = 1, N do
						local h = chunk.heights[(x - 1) * N + z]
						for y = 1, chunk.sizeY // VOXEL do
							if chunk.minY + y * VOXEL <= h and chunk.occupancy[x][y][z] < 1 then
								carved += 1
							end
						end
					end
				end
				if carved > 100 then
					table.insert(caveChunks, chunk)
				end
			end
		end
	end

	test("cave ores stud cave floors, walls and ceilings", function()
		local total, floors, walls, ceilings = 0, 0, 0, 0
		local byName = {}
		for _, chunk in caveChunks do
			local h = chunk.heights
			for _, p in Assets.placeInCaves(sampler, chunk) do
				total += 1
				byName[p.name] = (byName[p.name] or 0) + 1
				expect.truthy(table.find(Assets.NAMES, p.name), `known name {p.name}`)
				expect.between(p.x, chunk.minX, chunk.minX + CHUNK_STUDS, "x in chunk")
				expect.between(p.z, chunk.minZ, chunk.minZ + CHUNK_STUDS, "z in chunk")
				expect.near(p.nx * p.nx + p.ny * p.ny + p.nz * p.nz, 1, 1e-6, "unit up vector")

				local x = (p.x - chunk.minX) // VOXEL + 1
				local z = (p.z - chunk.minZ) // VOXEL + 1
				expect.truthy(p.y < h[(x - 1) * N + z], "under the surface")
				-- Rock just behind the node, open cave in front of it.
				local function solidAt(d: number): number
					local vx = (p.x + p.nx * d - chunk.minX) // VOXEL + 1
					local vy = (p.y + p.ny * d - chunk.minY) // VOXEL + 1
					local vz = (p.z + p.nz * d - chunk.minZ) // VOXEL + 1
					local plane = chunk.occupancy[math.clamp(vx, 1, N)]
					return plane[vy] and plane[vy][math.clamp(vz, 1, N)] or 0
				end
				expect.truthy(solidAt(-3) > 0, "rock behind")
				expect.truthy(solidAt(VOXEL) < 1, "air in front")

				if p.ny > 0.7 then
					floors += 1
				elseif p.ny < -0.7 then
					ceilings += 1
				elseif math.abs(p.ny) < 0.5 then
					walls += 1
				end
			end
		end
		local names = {}
		for name, count in byName do
			table.insert(names, `{name} {count}`)
		end
		table.sort(names)
		print(
			`    {string.format("%.1f", total / #caveChunks)} per cave chunk over {#caveChunks}: `
				.. `{floors} floor, {walls} wall, {ceilings} ceiling; {table.concat(names, ", ")}`
		)
		expect.near(total / #caveChunks, config.caveOreDensity, config.caveOreDensity * 0.5, "density")
		expect.truthy(floors > 0 and walls > 0 and ceilings > 0, "floors, walls and ceilings")
	end)

	test("deep caves hold the rich ores", function()
		local band = config.caveDepth
		for _, chunk in caveChunks do
			for _, p in Assets.placeInCaves(sampler, chunk) do
				local x = (p.x - chunk.minX) // VOXEL + 1
				local z = (p.z - chunk.minZ) // VOXEL + 1
				local h = chunk.heights[(x - 1) * N + z]
				if p.name == "Diamond" then
					-- Sampled at the voxel centre, so allow a little slack on depth.
					local peak = h - config.seaLevel >= config.peakElevation - VOXEL
					expect.truthy(h - p.y >= band * 0.8 - VOXEL * 2 or peak, "diamonds lie deep or under peaks")
				end
			end
		end
	end)

	test("cave ores are deterministic and switch off with caves", function()
		local chunk = caveChunks[1]
		local a = Assets.placeInCaves(sampler, chunk)
		local b = Assets.placeInCaves(Sampler.new(config), chunk)
		expect.equal(#a, #b, "count")
		for i, p in a do
			expect.equal(p.name, b[i].name, "name")
			expect.equal(p.y, b[i].y, "y")
		end
		local off = Config.sanitize({ caves = "Off" }, config)
		expect.equal(#Assets.placeInCaves(Sampler.new(off), chunk), 0, "caves off")
		local none = Config.sanitize({ caveOreDensity = 0 }, config)
		expect.equal(#Assets.placeInCaves(Sampler.new(none), chunk), 0, "zero density")
	end)

	test("zero density places nothing", function()
		local empty = Config.sanitize({ treeDensity = 0, oreDensity = 0 }, config)
		local emptySampler = Sampler.new(empty)
		for cx = -8, 8, 4 do
			expect.equal(#Assets.place(emptySampler, cx, 0), 0, "placements")
		end
	end)
end
