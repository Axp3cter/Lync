--!strict

--[=[
	vector3.spec

	The `t.vector3` f32 rule (v5.md §3.3): positions are stored in f32, so a component up to the
	f32 spacing at a bound past it, 2^(floor(log2 |bound|) - 23), takes the end code, and every
	decoded component re-quantizes to its own code. This holds for `t.cframe` positions too.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Frame = require("../support/frame")
local Gen = require("../support/gen")
local Ir = require("../../src/plan/ir")
local Leaves = require("../../src/codec/leaves")
local Lync = require("../../src")
local Quant = require("../../src/wire/quant")
local Rows = require("../../src/codec/rows")

-- Constants ---------------------------------------------------------------------------------------

const INTERIOR_CODES = 10_000

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

-- Bounds that are not f32 values, bounds at zero, and wide ranges with fine steps.
local function axesOf(): { [string]: Ir.NumberCodec }
	local declared = {
		["(-0.1, 0.1, 0.001)"] = t.vector3(-0.1, 0.1, 0.001),
		["(-2048, 2048, 1/32)"] = t.vector3(-2048, 2048, 1 / 32),
		["(-1e5, 1e5, 0.05)"] = t.vector3(-1e5, 1e5, 0.05),
		["(0, 3, 0.1)"] = t.vector3(0, 3, 0.1),
		["(-7.3, 1000, 0.01)"] = t.vector3(-7.3, 1000, 0.01),
		["(1/3, 2/3, 1/3000)"] = t.vector3(1 / 3, 2 / 3, 1 / 3000),
	}

	local axes = {}
	for name, codec in declared do
		axes[name] = (Gen.plan(codec) :: any).axis
	end

	return axes
end

local function spacingAt(bound: number): number
	if bound == 0 then
		return 0
	end

	local _, exponent = math.frexp(bound)
	return 2 ^ (exponent - 24)
end

local function newInstances(): Rows.Instances
	return { list = {}, index = {}, count = 0 }
end

-- Decodes a code into a Vector3 component, stored in f32, and returns the code it re-encodes to.
local function recoded(axis: Ir.NumberCodec, code: number): number?
	local component = Vector3.new(Quant.unnumber(code, axis.min, axis.step, axis.max), 0, 0).X

	return (Leaves.vector3Codes(component, component, component, axis))
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["every code at the bounds and random interior codes re-encode to themselves"] = function()
		math.randomseed(32)
		for name, axis in axesOf() do
			local n = axis.steps
			for _, code in { 0, 1, n - 1, n } do
				Check.expectEqual(recoded(axis, code), code, `{name}, code {code}`)
			end

			for _ = 1, INTERIOR_CODES do
				local code = math.random(1, n - 1)
				Check.expectEqual(recoded(axis, code), code, `{name}, code {code}`)
			end
		end
	end,

	["a component one f32 spacing past a bound takes the end code"] = function()
		for name, axis in axesOf() do
			local minSpacing, maxSpacing = spacingAt(axis.min), spacingAt(axis.max)
			local below = Leaves.vector3Codes(axis.min - minSpacing, axis.min, axis.min, axis)
			local above = Leaves.vector3Codes(axis.max + maxSpacing, axis.max, axis.max, axis)
			Check.expectEqual(below, 0, `{name}: below min`)
			Check.expectEqual(above, axis.steps, `{name}: above max`)

			local farBelow = axis.min - 2 * minSpacing
			local farAbove = axis.max + 2 * maxSpacing
			if farBelow ~= axis.min then
				Check.expectEqual(
					Leaves.vector3Codes(farBelow, axis.min, axis.min, axis),
					nil,
					`{name}: far below`
				)
			end
			Check.expectEqual(
				Leaves.vector3Codes(farAbove, axis.max, axis.max, axis),
				nil,
				`{name}: far above`
			)
		end
	end,

	["a Vector3 at a bound that is not an f32 value round trips"] = function()
		local codec = Gen.plan(t.vector3(-0.1, 0.1, 0.001))
		local value = Vector3.new(0.1, -0.1, 0.1)
		Check.expect(value.X > 0.1, "f32 0.1 must lie above 0.1")

		local decoded = Frame.decodeRun(Frame.encodeRun(codec, { value }, 1), codec, 1, {})
		Check.expectEqual(decoded.rule, 0, "rule")
		Check.expectEqual(decoded.values[1], value, "decoded")
	end,

	["a t.cframe position takes the end code within the f32 spacing"] = function()
		local codec = Gen.plan(t.cframe(t.vector3(-0.1, 0.1, 0.001), t.rotation(9)))
		local value = CFrame.new(0.1, -0.1, 0)
		local w = Bits.writer()
		Rows.encodeValue(w, codec, value, newInstances(), "arena.test:fire", "data")
		local r = Bits.reader(Bits.finish(w))
		local decoded, rule = Rows.read(r, codec, Rows.beginChunk({}, 0, 0), 1, {})
		Check.expectEqual(rule, 0, "rule")
		Check.expectEqual(decoded, value, "decoded")

		Check.expectThrow(function()
			Rows.encodeValue(
				Bits.writer(),
				codec,
				CFrame.new(0.1001, 0, 0),
				newInstances(),
				"a.b",
				"data"
			)
		end, { code = "valueRefused", path = "data.position" })
	end,
}
