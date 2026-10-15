--!strict

local Check = require("../support/check")
local Limits = require("../../src/wire/limits")

local NAN = 0 / 0
local INFINITY = math.huge

local function toF32(x: number): number
	local bytes = buffer.create(4)
	buffer.writef32(bytes, 0, x)

	return buffer.readf32(bytes, 0)
end

-- The next f32 above `m`, from its bit pattern.
local function nextF32(m: number): number
	local bytes = buffer.create(4)
	buffer.writef32(bytes, 0, m)
	buffer.writeu32(bytes, 0, buffer.readu32(bytes, 0) + 1)

	return buffer.readf32(bytes, 0)
end

return {
	["holds the t.int() range"] = function()
		Check.expectEqual(Limits.INT_MIN, -4503599627370496)
		Check.expectEqual(Limits.INT_MAX, 4503599627370495)
		Check.expect(Limits.isInteger(Limits.INT_MIN), "INT_MIN is an integer")
		Check.expect(Limits.isInteger(Limits.INT_MAX), "INT_MAX is an integer")
	end,

	["tests integers at the boundaries, ±0, NaN and ±inf"] = function()
		for _, x in { 0, -0, 1, -1, 2 ^ 53, -(2 ^ 53), 2 ^ 1000 } do
			Check.expect(Limits.isInteger(x), `{x} is an integer`)
		end
		for _, x in { 0.5, -0.5, 2 ^ 52 - 0.5, 1e-300, NAN, INFINITY, -INFINITY } do
			Check.expect(not Limits.isInteger(x), `{x} is not an integer`)
		end
	end,

	["tests finiteness at ±0, NaN and ±inf"] = function()
		for _, x in { 0, -0, 1e308, -1e308, 5e-324, 2 ^ 52 } do
			Check.expect(Limits.isFinite(x), `{x} is finite`)
		end
		for _, x in { NAN, -NAN, INFINITY, -INFINITY } do
			Check.expect(not Limits.isFinite(x), `{x} is not finite`)
		end
	end,

	["gives the f32 spacing at powers of two and between them"] = function()
		Check.expectEqual(Limits.f32Spacing(1), 2 ^ -23)
		Check.expectEqual(Limits.f32Spacing(2 - 2 ^ -52), 2 ^ -23)
		Check.expectEqual(Limits.f32Spacing(2), 2 ^ -22)
		Check.expectEqual(Limits.f32Spacing(3), 2 ^ -22)
		Check.expectEqual(Limits.f32Spacing(2 ^ 24), 2)
		Check.expectEqual(Limits.f32Spacing(2048), 2 ^ -12)
		Check.expectEqual(Limits.f32Spacing(-2048), 2 ^ -12)
		Check.expectEqual(Limits.f32Spacing(0.1), 2 ^ -27)
		Check.expectEqual(Limits.f32Spacing(0), 0)
		Check.expectEqual(Limits.f32Spacing(-0), 0)
	end,

	["agrees with the gap to the next f32"] = function()
		for exponent = -100, 100 do
			for _, fraction in { 1, 1.25, 1.5, 1.9999 } do
				local m = toF32(fraction * 2 ^ exponent)
				Check.expectEqual(nextF32(m) - m, Limits.f32Spacing(m), `at {m}`)
			end
		end
	end,
}
