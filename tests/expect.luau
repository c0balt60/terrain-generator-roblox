-- Minimal assertions for the spec files. Each raises with a readable message.

local expect = {}

function expect.equal<T>(actual: T, expected: T, what: string?)
	if actual ~= expected then
		error(`{what or "value"}: expected {expected}, got {actual}`, 2)
	end
end

function expect.near(actual: number, expected: number, tolerance: number, what: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{what or "value"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

function expect.between(actual: number, min: number, max: number, what: string?)
	if actual < min or actual > max then
		error(`{what or "value"}: expected within [{min}, {max}], got {actual}`, 2)
	end
end

function expect.truthy(value: any, what: string?)
	if not value then
		error(`{what or "value"}: expected truthy, got {value}`, 2)
	end
end

return expect
