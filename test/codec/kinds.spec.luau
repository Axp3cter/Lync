--!strict

--[=[
	kinds.spec

	Exhaustiveness of the codec's kind dispatches (m1-plan.md §7.4): a codec of every kind
	`ir.luau` declares goes through collecting, row and column encoding, and row and column
	decoding, and must come back as it went in. The kinds are read from `ir.luau` itself, so a kind
	added there without a case here fails this spec, and a dispatch that skips a kind fails the
	round trip.
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Frame = require("../support/frame")
local Gen = require("../support/gen")
local Lync = require("../../src")

-- Constants ---------------------------------------------------------------------------------------

const IR_SOURCE = "src/plan/ir.luau"
const DRAWS = 20

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function encodeNibble(w: Bits.Writer, value: number)
	Bits.write(w, 4, value)
end

local function decodeNibble(r: Bits.Reader): (any, number)
	local value = Bits.read(r, 4)
	if value == nil then
		return nil, 4
	end

	return value, 0
end

-- A codec of each kind; each composite kind holds an instance and an array, so a dispatch that
-- skips the composite shows in the instances and the elements.
local function codecsByKind(): { [string]: any }
	local function held(): any
		return { list = t.array(t.bool(), 4), part = t.instance() }
	end

	return {
		bool = t.bool(),
		int = t.int(0, 9),
		varint = t.int(),
		number = t.number(0, 1, 0.25),
		f32 = t.f32(),
		f64 = t.f64(),
		angle = t.angle(math.pi / 2),
		string = t.string(3),
		buffer = t.buffer(3),
		vector3 = t.vector3(0, 1, 0.25),
		vector3f32 = t.vector3f32(),
		direction = t.direction(8),
		rotation = t.rotation(7),
		cframe = t.cframe(t.vector3f32(), t.rotation(7)),
		color3 = t.color3(),
		enum = t.enum({ "a", "b", "c" }),
		robloxEnum = t.enum(Enum.NormalId),
		instance = t.instance(),
		optional = t.optional(held()),
		array = t.array(held(), 4),
		map = t.map(t.string(2), held(), 4),
		union = t.union({ a = held(), b = {} }),
		record = held(),
		custom = t.custom({
			encode = encodeNibble,
			decode = decodeNibble,
			maxBits = 4,
			name = "nibble",
			version = 1,
		}),
		convert = t.convert(held(), table.clone, table.clone),
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
	["every IR kind is collected, encoded and decoded in rows and column blocks"] = function()
		math.randomseed(25)
		local codecs = codecsByKind()
		local kinds = irKinds()
		Check.expect(#kinds >= 25, `{IR_SOURCE} must declare the codec kinds`)

		local pool = { Instance.new("Part"), Instance.new("Model"), Instance.new("Folder") }
		for _, kind in kinds do
			local declared = codecs[kind]
			Check.expect(declared ~= nil, `kind {kind} must have a case in kinds.spec`)

			local codec = Gen.plan(declared)
			Check.expectEqual(codec.kind, kind, `{kind} plans to its kind`)
			for _, count in { 1, Column.MIN_ROWS } do
				for _ = 1, DRAWS do
					local style = { absentChance = 0.2, variantCount = nil, instances = pool }
					local values = {}
					for i = 1, count do
						values[i] = Gen.value(codec, 4, style)
					end

					local bytes, list = Frame.encodeRun(codec, values, count)
					local decoded = Frame.decodeRun(bytes, codec, count, list)
					Check.expectEqual(decoded.rule, 0, `{kind}, {count} rows: rule`)
					Check.expectEqual(decoded.values, values, `{kind}, {count} rows`)
				end
			end
		end
	end,
}
