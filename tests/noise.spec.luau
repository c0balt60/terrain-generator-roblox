local Noise = require("@generation/Noise")
local Prng = require("@generation/Prng")
local expect = require("./expect")

return function(test)
	test("prng is deterministic and in range", function()
		local a, b = Prng.new(42, 1), Prng.new(42, 1)
		for _ = 1, 1000 do
			local x = a:nextNumber()
			expect.equal(x, b:nextNumber(), "same seed")
			expect.between(x, 0, 1, "nextNumber")
		end
		expect.truthy(Prng.new(42, 1):nextInt(1e6) ~= Prng.new(42, 2):nextInt(1e6), "salt changes stream")
	end)

	test("simplex is deterministic per seed and differs across seeds", function()
		local a, b, c = Noise.simplex2(7, 1), Noise.simplex2(7, 1), Noise.simplex2(8, 1)
		local differences = 0
		for i = 1, 200 do
			local x, y = i * 0.37, i * -0.91
			expect.equal(a(x, y), b(x, y), "same seed")
			if a(x, y) ~= c(x, y) then
				differences += 1
			end
		end
		expect.truthy(differences > 190, "different seeds give different noise")
	end)

	test("simplex stays in [-1, 1] with roughly zero mean", function()
		local n = Noise.simplex2(123, 1)
		local sum, lo, hi = 0, math.huge, -math.huge
		local count = 0
		for i = -100, 100 do
			for j = -100, 100 do
				local v = n(i * 0.173, j * 0.191)
				sum += v
				lo, hi = math.min(lo, v), math.max(hi, v)
				count += 1
			end
		end
		expect.between(lo, -1.001, -0.5, "min")
		expect.between(hi, 0.5, 1.001, "max")
		expect.near(sum / count, 0, 0.05, "mean")
	end)

	test("simplex handles negative coordinates and integer lattice points", function()
		local n = Noise.simplex2(5, 3)
		expect.equal(n(0, 0), 0, "origin")
		for i = -50, 50 do
			local v = n(i, -i * 2)
			expect.truthy(v == v, "not NaN")
		end
	end)

	test("fbm and ridged stay in range", function()
		local n = Noise.simplex2(99, 1)
		for i = 1, 2000 do
			local x, y = i * 0.0731, i * 0.0517
			expect.between(Noise.fbm(n, x, y, 5), -1, 1, "fbm")
			expect.between(Noise.ridged(n, x, y, 5), 0, 1, "ridged")
		end
	end)
end
