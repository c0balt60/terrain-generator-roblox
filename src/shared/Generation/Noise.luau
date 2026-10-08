--!strict
--!native
--!optimize 2
--[[
	Seeded 2D simplex noise (Gustavson's reference layout) plus fractal helpers.

	`math.noise` is fixed-permutation Perlin: "seeding" it means offsetting the
	input, which gives the same world shifted rather than a new one. A shuffled
	permutation table per channel does give independent worlds per seed.

	All functions are pure and allocation-free after construction, so they are
	safe to call from parallel Luau and from Lune.
]]

local Prng = require("./Prng")

local F2 = 0.5 * (math.sqrt(3) - 1)
local G2 = (3 - math.sqrt(3)) / 6

-- 12 gradient directions, x and y components.
local GRAD_X = { 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0 }
local GRAD_Y = { 1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1 }

export type Noise2 = (x: number, y: number) -> number

local Noise = {}

-- Returns a noise function in roughly [-1, 1]. Same (seed, salt) -> same function.
function Noise.simplex2(seed: number, salt: number): Noise2
	local rng = Prng.new(seed, salt)

	local source = table.create(256, 0)
	for i = 1, 256 do
		source[i] = i - 1
	end
	for i = 256, 2, -1 do
		local j = rng:nextInt(i) + 1
		source[i], source[j] = source[j], source[i]
	end

	-- perm[k] for k in [0, 511], stored 1-based as perm[k + 1].
	local perm = table.create(512, 0)
	local permGrad = table.create(512, 0)
	for k = 0, 511 do
		local value = source[(k % 256) + 1]
		perm[k + 1] = value
		permGrad[k + 1] = (value % 12) + 1
	end

	return function(xin: number, yin: number): number
		local s = (xin + yin) * F2
		local i = math.floor(xin + s)
		local j = math.floor(yin + s)
		local t = (i + j) * G2
		local x0 = xin - (i - t)
		local y0 = yin - (j - t)

		local i1, j1
		if x0 > y0 then
			i1, j1 = 1, 0
		else
			i1, j1 = 0, 1
		end

		local x1 = x0 - i1 + G2
		local y1 = y0 - j1 + G2
		local x2 = x0 - 1 + 2 * G2
		local y2 = y0 - 1 + 2 * G2

		local ii = i % 256
		local jj = j % 256

		local n = 0

		local t0 = 0.5 - x0 * x0 - y0 * y0
		if t0 > 0 then
			local g = permGrad[ii + perm[jj + 1] + 1]
			t0 *= t0
			n += t0 * t0 * (GRAD_X[g] * x0 + GRAD_Y[g] * y0)
		end

		local t1 = 0.5 - x1 * x1 - y1 * y1
		if t1 > 0 then
			local g = permGrad[ii + i1 + perm[jj + j1 + 1] + 1]
			t1 *= t1
			n += t1 * t1 * (GRAD_X[g] * x1 + GRAD_Y[g] * y1)
		end

		local t2 = 0.5 - x2 * x2 - y2 * y2
		if t2 > 0 then
			local g = permGrad[ii + 1 + perm[jj + 2] + 1]
			t2 *= t2
			n += t2 * t2 * (GRAD_X[g] * x2 + GRAD_Y[g] * y2)
		end

		return 70 * n
	end
end

-- Fractal Brownian motion, normalised back to roughly [-1, 1].
function Noise.fbm(noise: Noise2, x: number, y: number, octaves: number): number
	local sum = 0
	local amplitude = 1
	local frequency = 1
	local total = 0
	for _ = 1, octaves do
		sum += noise(x * frequency, y * frequency) * amplitude
		total += amplitude
		amplitude *= 0.5
		frequency *= 2
	end
	return sum / total
end

-- Ridged multifractal in [0, 1]: sharp crests where the base noise crosses zero.
-- Each octave is weighted by the previous one so detail gathers on the ridges.
function Noise.ridged(noise: Noise2, x: number, y: number, octaves: number): number
	local sum = 0
	local amplitude = 0.5
	local frequency = 1
	local weight = 1
	local total = 0
	for _ = 1, octaves do
		local signal = 1 - math.abs(noise(x * frequency, y * frequency))
		signal *= signal * weight
		weight = math.clamp(signal * 2, 0, 1)
		sum += signal * amplitude
		total += amplitude
		amplitude *= 0.5
		frequency *= 2
	end
	return sum / total
end

return Noise
