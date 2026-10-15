--!strict

--[=[
	kinds.spec

	Exhaustiveness of the planner's and serializer's kind dispatches (m1-plan.md §7.4): every
	codec kind `ir.luau` declares is built, planned alone and inside a column block, and
	serialized, and each must give its §4.7 type byte and its W. The kinds are read from
	`ir.luau` itself, so a kind added there without a case here fails this spec.
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Lync = require("../../src")

-- Constants ---------------------------------------------------------------------------------------

local t = Lync.types

const IR_SOURCE = "src/plan/ir.luau"

-- The type byte's offset in a one-definition schema "k" with data: version, namespace, count,
-- definition name, kind, from, lane, then data's presence byte (v5.md §4.7).
const TYPE_BYTE_OFFSET = 1 + (2 + 1) + 2 + (2 + 1) + 3 + 1

-- Private -----------------------------------------------------------------------------------------

local function identity(value: any): any
	return value
end

local function encodeCustom(w: Bits.Writer, value: number)
	Bits.write(w, 4, value)
end

local function decodeCustom(r: Bits.Reader): (any, number)
	return Bits.read(r, 4), 0
end

-- For each kind: a codec of it, its §4.7 type byte, the W of a message holding it, and whether it
-- holds an instance. Each composite kind holds `held`, so a dispatch that skips it shows in W and
-- in `hasInstances`.
local function casesByKind(): {
	[string]: { codec: any, typeByte: number, elements: number, hasInstances: boolean? },
}
	local function held(): any
		return { list = t.array(t.bool(), 2), part = t.instance() }
	end

	return {
		bool = { codec = t.bool(), typeByte = 1, elements = 1 },
		int = { codec = t.int(0, 9), typeByte = 2, elements = 1 },
		varint = { codec = t.int(), typeByte = 3, elements = 1 },
		number = { codec = t.number(0, 1, 0.25), typeByte = 4, elements = 1 },
		f32 = { codec = t.f32(), typeByte = 5, elements = 1 },
		f64 = { codec = t.f64(), typeByte = 6, elements = 1 },
		angle = { codec = t.angle(math.pi / 2), typeByte = 7, elements = 1 },
		string = { codec = t.string(3), typeByte = 8, elements = 1 },
		buffer = { codec = t.buffer(3), typeByte = 9, elements = 1 },
		vector3 = { codec = t.vector3(0, 1, 0.25), typeByte = 10, elements = 1 },
		vector3f32 = { codec = t.vector3f32(), typeByte = 11, elements = 1 },
		direction = { codec = t.direction(8), typeByte = 12, elements = 1 },
		rotation = { codec = t.rotation(7), typeByte = 13, elements = 1 },
		cframe = { codec = t.cframe(t.vector3f32(), t.rotation(7)), typeByte = 14, elements = 1 },
		color3 = { codec = t.color3(), typeByte = 15, elements = 1 },
		enum = { codec = t.enum({ "a", "b", "c" }), typeByte = 16, elements = 1 },
		robloxEnum = { codec = t.enum(Enum.NormalId), typeByte = 17, elements = 1 },
		instance = { codec = t.instance(), typeByte = 18, elements = 1, hasInstances = true },
		optional = { codec = t.optional(held()), typeByte = 19, elements = 3, hasInstances = true },
		array = { codec = t.array(held(), 2), typeByte = 20, elements = 7, hasInstances = true },
		map = {
			codec = t.map(t.string(2), held(), 2),
			typeByte = 21,
			elements = 7,
			hasInstances = true,
		},
		union = {
			codec = t.union({ a = held() }),
			typeByte = 22,
			elements = 3,
			hasInstances = true,
		},
		record = { codec = held(), typeByte = 23, elements = 3, hasInstances = true },
		custom = {
			codec = t.custom({
				encode = encodeCustom,
				decode = decodeCustom,
				maxBits = 4,
				name = "nibble",
				version = 1,
			}),
			typeByte = 24,
			elements = 1,
		},
		convert = {
			codec = t.convert(held(), identity, identity),
			typeByte = 25,
			elements = 3,
			hasInstances = true,
		},
	}
end

local function irKinds(): { string }
	local kinds = {}
	local isSeen: { [string]: boolean } = {}
	for kind in string.gmatch(fs.readFile(IR_SOURCE), 'kind: "(%w+)"%s*[,}]') do
		if not isSeen[kind] then
			isSeen[kind] = true
			table.insert(kinds, kind)
		end
	end

	return kinds
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["every IR kind is planned, sized, counted and serialized"] = function()
		local cases = casesByKind()
		local kinds = irKinds()
		Check.expect(#kinds >= 25, `{IR_SOURCE} must declare the codec kinds`)

		for _, kind in kinds do
			local case = cases[kind]
			Check.expect(case ~= nil, `kind {kind} must have a case in kinds.spec`)

			local ir = Lync.schema("k", {
				e = Lync.event({ from = "server", data = case.codec }),
			}).ir
			local definition = ir.definitions[1]
			local typeByte = buffer.readu8(ir.serialization, TYPE_BYTE_OFFSET)
			Check.expectEqual(definition.data.kind, kind, `{kind} plans to its kind`)
			Check.expectEqual(typeByte, case.typeByte, `{kind}'s type byte`)
			Check.expectEqual(definition.dataMaxElements, case.elements, `{kind}'s W`)
			Check.expect(definition.dataMaxBits > 0, `{kind} costs bits`)
			Check.expectEqual(
				definition.hasInstances,
				case.hasInstances == true,
				`{kind} instances`
			)

			-- Inside an array of 4, the element is sized as a column block too (v5.md §4.3).
			local column = Lync.schema("k", {
				e = Lync.event({ from = "server", data = t.array({ v = case.codec }, 4) }),
			}).ir.definitions[1]
			Check.expect(
				column.dataMaxBits > definition.dataMaxBits,
				`{kind} is sized in a column block`
			)
		end
	end,
}
