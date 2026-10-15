--!strict

--[=[
	sizes.spec

	Worst-case message sizes bound both forms of an array or map (v5.md §4.3): single rows below
	`Column.MIN_ROWS` elements, a column block from there. The property draws random values at the
	declared maxima, flattens them into columns as §4.3 does, costs each column with the reference
	encoder's `Column.choose`, and checks the total never passes the planner's worst case.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Ints = require("../../src/wire/ints")
local Lync = require("../../src")
local Prop = require("../support/prop")

-- Constants ---------------------------------------------------------------------------------------

local t = Lync.types

-- The bounds the planner uses for `t.int()` and Roblox enum codes, and for a chunk's instances.
const WIDE_INTERVAL = 2 ^ 53
const MAX_INSTANCES = 65_535

-- Private -----------------------------------------------------------------------------------------

local function identity(value: any): any
	return value
end

local function encodeCustom(_writer: any, _value: any) end

local function decodeCustom(_reader: any): (any, number)
	return nil, 0
end

-- Returns a code in [0, n - 1], the extremes a quarter of the time each.
local function randomCode(n: number): number
	local roll = math.random(1, 4)
	if roll == 1 then
		return 0
	end

	if roll == 2 then
		return n - 1
	end

	return math.floor(math.random() * n)
end

-- Returns a count in [0, max], the maximum half of the time.
local function randomCount(max: number): number
	if math.random(1, 2) == 1 then
		return max
	end

	return math.random(0, max)
end

local function integerColumnBits(n: number, rows: number): number
	local codes = table.create(rows) :: { number }
	for i = 1, rows do
		codes[i] = randomCode(n)
	end

	local _, _, bits = Column.choose(codes, 1, rows, 0, n)
	return bits
end

local function randomEnumValue(codec: any): number
	local values = {}
	for value in codec.byValue do
		table.insert(values, value)
	end

	return values[math.random(1, #values)]
end

local columnBitsOf: (codec: any, rows: number) -> (number, number)

-- Returns the bits and tail bytes of one random value in single-row encoding (v5.md §3.3).
local function rowBitsOf(codec: any): (number, number)
	local kind = codec.kind
	if kind == "bool" then
		return 1, 0
	elseif kind == "int" or kind == "number" or kind == "angle" or kind == "enum" then
		return codec.width, 0
	elseif kind == "varint" then
		local value = randomCode(WIDE_INTERVAL) - WIDE_INTERVAL / 2
		return Ints.egBits(Ints.zigzag(value), 0), 0
	elseif kind == "robloxEnum" then
		return Ints.egBits(Ints.zigzag(randomEnumValue(codec)), 0), 0
	elseif kind == "instance" then
		return Ints.width(math.random(1, MAX_INSTANCES)), 0
	elseif kind == "string" or kind == "buffer" then
		return codec.width, randomCount(codec.max)
	elseif kind == "f32" then
		return 32, 0
	elseif kind == "f64" then
		return 64, 0
	elseif kind == "vector3f32" then
		return 96, 0
	elseif kind == "custom" then
		return math.random(0, codec.maxBits), math.random(0, codec.maxBytes)
	elseif kind == "vector3" then
		return 3 * codec.axis.width, 0
	elseif kind == "direction" then
		return 2 * codec.bits, 0
	elseif kind == "color3" then
		return 24, 0
	elseif kind == "rotation" then
		local isAxisAligned = math.random(1, 2) == 1
		return if isAxisAligned then 1 + 5 else 1 + 2 + 3 * codec.bits, 0
	elseif kind == "cframe" then
		local positionBits, positionTail = rowBitsOf(codec.position)
		local rotationBits = rowBitsOf(codec.rotation)
		return positionBits + rotationBits, positionTail
	elseif kind == "optional" then
		if math.random(1, 2) == 1 then
			return 1, 0
		end

		local innerBits, innerTail = rowBitsOf(codec.inner)
		return 1 + innerBits, innerTail
	elseif kind == "union" then
		local variant = codec.variants[math.random(1, #codec.variants)]
		local variantBits, variantTail = rowBitsOf(variant.record)
		return codec.width + variantBits, variantTail
	elseif kind == "record" then
		local totalBits = 0
		local totalTail = 0
		for _, field in codec.fields do
			local fieldBits, fieldTail = rowBitsOf(field.codec)
			totalBits += fieldBits
			totalTail += fieldTail
		end
		return totalBits, totalTail
	elseif kind == "convert" then
		return rowBitsOf(codec.base)
	end

	-- An array or map: its elements in single rows below `Column.MIN_ROWS`, else a column block.
	local count = randomCount(codec.max)
	if count >= Column.MIN_ROWS then
		if kind == "array" then
			local elementsBits, elementsTail = columnBitsOf(codec.inner, count)
			return codec.width + elementsBits, elementsTail
		end

		local keysBits, keysTail = columnBitsOf(codec.key, count)
		local valuesBits, valuesTail = columnBitsOf(codec.value, count)
		return codec.width + keysBits + valuesBits, keysTail + valuesTail
	end

	local totalBits = codec.width
	local totalTail = 0
	for _ = 1, count do
		if kind == "array" then
			local elementBits, elementTail = rowBitsOf(codec.inner)
			totalBits += elementBits
			totalTail += elementTail
		else
			local keyBits, keyTail = rowBitsOf(codec.key)
			local valueBits, valueTail = rowBitsOf(codec.value)
			totalBits += keyBits + valueBits
			totalTail += keyTail + valueTail
		end
	end

	return totalBits, totalTail
end

-- Returns the bits and tail bytes of a codec's columns over `rows` random values, flattened as
-- v5.md §4.3 says.
function columnBitsOf(codec: any, rows: number): (number, number)
	if rows == 0 then
		return 0, 0
	end

	local kind = codec.kind
	if kind == "bool" then
		return integerColumnBits(2, rows), 0
	elseif kind == "int" then
		return integerColumnBits(codec.max - codec.min + 1, rows), 0
	elseif kind == "varint" or kind == "robloxEnum" then
		return integerColumnBits(WIDE_INTERVAL, rows), 0
	elseif kind == "number" then
		return integerColumnBits(codec.steps + 1, rows), 0
	elseif kind == "angle" then
		return integerColumnBits(codec.steps, rows), 0
	elseif kind == "enum" then
		return integerColumnBits(#codec.items, rows), 0
	elseif kind == "instance" then
		return integerColumnBits(math.random(1, MAX_INSTANCES), rows), 0
	elseif kind == "string" or kind == "buffer" then
		local tail = 0
		for _ = 1, rows do
			tail += randomCount(codec.max)
		end
		return integerColumnBits(codec.max + 1, rows), tail
	elseif kind == "f32" or kind == "f64" or kind == "vector3f32" or kind == "custom" then
		local totalBits = 0
		local totalTail = 0
		for _ = 1, rows do
			local valueBits, valueTail = rowBitsOf(codec)
			totalBits += valueBits
			totalTail += valueTail
		end
		return totalBits, totalTail
	elseif kind == "vector3" then
		local n = codec.axis.steps + 1
		return integerColumnBits(n, rows) + integerColumnBits(n, rows) + integerColumnBits(n, rows),
			0
	elseif kind == "direction" then
		local n = 2 ^ codec.bits
		return integerColumnBits(n, rows) + integerColumnBits(n, rows), 0
	elseif kind == "color3" then
		return integerColumnBits(256, rows) + integerColumnBits(256, rows) + integerColumnBits(
			256,
			rows
		),
			0
	elseif kind == "rotation" then
		local axisRows = math.random(0, rows)
		local otherRows = rows - axisRows
		local componentBits = 0
		for _ = 1, 3 do
			componentBits += if otherRows > 0
				then integerColumnBits(2 ^ codec.bits, otherRows)
				else 0
		end
		local axisBits = if axisRows > 0 then integerColumnBits(24, axisRows) else 0
		local droppedBits = if otherRows > 0 then integerColumnBits(4, otherRows) else 0
		return integerColumnBits(2, rows) + axisBits + droppedBits + componentBits, 0
	elseif kind == "cframe" then
		local positionBits, positionTail = columnBitsOf(codec.position, rows)
		local rotationBits = columnBitsOf(codec.rotation, rows)
		return positionBits + rotationBits, positionTail
	elseif kind == "optional" then
		local presentRows = math.random(0, rows)
		local innerBits, innerTail = columnBitsOf(codec.inner, presentRows)
		return integerColumnBits(2, rows) + innerBits, innerTail
	elseif kind == "union" then
		local totalBits = integerColumnBits(#codec.variants, rows)
		local totalTail = 0
		local rowsLeft = rows
		for i, variant in codec.variants do
			local variantRows = if i == #codec.variants then rowsLeft else math.random(0, rowsLeft)
			rowsLeft -= variantRows
			local variantBits, variantTail = columnBitsOf(variant.record, variantRows)
			totalBits += variantBits
			totalTail += variantTail
		end
		return totalBits, totalTail
	elseif kind == "record" then
		local totalBits = 0
		local totalTail = 0
		for _, field in codec.fields do
			local fieldBits, fieldTail = columnBitsOf(field.codec, rows)
			totalBits += fieldBits
			totalTail += fieldTail
		end
		return totalBits, totalTail
	elseif kind == "convert" then
		return columnBitsOf(codec.base, rows)
	end

	-- An array or map: a count column, then its elements' columns over every element of every row.
	local elementCount = 0
	for _ = 1, rows do
		elementCount += randomCount(codec.max)
	end

	local countBits = integerColumnBits(codec.max + 1, rows)
	if kind == "array" then
		local elementsBits, elementsTail = columnBitsOf(codec.inner, elementCount)
		return countBits + elementsBits, elementsTail
	end

	local keysBits, keysTail = columnBitsOf(codec.key, elementCount)
	local valuesBits, valuesTail = columnBitsOf(codec.value, elementCount)
	return countBits + keysBits + valuesBits, keysTail + valuesTail
end

local function sampled()
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

	["random values at the maxima never pass the planner's worst case"] = function()
		local ir = sampled()
		Prop.check("encoded size <= worst case", function(_size: number): number
			return math.random(1, 2 ^ 30)
		end, function(seed: number)
			math.randomseed(seed)
			for _, definition in ir.definitions do
				local bits, tail = rowBitsOf(definition.data)
				Check.expect(bits <= definition.dataMaxBits, `{definition.name}: {bits} bits`)
				Check.expect(tail <= definition.dataMaxTail, `{definition.name}: {tail} tail bytes`)
			end
		end, { runs = 300 })
	end,
}
