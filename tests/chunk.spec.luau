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
		local flat = table.clone(config)
		flat.caves, flat.overhangs = "Off", "Off"
		for _, case in { { "3D", sampler }, { "heightmap", Sampler.new(flat) } } do
			local start = os.clock()
			for i = 1, 20 do
				ChunkBuilder.build(case[2], i, i * 2)
			end
			local ms = (os.clock() - start) / 20 * 1000
			print(`    {case[1]}: {string.format("%.2f", ms)} ms/chunk (Lune, no native codegen)`)
		end
	end)

	-- Chunks spread over the world, plus every chunk holding a column above
	-- `minHeight` on a coarse grid (mountains, where overhangs grow).
	local function sampleChunks(minHeight: number): { { number } }
		local out = {}
		for cx = -60, 60, 20 do
			for cz = -60, 60, 30 do
				table.insert(out, { cx, cz })
			end
		end
		local found = 0
		for x = -9000, 9000, 600 do
			for z = -9000, 9000, 600 do
				if found < 12 and sampler.height(x, z) > minHeight then
					found += 1
					table.insert(out, { ChunkGrid.chunkOf(x, z) })
				end
			end
		end
		return out
	end

	test("with caves and overhangs off, occupancy is the plain heightmap", function()
		local flat = table.clone(config)
		flat.caves, flat.overhangs = "Off", "Off"
		local flatSampler = Sampler.new(flat)
		for _, coord in sampleChunks(150) do
			local chunk = ChunkBuilder.build(flatSampler, coord[1], coord[2])
			for x = 1, N do
				for z = 1, N do
					local h =
						flatSampler.height(chunk.minX + (x - 1) * VOXEL + VOXEL / 2, chunk.minZ + (z - 1) * VOXEL + 2)
					for y = 1, chunk.sizeY // VOXEL do
						local yb = chunk.minY + (y - 1) * VOXEL
						local expected = math.clamp((h - yb) / VOXEL, 0, 1)
						expect.equal(chunk.occupancy[x][y][z], expected, "heightmap occupancy")
						local water = if expected < 1 and yb < flat.seaLevel
							then math.clamp((flat.seaLevel - yb) / VOXEL, 0, 1)
							else 0
						expect.equal(chunk.liquid[x][y][z], water, "heightmap water")
					end
				end
			end
		end
	end)

	test("caves hollow the rock, stay dry and leave the floor sealed", function()
		-- Overhangs also leave air under the heightmap, so measure caves alone.
		local caveOnly = table.clone(config)
		caveOnly.overhangs = "Off"
		local caveSampler = Sampler.new(caveOnly)
		local carved, rock = 0, 0
		-- Carved and total voxels 0-32 studs and 64-96 studs below the surface.
		local shallow, shallowRock, deep, deepRock = 0, 0, 0, 0
		for _, coord in sampleChunks(150) do
			local chunk = ChunkBuilder.build(caveSampler, coord[1], coord[2])
			checkChunk(chunk)
			for x = 1, N do
				for z = 1, N do
					local h =
						caveSampler.height(chunk.minX + (x - 1) * VOXEL + VOXEL / 2, chunk.minZ + (z - 1) * VOXEL + 2)
					for y = 1, chunk.sizeY // VOXEL do
						local yb = chunk.minY + (y - 1) * VOXEL
						if yb + VOXEL <= h then
							local open = chunk.occupancy[x][y][z] < 1
							local depth = h - yb
							rock += 1
							if depth < 32 then
								shallowRock += 1
								shallow += if open then 1 else 0
							elseif depth >= 64 and depth < 96 then
								deepRock += 1
								deep += if open then 1 else 0
							end
							if open then
								carved += 1
								expect.equal(chunk.liquid[x][y][z], 0, "cave voxel is dry")
							end
						end
					end
					expect.equal(chunk.occupancy[x][1][z], 1, "world floor stays solid")
				end
			end
		end
		print(
			`    {string.format("%.1f", carved / rock * 100)}% of buried voxels carved; `
				.. `{string.format("%.1f", shallow / shallowRock * 100)}% near the surface, `
				.. `{string.format("%.1f", deep / deepRock * 100)}% 64-96 studs down`
		)
		expect.between(carved / rock, 0.005, 0.2, "cave volume")
		expect.truthy(deep / deepRock > 1.5 * shallow / shallowRock, "caves get roomier with depth")
	end)

	test("cave mouths are open: no films or thin roofs over caves", function()
		-- A part-solid surface voxel left over cave air, or a roof under
		-- MIN_ROOF thick, meshes as torn strips joining the cave mouths.
		local caveOnly = table.clone(config)
		caveOnly.overhangs = "Off"
		local caveSampler = Sampler.new(caveOnly)
		local ox, oz
		for x = 0, 9000, 300 do
			local h = caveSampler.height(x, x * 0.37)
			if h > caveOnly.seaLevel + 40 and h < caveOnly.seaLevel + 120 then
				ox, oz = ChunkGrid.chunkOf(x, x * 0.37)
				break
			end
		end
		assert(ox and oz, "no hilly land found")
		local opened = 0
		for i = 0, 5 do
			for j = 0, 5 do
				local chunk = ChunkBuilder.build(caveSampler, ox + i, oz + j)
				for x = 1, N do
					local o = chunk.occupancy[x]
					for z = 1, N do
						local top = 0
						for y = chunk.sizeY // VOXEL, 1, -1 do
							if o[y][z] > 0 then
								top = y
								break
							end
						end
						local h = chunk.heights[(x - 1) * N + z]
						-- Total solid down to the first empty voxel, when that voxel is buried.
						local sum, y = 0, top
						while y > 1 and o[y][z] > 0 do
							sum += o[y][z]
							y -= 1
						end
						if o[y][z] == 0 and chunk.minY + y * VOXEL <= h then
							expect.truthy(sum >= Sampler.MIN_ROOF, `roof {sum} voxels thick over a cave`)
						end
						if chunk.minY + top * VOXEL < h - VOXEL then
							opened += 1
						end
					end
				end
			end
		end
		print(`    {opened} columns open into caves`)
		expect.truthy(opened > 0, "some cave mouths")
	end)

	test("most caves are big enough to walk into from the surface", function()
		-- A 6x6 chunk block of hilly land; only the inner 4x4 is scored, so
		-- tunnels leaving the block are less likely to count as sealed.
		local ox, oz
		for x = 0, 9000, 300 do
			local h = sampler.height(x, x * 0.37)
			if h > config.seaLevel + 40 and h < config.seaLevel + 120 then
				ox, oz = ChunkGrid.chunkOf(x, x * 0.37)
				break
			end
		end
		assert(ox and oz, "no hilly land found")
		local SPAN = 6 * N
		local bottom = Constants.WORLD_BOTTOM
		local grid: { [number]: number } = {}
		local heights: { [number]: number } = {}
		local ny = 0
		for i = 0, 5 do
			for j = 0, 5 do
				local chunk = ChunkBuilder.build(sampler, ox + i, oz + j)
				ny = math.max(ny, chunk.sizeY // VOXEL)
				for x = 1, N do
					for z = 1, N do
						local gx, gz = i * N + x, j * N + z
						heights[gx * 1000 + gz] =
							sampler.height(chunk.minX + (x - 1) * VOXEL + 2, chunk.minZ + (z - 1) * VOXEL + 2)
						for y = 1, chunk.sizeY // VOXEL do
							grid[(gx * 1000 + gz) * 1000 + y] = chunk.occupancy[x][y][z]
						end
					end
				end
			end
		end
		ny += 2

		-- A player (about 2 x 5 studs) fits where a voxel and the one above it are empty.
		local function passable(x: number, y: number, z: number): boolean
			if x < 1 or x > SPAN or z < 1 or z > SPAN or y < 1 or y >= ny then
				return false
			end
			local key = (x * 1000 + z) * 1000 + y
			return (grid[key] or 0) == 0 and (grid[key + 1] or 0) == 0
		end
		local function buried(x: number, y: number, z: number): boolean
			return bottom + y * VOXEL <= heights[x * 1000 + z]
		end

		local reached: { [number]: boolean } = {}
		local queue = {}
		for x = 1, SPAN do
			for z = 1, SPAN do
				for y = 1, ny - 1 do
					if not buried(x, y, z) and passable(x, y, z) then
						local key = (x * 1000 + z) * 1000 + y
						reached[key] = true
						table.insert(queue, { x, y, z })
						break -- The lowest open voxel above ground is enough to start from.
					end
				end
			end
		end
		local head = 1
		while head <= #queue do
			local p = queue[head]
			head += 1
			for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
				local x, y, z = p[1] + d[1], p[2] + d[2], p[3] + d[3]
				local key = (x * 1000 + z) * 1000 + y
				if not reached[key] and passable(x, y, z) then
					reached[key] = true
					table.insert(queue, { x, y, z })
				end
			end
		end

		local carved, walkable, open = 0, 0, 0
		for x = N + 1, 5 * N do
			for z = N + 1, 5 * N do
				for y = 1, ny - 1 do
					if buried(x, y, z) and (grid[(x * 1000 + z) * 1000 + y] or 0) < 1 then
						carved += 1
						if passable(x, y, z) then
							walkable += 1
							if reached[(x * 1000 + z) * 1000 + y] then
								open += 1
							end
						end
					end
				end
			end
		end
		print(
			`    {carved} carved voxels, {math.round(walkable / carved * 100)}% walkable, `
				.. `{math.round(open / walkable * 100)}% of that reachable from the surface`
		)
		expect.truthy(walkable / carved > 0.3, "caves are wide enough to walk in")
		expect.truthy(open / walkable > 0.75, "most cave space connects to the surface")
	end)

	test("overhangs fold the ground over on steep mountains", function()
		local solo = table.clone(config)
		solo.caves = "Off"
		local soloSampler = Sampler.new(solo)
		local folded = 0
		for _, coord in sampleChunks(150) do
			local chunk = ChunkBuilder.build(soloSampler, coord[1], coord[2])
			checkChunk(chunk)
			for x = 1, N do
				for z = 1, N do
					-- Air with solid ground somewhere above it.
					local roofed = false
					for y = chunk.sizeY // VOXEL, 1, -1 do
						local solid = chunk.occupancy[x][y][z]
						if solid > 0.5 then
							roofed = true
						elseif roofed and solid == 0 then
							folded += 1
							expect.truthy(chunk.minY + (y - 1) * VOXEL >= solo.seaLevel, "no overhang over water")
							break
						end
					end
				end
			end
		end
		print(`    {folded} overhung columns`)
		expect.truthy(folded > 0, "some ground hangs over air")
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
