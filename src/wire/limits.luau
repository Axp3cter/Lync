--!strict

--[=[
	Limits

	The numeric limits and tests that every layer shares, kept in one copy (m1-plan.md §7.1 A6):
	the `t.int()` range, the f32 spacing that `t.vector3`'s rules use (v5.md §3.3), and integer and
	finiteness tests.
]=]

-- Module ------------------------------------------------------------------------------------------

local Limits = {}

-- Constants ---------------------------------------------------------------------------------------

const F32_MANTISSA_BITS = 23

-- Public ------------------------------------------------------------------------------------------

--- The greatest `t.int()` value, 2^52 - 1 (v5.md §3.3).
Limits.INT_MAX = 2 ^ 52 - 1

--- The least `t.int()` value, -2^52 (v5.md §3.3).
Limits.INT_MIN = -2 ^ 52

--[=[
	Returns the f32 spacing at a magnitude: the gap between f32 values at and just above it.

	`math.frexp` gives m = f × 2^e with f in [0.5, 1), so floor(log2 |m|) = e - 1, exactly.

	@param  m a finite number; its sign is ignored
	@return 2^(floor(log2 |m|) - 23), or 0 when `m` is 0
]=]
function Limits.f32Spacing(m: number): number
	if m == 0 then
		return 0
	end

	local _, exponent = math.frexp(m)
	return math.ldexp(1, exponent - 1 - F32_MANTISSA_BITS)
end

--[=[
	Returns whether a number is finite.

	@param  x the number
	@return false for NaN and ±infinity
]=]
function Limits.isFinite(x: number): boolean
	-- selene's standard library predates math.isfinite.
	-- selene: allow(incorrect_standard_library_use)
	return math.isfinite(x)
end

--[=[
	Returns whether a number is a finite integer.

	@param  x the number
	@return true when `x` is finite and has no fraction; -0 is an integer
]=]
function Limits.isInteger(x: number): boolean
	-- selene: allow(incorrect_standard_library_use)
	return math.isfinite(x) and math.floor(x) == x
end

return table.freeze(Limits)
