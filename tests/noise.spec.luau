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

	test("simplex2d matches simplex2 and its derivatives match finite differences", function()
		local plain, derived = Noise.simplex2(31, 4), Noise.simplex2d(31, 4)
		local e = 1e-5
		for i = 1, 2000 do
			local x, y = i * 0.0137 - 9, i * -0.0091 + 4
			local v, dx, dy = derived(x, y)
			expect.equal(v, plain(x, y), "value")
			expect.near(dx, (plain(x + e, y) - plain(x - e, y)) / (2 * e), 1e-4, "d/dx")
			expect.near(dy, (plain(x, y + e) - plain(x, y - e)) / (2 * e), 1e-4, "d/dy")
		end
	end)

	test("eroded fractals stay in range and are continuous", function()
		local n = Noise.simplex2d(99, 1)
		for i = 1, 2000 do
			local x, y = i * 0.0731, i * 0.0517
			local f = Noise.erodedFbm(n, x, y, 5, 0.3)
			local r = Noise.erodedRidged(n, x, y, 6, 0.3)
			expect.between(f, -1, 1, "erodedFbm")
			expect.between(r, 0, 1, "erodedRidged")
			-- A step of 1e-4 noise units is a fraction of a stud at terrain scales.
			expect.truthy(math.abs(Noise.erodedFbm(n, x + 1e-4, y, 5, 0.3) - f) < 0.01, "erodedFbm jump")
			expect.truthy(math.abs(Noise.erodedRidged(n, x + 1e-4, y, 6, 0.3) - r) < 0.01, "erodedRidged jump")
		end
	end)

	test("simplex3 is seeded, in range and continuous", function()
		local a, b, c = Noise.simplex3(7, 1), Noise.simplex3(7, 1), Noise.simplex3(8, 1)
		local sum, lo, hi, differences = 0, math.huge, -math.huge, 0
		local count = 20000
		for i = 1, count do
			local x, y, z = (i % 37) * 0.413 - 7, (i // 37 % 23) * -0.377, (i // 851) * 0.291 + 3
			local v = a(x, y, z)
			expect.equal(v, b(x, y, z), "same seed")
			if v ~= c(x, y, z) then
				differences += 1
			end
			sum += v
			lo, hi = math.min(lo, v), math.max(hi, v)
			-- Kernels that leak across simplex borders show up as jumps here.
			expect.truthy(math.abs(a(x + 1e-4, y, z) - v) < 0.01, "jump")
			expect.between(Noise.fbm3(a, x, y, z, 3), -1, 1, "fbm3")
		end
		expect.truthy(differences > count * 0.95, "different seeds give different noise")
		expect.between(lo, -1.001, -0.5, "min")
		expect.between(hi, 0.5, 1.001, "max")
		expect.near(sum / count, 0, 0.05, "mean")
	end)

	test("erosion removes ridged detail without lowering the peaks", function()
		local n = Noise.simplex2d(5, 2)
		local plainMax, erodedMax = 0, 0
		for i = 1, 20000 do
			local x, y = (i % 200) * 0.0731, (i // 200) * 0.0517
			plainMax = math.max(plainMax, Noise.erodedRidged(n, x, y, 6, 0))
			erodedMax = math.max(erodedMax, Noise.erodedRidged(n, x, y, 6, 0.3))
		end
		expect.truthy(erodedMax >= plainMax * 0.95, `peaks {erodedMax} vs {plainMax}`)
	end)
end
