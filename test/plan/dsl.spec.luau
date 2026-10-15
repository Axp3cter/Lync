--!strict

--[=[
	dsl.spec

	The codec and definition constructors: the values they build, and the declaration errors they
	raise at their own line.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Dsl = require("../../src/plan/dsl")
local Lync = require("../../src")

-- Constants ---------------------------------------------------------------------------------------

const SOURCE = debug.info(1, "s")

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function at(line: number): string
	return `{SOURCE}:{line}`
end

local function codecOf(definitions: { [string]: any }): any
	return Lync.schema("dsl", definitions).ir.byName.value.data
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["a codec records the line its constructor was called from"] = function()
		local line = debug.info(1, "l")
		local codec = t.int(0, 3) :: any

		Check.expectEqual(codec.line, line + 1)
		Check.expectEqual(codec.source, SOURCE)
	end,

	["a multi-line call records its first line"] = function()
		local line = debug.info(1, "l")
		local codec = t.number(0, 1, 0.25) :: any

		Check.expectEqual(codec.line, line + 1)
	end,

	[":newest() returns a marked copy and leaves the codec unmarked"] = function()
		local codec = t.bool() :: any
		local marked = codec:newest()

		Check.expect(Dsl.isCodec(marked), "the copy must be a codec")
		Check.expect(marked.isNewest, "the copy must be marked")
		Check.expect(not codec.isNewest, "the original must stay unmarked")
		Check.expectEqual(marked.line, codec.line)
	end,

	["isCodec: codecs only, not records or declarations"] = function()
		Check.expect(Dsl.isCodec(t.f32()), "t.f32() must be a codec")
		Check.expect(not Dsl.isCodec({ a = t.f32() }), "a record must not be a codec")
		Check.expect(
			not Dsl.isCodec(Lync.event({ from = "client" })),
			"an event must not be a codec"
		)
		Check.expect(not Dsl.isCodec(nil), "nil must not be a codec")
	end,

	["codec values are frozen"] = function()
		Check.expect(table.isfrozen(t.string(4) :: any), "a codec must be frozen")
	end,

	["t.int() is the unbounded integer"] = function()
		local codec = codecOf({ value = Lync.event({ from = "client", data = t.int() }) })

		Check.expectEqual(codec.kind, "varint")
	end,

	["t.int(5, 5) and a one-item enum are zero bits wide"] = function()
		local ir = Lync.schema("dsl", {
			one = Lync.event({
				from = "client",
				data = { a = t.int(5, 5), b = t.enum({ "only" }) },
			}),
		}).ir

		Check.expectEqual(ir.byName.one.dataMaxBits, 0)
	end,

	["t.number(0, 0.3, 0.1) has 3 steps"] = function()
		local codec =
			codecOf({ value = Lync.event({ from = "client", data = t.number(0, 0.3, 0.1) }) })

		Check.expectEqual(codec.steps, 3)
		Check.expectEqual(codec.width, 2)
	end,

	["t.angle(2 * pi / 1000) has 1000 steps"] = function()
		local codec =
			codecOf({ value = Lync.event({ from = "client", data = t.angle(2 * math.pi / 1000) }) })

		Check.expectEqual(codec.steps, 1000)
		Check.expectEqual(codec.width, 10)
	end,

	["t.enum of a list keeps list order, indexed from 0"] = function()
		local codec =
			codecOf({ value = Lync.event({ from = "client", data = t.enum({ "b", "a", "c" }) }) })

		Check.expectEqual(codec.items, { "b", "a", "c" })
		Check.expectEqual(codec.index, { b = 0, a = 1, c = 2 })
		Check.expectEqual(codec.width, 2)
	end,

	["t.enum of a Roblox Enum maps values to items"] = function()
		local codec =
			codecOf({ value = Lync.event({ from = "client", data = t.enum(Enum.Material) }) })

		Check.expectEqual(codec.kind, "robloxEnum")
		Check.expectEqual(codec.name, "Material")
		Check.expect(codec.byValue[Enum.Material.Plastic.Value] == Enum.Material.Plastic, "Plastic")
	end,

	["intBounds: min above max"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.int(10, 1)
		end, { code = "intBounds", at = at(line + 2), subject = "t.int" })
	end,

	["intBounds: a fractional bound"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.int(0.5, 2)
		end, { code = "intBounds", at = at(line + 2) })
	end,

	["intBounds: a bound past 2^52 - 1, or a missing max"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.int(0, 2 ^ 52)
		end, { code = "intBounds", at = at(line + 2) })
		Check.expectThrow(function()
			t.int(0)
		end, { code = "intBounds", at = at(line + 5) })
	end,

	["numberStep: a step that does not divide the range"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.number(0, 1, 0.35)
		end, { code = "numberStep", at = at(line + 2), subject = "t.number" })
	end,

	["numberStep: t.vector3 shares the rule"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.vector3(0, 1, 0.35)
		end, { code = "numberStep", at = at(line + 2), subject = "t.vector3" })
	end,

	["vectorStep: the boundary, the largest refused and the smallest accepted step"] = function()
		-- Each case: bounds whose larger magnitude M gives the f32 spacing 2^(floor(log2 M) - 23),
		-- which divides max - min into N steps; the next larger step that divides it is
		-- (max - min) / (N - 1).
		local cases = {
			{ min = -2048, max = 2048, spacing = 2 ^ -12 },
			{ min = 0, max = 1024, spacing = 2 ^ -13 },
			{ min = 0, max = 1, spacing = 2 ^ -23 },
			{ min = -1000, max = 1000, spacing = 2 ^ -14 },
			{ min = -3, max = 0.5, spacing = 2 ^ -22 },
		}

		for _, case in cases do
			local range = case.max - case.min
			local acceptedStep = range / (range / case.spacing - 1)
			local line = debug.info(1, "l")
			Check.expectThrow(function()
				t.vector3(case.min, case.max, case.spacing)
			end, { code = "vectorStep", at = at(line + 2), subject = "t.vector3" })

			local codec = t.vector3(case.min, case.max, acceptedStep) :: any
			Check.expectEqual(codec.node.steps, range / case.spacing - 1, `steps for {case.max}`)
		end
	end,

	["vectorStep: a t.cframe position, at the t.vector3 line"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.cframe(t.vector3(-2048, 2048, 2 ^ -12), t.rotation(9))
		end, { code = "vectorStep", at = at(line + 2), subject = "t.vector3" })
	end,

	["optionalPlacement: an optional in an optional, as an element or as a map value"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.optional(t.optional(t.bool()))
		end, { code = "optionalPlacement", at = at(line + 2), subject = "t.optional" })
		Check.expectThrow(function()
			t.array(t.optional(t.bool()), 4)
		end, { code = "optionalPlacement", at = at(line + 5), subject = "t.array" })
		Check.expectThrow(function()
			t.map(t.string(4), t.optional(t.bool()), 4)
		end, { code = "optionalPlacement", at = at(line + 8), subject = "t.map" })
	end,

	["an optional inside a record inside an array is allowed"] = function()
		local codec = t.array({ title = t.optional(t.string(4)) }, 4) :: any

		Check.expectEqual(codec.node.kind, "array")
	end,

	["numberStepIsInt: step 1 with an integer min"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.number(0, 10, 1)
		end, { code = "numberStepIsInt", at = at(line + 2), subject = "t.number" })
	end,

	["paramRange: lengths, counts and bit counts out of range"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.string(0)
		end, { code = "paramRange", at = at(line + 2), subject = "t.string" })
		Check.expectThrow(function()
			t.array(t.bool(), 70_000)
		end, { code = "paramRange", at = at(line + 5), subject = "t.array" })
		Check.expectThrow(function()
			t.direction(7)
		end, { code = "paramRange", at = at(line + 8), subject = "t.direction" })
		Check.expectThrow(function()
			t.rotation(16)
		end, { code = "paramRange", at = at(line + 11), subject = "t.rotation" })
	end,

	["paramRange: non-finite numbers and non-positive steps"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.number(0, math.huge, 1)
		end, { code = "paramRange", at = at(line + 2), subject = "t.number" })
		Check.expectThrow(function()
			t.angle(0)
		end, { code = "paramRange", at = at(line + 5), subject = "t.angle" })
		Check.expectThrow(function()
			t.number(0, 0 / 0, 0.5)
		end, { code = "paramRange", at = at(line + 8), subject = "t.number" })
	end,

	["paramRange: t.cframe of a codec that is not a position"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.cframe(t.bool() :: any, t.rotation(9))
		end, { code = "paramRange", at = at(line + 2), subject = "t.cframe" })
	end,

	["paramRange: definition options that are not a table"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			Lync.event("client" :: any)
		end, { code = "paramRange", at = at(line + 2), subject = "Lync.event" })
	end,

	["enumItems: an empty list"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.enum({})
		end, { code = "enumItems", at = at(line + 2), subject = "t.enum" })
	end,

	["enumItems: items that are not strings, or a table that is not a list"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.enum({ "a", 2 } :: any)
		end, { code = "enumItems", at = at(line + 2) })
		Check.expectThrow(function()
			t.enum({ "a", b = "b" } :: any)
		end, { code = "enumItems", at = at(line + 5) })
	end,

	["duplicateName: an enum list that repeats an item"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.enum({ "red", "blue", "red" })
		end, { code = "duplicateName", at = at(line + 2), subject = "t.enum" })
	end,

	["mapKey: a key that is not an integer, list enum or string codec"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.map(t.bool() :: any, t.int(0, 3), 4)
		end, { code = "mapKey", at = at(line + 2), subject = "t.map" })
		Check.expectThrow(function()
			t.map(t.enum(Enum.Material) :: any, t.int(0, 3), 4)
		end, { code = "mapKey", at = at(line + 5), subject = "t.map" })
	end,

	["notACodec: a constructor given a value that is not a codec"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.optional(5)
		end, { code = "notACodec", at = at(line + 2), subject = "t.optional" })
		Check.expectThrow(function()
			t.cframe(nil :: any, t.rotation(9))
		end, { code = "notACodec", at = at(line + 5), subject = "t.cframe" })
	end,

	["t.custom: unknown, missing and misnamed options"] = function()
		local function encode(_writer: any, _value: any) end
		local function decode(_reader: any): (any, number)
			return nil, 0
		end

		local withSize =
			{ encode = encode, decode = decode, maxBits = 8, name = "x", version = 1, size = 1 }

		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.custom(withSize :: any)
		end, { code = "unknownOption", at = at(line + 2), subject = "t.custom" })
		Check.expectThrow(function()
			t.custom({ encode = encode, decode = decode, name = "x", version = 1 } :: any)
		end, { code = "missingOption", at = at(line + 5), subject = "t.custom" })
		Check.expectThrow(function()
			t.custom({ encode = encode, decode = decode, maxBits = 8, name = "", version = 1 })
		end, { code = "nameLength", at = at(line + 8), subject = "t.custom" })
	end,

	["nameLength: a union variant named by a number"] = function()
		local line = debug.info(1, "l")
		Check.expectThrow(function()
			t.union({ { a = t.bool() } })
		end, { code = "nameLength", at = at(line + 2), subject = "t.union" })
	end,
}
