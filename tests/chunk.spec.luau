local ChunkBuilder = require("@generation/ChunkBuilder")
local ChunkGrid = require("@generation/ChunkGrid")
local Config = require("@generation/Config")
local Constants = require("@generation/Constants")
local Sampler = require("@generation/Sampler")
local expect = require("./expect")

local N = Constants.CHUNK_VOXELS
local VOXEL = Constants.VOXEL_SIZE

local function checkChunk(chunk: ChunkBuilder.Chunk)
	local ny = chunk.sizeY // VOXEL
	expect.equal(#chunk.materials, N, "x size")
	for x = 1, N do
		expect.equal(#chunk.materials[x], ny, "y size")
		for y = 1, ny do
			for z = 1, N do
				local solid = chunk.occupancy[x][y][z]
				local water = chunk.liquid[x][y][z]
				local material = chunk.materials[x][y][z]
				expect.between(solid, 0, 1, "solid occupancy")
				expect.between(water, 0, 1, "liquid occupancy")
				if solid > 0 then
					expect.truthy(material ~= "Air", "solid voxel has a material")
				else
					expect.equal(material, "Air", "empty voxel material")
				end
				if solid >= 1 then
					expect.equal(water, 0, "no water inside full solid")
				end
			end
		end
	end
end

return function(test)
	local config = Config.defaults()
	local sampler = Sampler.new(config)

	test("chunk channels have valid shape and values", function()
		local chunk = ChunkBuilder.build(sampler, 0, 0)
		expect.equal(chunk.minX, 0, "minX")
		expect.equal(chunk.minY, Constants.WORLD_BOTTOM, "minY")
		expect.equal(chunk.sizeY % VOXEL, 0, "sizeY on grid")
		checkChunk(chunk)
	end)

	test("chunks across the world are valid; oceans hold water", function()
		local waterChunks = 0
		local seaVoxel = (config.seaLevel - VOXEL - Constants.WORLD_BOTTOM) // VOXEL + 1
		for cx = -60, 60, 20 do
			for cz = -60, 60, 30 do
				local chunk = ChunkBuilder.build(sampler, cx, cz)
				checkChunk(chunk)
				for x = 1, N do
					if chunk.liquid[x][seaVoxel][1] > 0 then
						waterChunks += 1
						break
					end
				end
			end
		end
		expect.truthy(waterChunks > 0, "some chunks contain water")
	end)

	test("palette maps every material name", function()
		local palette = setmetatable({}, {
			__index = function(_, name)
				return #name
			end,
		})
		local chunk = ChunkBuilder.build(sampler, 3, -2, palette)
		for x = 1, N do
			for _, row in chunk.materials[x] do
				for _, value in row do
					expect.truthy(type(value) == "number", "palette value")
				end
			end
		end
	end)

	test("build is deterministic", function()
		local a = ChunkBuilder.build(sampler, -5, 9)
		local b = ChunkBuilder.build(Sampler.new(config), -5, 9)
		expect.equal(a.sizeY, b.sizeY, "sizeY")
		for x = 1, N do
			for y = 1, a.sizeY // VOXEL do
				for z = 1, N do
					expect.equal(a.occupancy[x][y][z], b.occupancy[x][y][z], "occupancy")
					expect.equal(a.materials[x][y][z], b.materials[x][y][z], "material")
				end
			end
		end
	end)

	test("chunk build time", function()
		local start = os.clock()
		for i = 1, 20 do
			ChunkBuilder.build(sampler, i, i * 2)
		end
		print(`    {string.format("%.2f", (os.clock() - start) / 20 * 1000)} ms/chunk (Lune, no native codegen)`)
	end)

	test("inRadius returns a sorted disc", function()
		local coords = ChunkGrid.inRadius(10, -4, 3)
		expect.equal(#coords, 29, "count for r=3")
		expect.equal(coords[1].cx, 10, "nearest first")
		for i = 2, #coords do
			expect.truthy(coords[i].distance2 >= coords[i - 1].distance2, "sorted")
		end
		expect.equal((ChunkGrid.chunkOf(-1, 0)), -1, "negative coordinates floor")
	end)
end
