local Assets = require("@generation/Assets")
local Config = require("@generation/Config")
local Constants = require("@generation/Constants")
local Sampler = require("@generation/Sampler")
local expect = require("./expect")

local CHUNK_STUDS = Constants.CHUNK_STUDS

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

	test("zero density places nothing", function()
		local empty = Config.sanitize({ treeDensity = 0, oreDensity = 0 }, config)
		local emptySampler = Sampler.new(empty)
		for cx = -8, 8, 4 do
			expect.equal(#Assets.place(emptySampler, cx, 0), 0, "placements")
		end
	end)
end
