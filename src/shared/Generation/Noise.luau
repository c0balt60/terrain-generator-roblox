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
local F3 = 1 / 3
local G3 = 1 / 6

-- 12 gradient directions (the cube's edge midpoints). 2D noise uses the x and y components.
local GRAD_X = { 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0 }
local GRAD_Y = { 1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1 }
local GRAD_Z = { 0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1 }

-- Brings the 3D sum back to [-1, 1]: the measured raw peak is about 0.013.
local SIMPLEX3_SCALE = 76

export type Noise2 = (x: number, y: number) -> number
export type Noise3 = (x: number, y: number, z: number) -> number
-- Noise value plus its partial derivatives with respect to x and y.
export type Noise2D = (x: number, y: number) -> (number, number, number)

local Noise = {}

-- Octaves are rotated by this angle (a 3-4-5 triangle) so their lattices don't line up.
local ROT_C, ROT_S = 0.8, 0.6

-- Shuffled permutation for one (seed, salt): perm[k + 1] and its gradient index, k in [0, 511].
local function permutation(seed: number, salt: number): ({ number }, { number })
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
	return perm, permGrad
end

-- Returns a noise function in roughly [-1, 1]. Same (seed, salt) -> same function.
function Noise.simplex2(seed: number, salt: number): Noise2
	local perm, permGrad = permutation(seed, salt)

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

--[[
	Same noise as `simplex2` for the same (seed, salt), plus its analytic
	derivatives. Each corner contributes t^4 * (g . d) with t = 0.5 - |d|^2,
	so its gradient is t^4 * g - 8 t^3 * (g . d) * d.
]]
function Noise.simplex2d(seed: number, salt: number): Noise2D
	local perm, permGrad = permutation(seed, salt)

	return function(xin: number, yin: number): (number, number, number)
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

		local n, dx, dy = 0, 0, 0

		local t0 = 0.5 - x0 * x0 - y0 * y0
		if t0 > 0 then
			local g = permGrad[ii + perm[jj + 1] + 1]
			local gx, gy = GRAD_X[g], GRAD_Y[g]
			local gd = gx * x0 + gy * y0
			local t2 = t0 * t0
			local t4 = t2 * t2
			local k = -8 * t2 * t0 * gd
			n += t4 * gd
			dx += k * x0 + t4 * gx
			dy += k * y0 + t4 * gy
		end

		local t1 = 0.5 - x1 * x1 - y1 * y1
		if t1 > 0 then
			local g = permGrad[ii + i1 + perm[jj + j1 + 1] + 1]
			local gx, gy = GRAD_X[g], GRAD_Y[g]
			local gd = gx * x1 + gy * y1
			local t2 = t1 * t1
			local t4 = t2 * t2
			local k = -8 * t2 * t1 * gd
			n += t4 * gd
			dx += k * x1 + t4 * gx
			dy += k * y1 + t4 * gy
		end

		local t2c = 0.5 - x2 * x2 - y2 * y2
		if t2c > 0 then
			local g = permGrad[ii + 1 + perm[jj + 2] + 1]
			local gx, gy = GRAD_X[g], GRAD_Y[g]
			local gd = gx * x2 + gy * y2
			local t2 = t2c * t2c
			local t4 = t2 * t2
			local k = -8 * t2 * t2c * gd
			n += t4 * gd
			dx += k * x2 + t4 * gx
			dy += k * y2 + t4 * gy
		end

		return 70 * n, 70 * dx, 70 * dy
	end
end

--[[
	Seeded 3D simplex noise in roughly [-1, 1]. Kernel radius^2 is 0.5 rather than
	the 0.6 of the reference code, because 0.6 leaks across simplex borders and
	leaves faint seams.
]]
function Noise.simplex3(seed: number, salt: number): Noise3
	local perm, permGrad = permutation(seed, salt)

	local function corner(g: number, x: number, y: number, z: number): number
		local t = 0.5 - x * x - y * y - z * z
		if t <= 0 then
			return 0
		end
		t *= t
		return t * t * (GRAD_X[g] * x + GRAD_Y[g] * y + GRAD_Z[g] * z)
	end

	return function(xin: number, yin: number, zin: number): number
		local s = (xin + yin + zin) * F3
		local i = math.floor(xin + s)
		local j = math.floor(yin + s)
		local k = math.floor(zin + s)
		local t = (i + j + k) * G3
		local x0 = xin - (i - t)
		local y0 = yin - (j - t)
		local z0 = zin - (k - t)

		-- Which of the six tetrahedra in the skewed cube holds the point.
		local i1, j1, k1, i2, j2, k2
		if x0 >= y0 then
			if y0 >= z0 then
				i1, j1, k1, i2, j2, k2 = 1, 0, 0, 1, 1, 0
			elseif x0 >= z0 then
				i1, j1, k1, i2, j2, k2 = 1, 0, 0, 1, 0, 1
			else
				i1, j1, k1, i2, j2, k2 = 0, 0, 1, 1, 0, 1
			end
		else
			if y0 < z0 then
				i1, j1, k1, i2, j2, k2 = 0, 0, 1, 0, 1, 1
			elseif x0 < z0 then
				i1, j1, k1, i2, j2, k2 = 0, 1, 0, 0, 1, 1
			else
				i1, j1, k1, i2, j2, k2 = 0, 1, 0, 1, 1, 0
			end
		end

		local ii = i % 256
		local jj = j % 256
		local kk = k % 256

		local n = corner(permGrad[ii + perm[jj + perm[kk + 1] + 1] + 1], x0, y0, z0)
		n += corner(
			permGrad[ii + i1 + perm[jj + j1 + perm[kk + k1 + 1] + 1] + 1],
			x0 - i1 + G3,
			y0 - j1 + G3,
			z0 - k1 + G3
		)
		n += corner(
			permGrad[ii + i2 + perm[jj + j2 + perm[kk + k2 + 1] + 1] + 1],
			x0 - i2 + 2 * G3,
			y0 - j2 + 2 * G3,
			z0 - k2 + 2 * G3
		)
		n += corner(
			permGrad[ii + 1 + perm[jj + 1 + perm[kk + 2] + 1] + 1],
			x0 - 1 + 3 * G3,
			y0 - 1 + 3 * G3,
			z0 - 1 + 3 * G3
		)
		return SIMPLEX3_SCALE * n
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

-- 3D fbm, normalised back to roughly [-1, 1].
function Noise.fbm3(noise: Noise3, x: number, y: number, z: number, octaves: number): number
	local sum = 0
	local amplitude = 1
	local frequency = 1
	local total = 0
	for _ = 1, octaves do
		sum += noise(x * frequency, y * frequency, z * frequency) * amplitude
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

--[[
	Eroded fbm in roughly [-1, 1]. Every octave is damped by the slope the
	octaves so far have built up (1 / (1 + erosion * |slope|^2)), so fine
	detail settles on flats and crests while steep flanks stay smooth and pick
	up streaks running downhill, which reads as weathering. Octaves average
	zero, so damping them removes detail without shifting the height.

	Octaves are rotated against each other; the accumulated slope is rotated
	back into world orientation so directions agree between octaves.
]]
function Noise.erodedFbm(noise: Noise2D, x: number, y: number, octaves: number, erosion: number): number
	local sum, total = 0, 0
	local amplitude = 1
	local dx, dy = 0, 0
	local px, py = x, y
	local c, s = 1, 0
	for _ = 1, octaves do
		local n, gx, gy = noise(px, py)
		dx += c * gx + s * gy
		dy += c * gy - s * gx
		sum += amplitude * n / (1 + erosion * (dx * dx + dy * dy))
		total += amplitude
		amplitude *= 0.5
		px, py = (ROT_C * px - ROT_S * py) * 2, (ROT_S * px + ROT_C * py) * 2
		c, s = ROT_C * c - ROT_S * s, ROT_S * c + ROT_C * s
	end
	return sum / total
end

--[[
	Eroded ridged multifractal in [0, 1]. Like `ridged`, each octave is weighted
	by the previous signal so detail gathers along crests. Each octave is also
	damped by the slope of the octaves before it (not its own, which would flatten
	the main crest), giving sharp, craggy ridges with smooth flanks.

	The slope is accumulated as squared magnitudes. Ridges have a kink on the
	crest, so their slope direction flips there; summing directions would make
	the damping collapse along every crest line and the height jump around it.

	Ridged octaves don't average zero, so a damped octave fades toward the
	previous octave's signal rather than toward 0. That removes its detail
	without lowering the peaks.
]]
function Noise.erodedRidged(noise: Noise2D, x: number, y: number, octaves: number, erosion: number): number
	local sum, total = 0, 0
	local amplitude = 0.5
	local weight = 1
	local previous = 0
	local slope2 = 0
	local px, py = x, y
	for octave = 1, octaves do
		local n, gx, gy = noise(px, py)
		local ridge = 1 - math.abs(n)
		local signal = ridge * ridge * weight
		local kept = if octave == 1 then signal else previous + (signal - previous) / (1 + erosion * slope2)
		sum += amplitude * kept
		total += amplitude
		previous = kept

		-- |d(ridge^2)| = 2 * ridge * |dn|, scaled by this octave's weight.
		local k = 2 * ridge * weight
		slope2 += k * k * (gx * gx + gy * gy)
		weight = math.clamp(signal * 2, 0, 1)

		amplitude *= 0.5
		px, py = (ROT_C * px - ROT_S * py) * 2, (ROT_S * px + ROT_C * py) * 2
	end
	return sum / total
end

return Noise
