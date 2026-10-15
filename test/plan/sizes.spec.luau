--!strict

--[=[
	sizes.spec

	Worst-case message sizes and element counts against the real encoder: random messages of
	every kind of codec are encoded with `Run.encode`, and none passes the planner's
	`dataMaxBits` or `dataMaxTail` (v5.md §3.4); decoded, none holds more than its W elements
	(`dataMaxElements`, §4.8). Arrays and maps are bounded in both forms (§4.3): single rows below
	`Column.MIN_ROWS` elements, a column block from there.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Gen = require("../support/gen")
local Ints = require("../../src/wire/ints")
local Lync = require("../../src")
local Run = require("../../src/codec/run")

-- Constants ---------------------------------------------------------------------------------------

local t = Lync.types

const MESSAGES_PER_DEFINITION = 20_000
const CUSTOM_BITS = 12
const INSTANCE_COUNT = 5

-- Private -----------------------------------------------------------------------------------------

local function identity(value: any): any
	return value
end

local function encodeCustom(w: Bits.Writer, value: number)
	Bits.write(w, CUSTOM_BITS, value)
end

local function decodeCustom(r: Bits.Reader): (any, number)
	local value = Bits.read(r, CUSTOM_BITS)
	if value == nil then
		return nil, 4
	end

	return value, 0
end

-- Returns the elements a decoded value holds below its message (v5.md §4.8).
local function elementsIn(codec: any, value: any): number
	if value == nil then
		return 0
	end

	local kind = codec.kind
	if kind == "record" then
		local total = 0
		for _, field in codec.fields do
			total += elementsIn(field.codec, value[field.name])
		end
		return total
	elseif kind == "optional" then
		return elementsIn(codec.inner, value)
	elseif kind == "convert" then
		return elementsIn(codec.base, value)
	elseif kind == "union" then
		local variant = codec.variants[codec.byName[value.kind] + 1]
		return elementsIn(variant.record, value)
	elseif kind == "array" then
		local total = #value
		for _, element in value do
			total += elementsIn(codec.inner, element)
		end
		return total
	elseif kind == "map" then
		local total = 0
		for key, element in value do
			total += 1 + elementsIn(codec.key, key) + elementsIn(codec.value, element)
		end
		return total
	end

	return 0
end

local function sampled(): any
	local custom = t.custom({
		encode = encodeCustom,
		decode = decodeCustom,
		maxBits = 12,
		maxBytes = 3,
		name = "packed",
		version = 1,
	})

	return Lync.schema("sizes", {
		ints = Lync.event({ from = "server", data = t.array(t.int(0, 100), 10) }),
		few = Lync.event({ from = "server", data = t.array(t.angle(0.01), 3) }),
		records = Lync.event({
			from = "server",
			data = t.array({
				hp = t.int(0, 100),
				tag = t.enum({ "a", "b", "c" }),
				alive = t.bool(),
				title = t.optional(t.string(8)),
			}, 6),
		}),
		variants = Lync.event({
			from = "server",
			data = t.array(
				t.union({
					a = { x = t.int(0, 1000) },
					b = { y = t.vector3(-10, 10, 0.5), r = t.rotation(9) },
				}),
				5
			),
		}),
		maps = Lync.event({ from = "server", data = t.map(t.string(4), t.array(t.int(), 5), 4) }),
		nested = Lync.event({ from = "server", data = t.array(t.array(t.direction(11), 4), 4) }),
		mixed = Lync.event({
			from = "server",
			data = t.array({
				c = t.color3(),
				f = t.f32(),
				d = t.f64(),
				e = t.enum(Enum.Material),
				i = t.optional(t.instance()),
				s = custom,
			}, 8),
		}),
		converted = Lync.event({
			from = "server",
			data = t.array(t.convert(t.int(0, 9), identity, identity), 20),
		}),
		frames = Lync.event({
			from = "server",
			data = t.map(t.int(-5, 5), t.cframe(t.vector3(0, 1, 0.25), t.rotation(7)), 8),
		}),
	}).ir
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["an array of Column.MIN_ROWS or more elements is bounded by its column block"] = function()
		local manyCount = Column.MIN_ROWS + 7
		local fewCount = Column.MIN_ROWS - 1
		local ir = Lync.schema("sizes", {
			many = Lync.event({ from = "server", data = t.array(t.int(0, 100), manyCount) }),
			few = Lync.event({ from = "server", data = t.array(t.int(0, 100), fewCount) }),
		}).ir

		-- Each element is u(ceil(log2 101)) = 7 bits in a single row. As a column: mode 2 bits,
		-- base EG-0 of 100 (z = 6, so 13 bits) and width 6 bits, then 7 bits per element. The
		-- count is u(ceil(log2(max + 1))) bits.
		local manyCountBits = Ints.width(manyCount + 1)
		local fewCountBits = Ints.width(fewCount + 1)
		Check.expectEqual(ir.byName.many.dataMaxBits, manyCountBits + 2 + 13 + 6 + manyCount * 7)
		Check.expectEqual(ir.byName.few.dataMaxBits, fewCountBits + fewCount * 7)
	end,

	["random messages never pass the planner's worst-case size or element count"] = function()
		math.randomseed(1)
		local instances = table.create(INSTANCE_COUNT) :: { Instance }
		for i = 1, INSTANCE_COUNT do
			instances[i] = Instance.new("Part")
		end

		for _, definition in sampled().definitions do
			local codec = definition.data
			for message = 1, MESSAGES_PER_DEFINITION do
				local value = Gen.value(codec, math.huge, Gen.style(instances))
				local listed = { list = {}, index = {} }
				Run.collect(codec, { value }, 1, listed)

				local w = Bits.writer()
				Run.encode(w, codec, { value }, 1, listed, `sizes.{definition.name}`)
				local bits = w.bit
				local tail = w.tailBytes
				Check.expect(
					bits <= definition.dataMaxBits,
					`{definition.name} {message}: {bits} bits`
				)
				Check.expect(
					tail <= definition.dataMaxTail,
					`{definition.name} {message}: {tail} B`
				)

				local out = {}
				local rule = Run.decode(Bits.reader(Bits.finish(w)), codec, 1, listed.list, out)
				Check.expectEqual(rule, 0, `{definition.name} {message} decodes`)

				local elements = 1 + elementsIn(codec, out[1])
				Check.expect(
					elements <= definition.dataMaxElements,
					`{definition.name} {message}: {elements} elements`
				)
			end
		end
	end,
}
