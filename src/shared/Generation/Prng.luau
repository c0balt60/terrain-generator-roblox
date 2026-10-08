--!strict
--[[
	Deterministic Park-Miller (MINSTD) generator.

	Roblox's `Random` doesn't exist in Lune, and the tests need byte-identical
	output on both, so seeding goes through this instead. The largest
	intermediate product (2^31 * 48271) stays well under 2^53, so plain doubles
	are exact.
]]

local MODULUS = 2147483647
local MULTIPLIER = 48271

local Prng = {}

export type Prng = {
	nextInt: (self: Prng, n: number) -> number,
	nextNumber: (self: Prng) -> number,
	_state: number,
}

local function step(state: number): number
	return (state * MULTIPLIER) % MODULUS
end

-- Folds an arbitrary integer seed and a salt into a valid non-zero state, so
-- each noise channel derived from one world seed gets an independent stream.
function Prng.hash(seed: number, salt: number): number
	local state = (math.floor(seed) + math.floor(salt) * 1013904223) % (MODULUS - 1) + 1
	for _ = 1, 4 do
		state = step(state)
	end
	return state
end

local methods = {}

-- Uniform integer in [0, n).
function methods.nextInt(self: Prng, n: number): number
	self._state = step(self._state)
	return self._state % n
end

-- Uniform float in [0, 1).
function methods.nextNumber(self: Prng): number
	self._state = step(self._state)
	return (self._state - 1) / (MODULUS - 1)
end

function Prng.new(seed: number, salt: number?): Prng
	local self = {
		_state = Prng.hash(seed, salt or 0),
	}
	return (setmetatable(self, { __index = methods }) :: any) :: Prng
end

return Prng
