--!strict

--[=[
	Columns

	Column blocks (v5.md §4.3): many values of one codec flattened, depth first in field order, into
	columns, each integer column coded on residuals by `Column`.

	A record gives its fields' columns in order; an optional, a presence column and then its inner
	codec's columns over the present rows; a union, a variant-index column and then each variant's
	columns over that variant's rows; an array or map, a count column and then its elements' (or
	keys' and then values') columns over every element of every row. Strings and buffers give a
	length column, their bytes going to the tail in row order. `t.f32`, `t.f64` and `t.custom` give
	raw columns, their single-row encodings one after another; `t.vector3f32` gives three, x, y
	and z. A column over zero rows writes nothing.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Column = require("../wire/column")
local Ir = require("../plan/ir")
local Leaves = require("./leaves")
local Quant = require("../wire/quant")

-- Module ------------------------------------------------------------------------------------------

local Columns = {}

-- Constants ---------------------------------------------------------------------------------------

--- The interval of `t.int()` and Roblox enum columns: the values themselves.
const WIDE_LO = -2 ^ 52
const WIDE_N = 2 ^ 53

const AXIS_COUNT = 24
const DROPPED_COUNT = 4
const COLOR_CODES = 256

-- Private -----------------------------------------------------------------------------------------

-- A union variant's record codec is always a record; the cast names that for the checker.
local function fieldsOf(variant: Ir.Variant): { Ir.Field }
	return (variant.record :: any).fields
end

local writeColumns: (
	w: Bits.Writer,
	codec: Ir.Codec,
	values: { any },
	first: number,
	count: number,
	instances: Leaves.Instances
) -> Leaves.Refusal?

local function writeRecords(
	w: Bits.Writer,
	codec: Ir.Codec,
	fields: { Ir.Field },
	values: { any },
	first: number,
	count: number,
	instances: Leaves.Instances
): Leaves.Refusal?
	for i = first, first + count - 1 do
		if typeof(values[i]) ~= "table" then
			return Leaves.refusal(codec, values[i])
		end
	end

	local fieldValues = table.create(count)
	for _, field in fields do
		local name = field.name
		for i = 1, count do
			fieldValues[i] = values[first + i - 1][name]
		end

		local refusal = writeColumns(w, field.codec, fieldValues, 1, count, instances)
		if refusal ~= nil then
			return Leaves.extend(refusal, `.{name}`)
		end
	end

	return nil
end

function writeColumns(
	w: Bits.Writer,
	codec: Ir.Codec,
	values: { any },
	first: number,
	count: number,
	instances: Leaves.Instances
): Leaves.Refusal?
	if count == 0 then
		return nil
	end

	local last = first + count - 1
	if codec.kind == "record" then
		return writeRecords(w, codec, codec.fields, values, first, count, instances)
	elseif codec.kind == "bool" then
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local value = values[i]
			if value == true then
				codes[i - first + 1] = 1
			elseif value == false then
				codes[i - first + 1] = 0
			else
				return Leaves.refusal(codec, value)
			end
		end
		Column.write(w, codes, 1, count, 2)
	elseif codec.kind == "int" then
		local min, max = codec.min, codec.max
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local code = Leaves.intCode(values[i], min, max)
			if code == nil then
				return Leaves.refusal(codec, values[i])
			end
			codes[i - first + 1] = code
		end
		Column.write(w, codes, 1, count, max - min + 1)
	elseif codec.kind == "varint" then
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local code = Leaves.varintCode(values[i])
			if code == nil then
				return Leaves.refusal(codec, values[i])
			end
			codes[i - first + 1] = code
		end
		Column.write(w, codes, 1, count, WIDE_N)
	elseif codec.kind == "number" then
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local code = Leaves.numberCode(values[i], codec)
			if code == nil then
				return Leaves.refusal(codec, values[i])
			end
			codes[i - first + 1] = code
		end
		Column.write(w, codes, 1, count, codec.steps + 1)
	elseif codec.kind == "angle" then
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local code = Leaves.angleCode(values[i], codec.steps)
			if code == nil then
				return Leaves.refusal(codec, values[i])
			end
			codes[i - first + 1] = code
		end
		Column.write(w, codes, 1, count, codec.steps)
	elseif codec.kind == "enum" then
		local index = codec.index
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local code = index[values[i]]
			if code == nil then
				return Leaves.refusal(codec, values[i])
			end
			codes[i - first + 1] = code
		end
		Column.write(w, codes, 1, count, #codec.items)
	elseif codec.kind == "robloxEnum" then
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local code = Leaves.robloxEnumCode(values[i], codec.byValue)
			if code == nil then
				return Leaves.refusal(codec, values[i])
			end
			codes[i - first + 1] = code
		end
		Column.write(w, codes, 1, count, WIDE_N)
	elseif codec.kind == "instance" then
		local codes: { number } = table.create(count, 0)
		for i = first, last do
			local code = Leaves.instanceCode(values[i], codec.class, instances)
			if code == nil then
				return Leaves.refusal(codec, values[i])
			end
			codes[i - first + 1] = code
		end
		Column.write(w, codes, 1, count, #instances.list)
	elseif codec.kind == "optional" then
		local presence: { number } = table.create(count, 0)
		local present = {}
		for i = first, last do
			local value = values[i]
			if value == nil then
				presence[i - first + 1] = 0
			else
				presence[i - first + 1] = 1
				table.insert(present, value)
			end
		end
		Column.write(w, presence, 1, count, 2)
		return writeColumns(w, codec.inner, present, 1, #present, instances)
	elseif codec.kind == "string" or codec.kind == "buffer" then
		local valueType = codec.kind
		local max = codec.max
		local lengths: { number } = table.create(count, 0)
		for i = first, last do
			local value = values[i]
			if typeof(value) ~= valueType then
				return Leaves.refusal(codec, value)
			end

			local length = if valueType == "string" then #value else buffer.len(value)
			if length > max then
				return Leaves.refusal(codec, value)
			end
			lengths[i - first + 1] = length
		end
		Column.write(w, lengths, 1, count, max + 1)
		for i = first, last do
			Bits.writeTail(w, values[i])
		end
	elseif codec.kind == "union" then
		local byName = codec.byName
		local variants = codec.variants
		local codes: { number } = table.create(count, 0)
		local rowsByVariant: { { any } } = {}
		for i = first, last do
			local value = values[i]
			local code = if typeof(value) == "table" then byName[value.kind] else nil
			if code == nil then
				return Leaves.refusal(codec, value)
			end
			codes[i - first + 1] = code

			local rows = rowsByVariant[code + 1]
			if rows == nil then
				rows = {}
				rowsByVariant[code + 1] = rows
			end
			table.insert(rows, value)
		end
		Column.write(w, codes, 1, count, #variants)

		for i, variant in variants do
			local rows = rowsByVariant[i]
			if rows == nil then
				continue
			end

			local refusal =
				writeRecords(w, variant.record, fieldsOf(variant), rows, 1, #rows, instances)
			if refusal ~= nil then
				return refusal
			end
		end
	elseif codec.kind == "array" then
		local max = codec.max
		local counts: { number } = table.create(count, 0)
		local elements = {}
		for i = first, last do
			local value = values[i]
			if typeof(value) ~= "table" or #value > max then
				return Leaves.refusal(codec, value)
			end

			local elementCount = #value
			counts[i - first + 1] = elementCount
			table.move(value, 1, elementCount, #elements + 1, elements)
		end
		Column.write(w, counts, 1, count, max + 1)

		local refusal = writeColumns(w, codec.inner, elements, 1, #elements, instances)
		if refusal ~= nil then
			return Leaves.extend(refusal, "[]")
		end
	elseif codec.kind == "map" then
		local counts: { number } = table.create(count, 0)
		local allKeys = {}
		local allValues = {}
		for i = first, last do
			local value = values[i]
			local keys, refusal = Leaves.sortedKeys(codec, value)
			if keys == nil then
				return refusal
			end

			counts[i - first + 1] = #keys
			for _, key in keys do
				table.insert(allKeys, key)
				allValues[#allKeys] = value[key]
			end
		end
		Column.write(w, counts, 1, count, codec.max + 1)

		local pairCount = #allKeys
		local keyRefusal = writeColumns(w, codec.key, allKeys, 1, pairCount, instances)
		if keyRefusal ~= nil then
			return Leaves.extend(keyRefusal, "[key]")
		end

		local valueRefusal = writeColumns(w, codec.value, allValues, 1, pairCount, instances)
		if valueRefusal ~= nil then
			return Leaves.extend(valueRefusal, "[]")
		end
	elseif codec.kind == "vector3" then
		local axis = codec.axis
		local xCodes: { number } = table.create(count, 0)
		local yCodes: { number } = table.create(count, 0)
		local zCodes: { number } = table.create(count, 0)
		for i = first, last do
			local value = values[i]
			if typeof(value) ~= "Vector3" then
				return Leaves.refusal(codec, value)
			end

			local x, y, z = Leaves.vector3Codes(value.X, value.Y, value.Z, axis)
			if x == nil then
				return Leaves.refusal(codec, value)
			end
			local row = i - first + 1
			xCodes[row], yCodes[row], zCodes[row] = x, y, z
		end

		local n = axis.steps + 1
		Column.write(w, xCodes, 1, count, n)
		Column.write(w, yCodes, 1, count, n)
		Column.write(w, zCodes, 1, count, n)
	elseif codec.kind == "vector3f32" then
		local xBitsList: { number } = table.create(count, 0)
		local yBitsList: { number } = table.create(count, 0)
		local zBitsList: { number } = table.create(count, 0)
		for i = first, last do
			local value = values[i]
			if typeof(value) ~= "Vector3" then
				return Leaves.refusal(codec, value)
			end

			local x, y, z = Leaves.vector3f32Bits(value.X, value.Y, value.Z)
			if x == nil then
				return Leaves.refusal(codec, value)
			end
			local row = i - first + 1
			xBitsList[row], yBitsList[row], zBitsList[row] = x, y, z
		end

		for _, bitsList in { xBitsList, yBitsList, zBitsList } do
			for i = 1, count do
				Bits.write(w, 32, bitsList[i])
			end
		end
	elseif codec.kind == "color3" then
		local redCodes: { number } = table.create(count, 0)
		local greenCodes: { number } = table.create(count, 0)
		local blueCodes: { number } = table.create(count, 0)
		for i = first, last do
			local red, green, blue = Leaves.color3Codes(values[i])
			if red == nil then
				return Leaves.refusal(codec, values[i])
			end
			local row = i - first + 1
			redCodes[row], greenCodes[row], blueCodes[row] = red, green, blue
		end

		Column.write(w, redCodes, 1, count, COLOR_CODES)
		Column.write(w, greenCodes, 1, count, COLOR_CODES)
		Column.write(w, blueCodes, 1, count, COLOR_CODES)
	elseif codec.kind == "direction" then
		local bits = codec.bits
		local xCodes: { number } = table.create(count, 0)
		local yCodes: { number } = table.create(count, 0)
		for i = first, last do
			local x, y = Leaves.directionCodes(values[i], bits)
			if x == nil then
				return Leaves.refusal(codec, values[i])
			end
			xCodes[i - first + 1], yCodes[i - first + 1] = x, y
		end

		Column.write(w, xCodes, 1, count, 2 ^ bits)
		Column.write(w, yCodes, 1, count, 2 ^ bits)
	elseif codec.kind == "rotation" then
		local bits = codec.bits
		local flags: { number } = table.create(count, 0)
		local axes: { number } = {}
		local dropped: { number } = {}
		local aCodes: { number } = {}
		local bCodes: { number } = {}
		local cCodes: { number } = {}
		for i = first, last do
			local value = values[i]
			if typeof(value) ~= "CFrame" or value.X ~= 0 or value.Y ~= 0 or value.Z ~= 0 then
				return Leaves.refusal(codec, value)
			end

			local flag, index, a, b, c = Leaves.rotationCodes(value, bits)
			if flag == nil then
				return Leaves.refusal(codec, value)
			end

			flags[i - first + 1] = flag
			if flag == 1 then
				table.insert(axes, index)
			else
				table.insert(dropped, index)
				table.insert(aCodes, a)
				table.insert(bCodes, b)
				table.insert(cCodes, c)
			end
		end

		local componentCodes = 2 ^ bits
		Column.write(w, flags, 1, count, 2)
		Column.write(w, axes, 1, #axes, AXIS_COUNT)
		Column.write(w, dropped, 1, #dropped, DROPPED_COUNT)
		Column.write(w, aCodes, 1, #aCodes, componentCodes)
		Column.write(w, bCodes, 1, #bCodes, componentCodes)
		Column.write(w, cCodes, 1, #cCodes, componentCodes)
	elseif codec.kind == "cframe" then
		local positions = table.create(count)
		local rotations = table.create(count)
		for i = first, last do
			local value = values[i]
			if typeof(value) ~= "CFrame" then
				return Leaves.refusal(codec, value)
			end
			positions[i - first + 1] = value.Position
			rotations[i - first + 1] = value.Rotation
		end

		local positionRefusal = writeColumns(w, codec.position, positions, 1, count, instances)
		if positionRefusal ~= nil then
			return Leaves.extend(positionRefusal, ".position")
		end

		local rotationRefusal = writeColumns(w, codec.rotation, rotations, 1, count, instances)
		if rotationRefusal ~= nil then
			return Leaves.extend(rotationRefusal, ".rotation")
		end
	elseif codec.kind == "f32" then
		for i = first, last do
			local bits = Leaves.f32Bits(values[i])
			if bits == nil then
				return Leaves.refusal(codec, values[i])
			end
			Bits.write(w, 32, bits)
		end
	elseif codec.kind == "f64" then
		for i = first, last do
			local low, high = Leaves.f64Bits(values[i])
			if low == nil then
				return Leaves.refusal(codec, values[i])
			end
			Bits.write(w, 32, low)
			Bits.write(w, 32, high)
		end
	elseif codec.kind == "custom" then
		for i = first, last do
			local refusal = Leaves.writeCustom(w, codec, values[i])
			if refusal ~= nil then
				return refusal
			end
		end
	elseif codec.kind == "convert" then
		local baseValues = table.create(count)
		for i = first, last do
			baseValues[i - first + 1] = codec.encode(values[i])
		end

		return writeColumns(w, codec.base, baseValues, 1, count, instances)
	end

	return nil
end

local readColumns: (
	r: Bits.Reader,
	codec: Ir.Codec,
	count: number,
	instances: { Instance? },
	out: { any }
) -> number

local function readRecords(
	r: Bits.Reader,
	fields: { Ir.Field },
	variant: Ir.Variant?,
	count: number,
	instances: { Instance? },
	out: { any }
): number
	for i = 1, count do
		out[i] = Leaves.newRecord(fields, variant)
	end

	local column = table.create(count)
	for _, field in fields do
		local rule = readColumns(r, field.codec, count, instances, column)
		if rule ~= 0 then
			return rule
		end

		local name = field.name
		for i = 1, count do
			out[i][name] = column[i]
		end
	end

	return 0
end

local function readRaw32(r: Bits.Reader, count: number, out: { any }, first: number): number
	for i = first, first + count - 1 do
		local bits = Bits.read(r, 32)
		if bits == nil then
			return 4
		end

		local value = Leaves.f32Of(bits)
		if value == nil then
			return 3
		end
		out[i] = value
	end

	return 0
end

function readColumns(
	r: Bits.Reader,
	codec: Ir.Codec,
	count: number,
	instances: { Instance? },
	out: { any }
): number
	if count == 0 then
		return 0
	end

	if codec.kind == "record" then
		return readRecords(r, codec.fields, nil, count, instances, out)
	elseif codec.kind == "bool" then
		local rule = Column.read(r, out, 1, count, 0, 2)
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] = out[i] == 1
		end
		return 0
	elseif codec.kind == "int" then
		local min = codec.min
		local rule = Column.read(r, out, 1, count, 0, codec.max - min + 1)
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] += min
		end
		return 0
	elseif codec.kind == "varint" then
		return Column.read(r, out, 1, count, WIDE_LO, WIDE_N)
	elseif codec.kind == "number" then
		local rule = Column.read(r, out, 1, count, 0, codec.steps + 1)
		if rule ~= 0 then
			return rule
		end

		local min, step, max = codec.min, codec.step, codec.max
		for i = 1, count do
			out[i] = Quant.unnumber(out[i], min, step, max)
		end
		return 0
	elseif codec.kind == "angle" then
		local steps = codec.steps
		local rule = Column.read(r, out, 1, count, 0, steps)
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] = Quant.unangle(out[i], steps)
		end
		return 0
	elseif codec.kind == "enum" then
		local items = codec.items
		local rule = Column.read(r, out, 1, count, 0, #items)
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] = items[out[i] + 1]
		end
		return 0
	elseif codec.kind == "robloxEnum" then
		local rule = Column.read(r, out, 1, count, WIDE_LO, WIDE_N)
		if rule ~= 0 then
			return rule
		end

		local byValue = codec.byValue
		for i = 1, count do
			out[i] = byValue[out[i]]
		end
		return 0
	elseif codec.kind == "instance" then
		local instanceCount = #instances
		if instanceCount == 0 then
			return 2
		end

		local rule = Column.read(r, out, 1, count, 0, instanceCount)
		if rule ~= 0 then
			return rule
		end

		local class = codec.class
		for i = 1, count do
			local instance, instanceRule = Leaves.instanceOf(instances, out[i], class)
			if instanceRule ~= 0 then
				return instanceRule
			end
			out[i] = instance
		end
		return 0
	elseif codec.kind == "optional" then
		local rule = Column.read(r, out, 1, count, 0, 2)
		if rule ~= 0 then
			return rule
		end

		local presentCount = 0
		for i = 1, count do
			presentCount += out[i]
		end

		local present = table.create(presentCount)
		rule = readColumns(r, codec.inner, presentCount, instances, present)
		if rule ~= 0 then
			return rule
		end

		local j = 0
		for i = 1, count do
			if out[i] == 1 then
				j += 1
				out[i] = present[j]
			else
				out[i] = nil
			end
		end
		return 0
	elseif codec.kind == "string" or codec.kind == "buffer" then
		local rule = Column.read(r, out, 1, count, 0, codec.max + 1)
		if rule ~= 0 then
			return rule
		end

		local isBuffer = codec.kind == "buffer"
		for i = 1, count do
			local value = Bits.readTail(r, out[i], isBuffer)
			if value == nil then
				return 4
			end
			out[i] = value
		end
		return 0
	elseif codec.kind == "union" then
		local variants = codec.variants
		local rule = Column.read(r, out, 1, count, 0, #variants)
		if rule ~= 0 then
			return rule
		end

		local rowCounts: { number } = {}
		for i = 1, count do
			local variantIndex = out[i] + 1
			rowCounts[variantIndex] = (rowCounts[variantIndex] or 0) + 1
		end

		local recordsByVariant: { { any } } = {}
		for i, variant in variants do
			local rowCount = rowCounts[i]
			if rowCount == nil then
				continue
			end

			local records = table.create(rowCount)
			rule = readRecords(r, fieldsOf(variant), variant, rowCount, instances, records)
			if rule ~= 0 then
				return rule
			end
			recordsByVariant[i] = records
			rowCounts[i] = 0
		end

		for i = 1, count do
			local variantIndex = out[i] + 1
			local taken = rowCounts[variantIndex] + 1
			rowCounts[variantIndex] = taken
			out[i] = recordsByVariant[variantIndex][taken]
		end
		return 0
	elseif codec.kind == "array" then
		local rule = Column.read(r, out, 1, count, 0, codec.max + 1)
		if rule ~= 0 then
			return rule
		end

		local elementCount = 0
		for i = 1, count do
			elementCount += out[i]
		end

		local elements = table.create(elementCount)
		rule = readColumns(r, codec.inner, elementCount, instances, elements)
		if rule ~= 0 then
			return rule
		end

		local position = 1
		for i = 1, count do
			local rowCount = out[i]
			local array = table.create(rowCount)
			table.move(elements, position, position + rowCount - 1, 1, array)
			position += rowCount
			out[i] = array
		end
		return 0
	elseif codec.kind == "map" then
		local rule = Column.read(r, out, 1, count, 0, codec.max + 1)
		if rule ~= 0 then
			return rule
		end

		local pairCount = 0
		for i = 1, count do
			pairCount += out[i]
		end

		local keys = table.create(pairCount)
		rule = readColumns(r, codec.key, pairCount, instances, keys)
		if rule ~= 0 then
			return rule
		end

		local values = table.create(pairCount)
		rule = readColumns(r, codec.value, pairCount, instances, values)
		if rule ~= 0 then
			return rule
		end

		local keyCodec = codec.key
		local position = 0
		for i = 1, count do
			local map = {}
			for j = position + 1, position + out[i] do
				local key = keys[j]
				if j > position + 1 and not Leaves.isAscending(keyCodec, keys[j - 1], key) then
					return 5
				end
				map[key] = values[j]
			end
			position += out[i]
			out[i] = map
		end
		return 0
	elseif codec.kind == "vector3" then
		local axis = codec.axis
		local n = axis.steps + 1
		local yCodes: { number } = table.create(count, 0)
		local zCodes: { number } = table.create(count, 0)
		local rule = Column.read(r, out, 1, count, 0, n)
		if rule == 0 then
			rule = Column.read(r, yCodes, 1, count, 0, n)
		end
		if rule == 0 then
			rule = Column.read(r, zCodes, 1, count, 0, n)
		end
		if rule ~= 0 then
			return rule
		end

		local min, step, max = axis.min, axis.step, axis.max
		for i = 1, count do
			out[i] = Vector3.new(
				Quant.unnumber(out[i], min, step, max),
				Quant.unnumber(yCodes[i], min, step, max),
				Quant.unnumber(zCodes[i], min, step, max)
			)
		end
		return 0
	elseif codec.kind == "vector3f32" then
		local ys: { number } = table.create(count, 0)
		local zs: { number } = table.create(count, 0)
		local rule = readRaw32(r, count, out, 1)
		if rule == 0 then
			rule = readRaw32(r, count, ys, 1)
		end
		if rule == 0 then
			rule = readRaw32(r, count, zs, 1)
		end
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] = Vector3.new(out[i], ys[i], zs[i])
		end
		return 0
	elseif codec.kind == "color3" then
		local greenCodes: { number } = table.create(count, 0)
		local blueCodes: { number } = table.create(count, 0)
		local rule = Column.read(r, out, 1, count, 0, COLOR_CODES)
		if rule == 0 then
			rule = Column.read(r, greenCodes, 1, count, 0, COLOR_CODES)
		end
		if rule == 0 then
			rule = Column.read(r, blueCodes, 1, count, 0, COLOR_CODES)
		end
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] = Leaves.color3Of(out[i], greenCodes[i], blueCodes[i])
		end
		return 0
	elseif codec.kind == "direction" then
		local bits = codec.bits
		local yCodes: { number } = table.create(count, 0)
		local rule = Column.read(r, out, 1, count, 0, 2 ^ bits)
		if rule == 0 then
			rule = Column.read(r, yCodes, 1, count, 0, 2 ^ bits)
		end
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] = Leaves.directionOf(out[i], yCodes[i], bits)
		end
		return 0
	elseif codec.kind == "rotation" then
		local rule = Column.read(r, out, 1, count, 0, 2)
		if rule ~= 0 then
			return rule
		end

		local axisCount = 0
		for i = 1, count do
			axisCount += out[i]
		end
		local otherCount = count - axisCount

		local bits = codec.bits
		local componentCodes = 2 ^ bits
		local axes: { number } = table.create(axisCount, 0)
		local dropped: { number } = table.create(otherCount, 0)
		local aCodes: { number } = table.create(otherCount, 0)
		local bCodes: { number } = table.create(otherCount, 0)
		local cCodes: { number } = table.create(otherCount, 0)
		rule = Column.read(r, axes, 1, axisCount, 0, AXIS_COUNT)
		if rule == 0 then
			rule = Column.read(r, dropped, 1, otherCount, 0, DROPPED_COUNT)
		end
		if rule == 0 then
			rule = Column.read(r, aCodes, 1, otherCount, 0, componentCodes)
		end
		if rule == 0 then
			rule = Column.read(r, bCodes, 1, otherCount, 0, componentCodes)
		end
		if rule == 0 then
			rule = Column.read(r, cCodes, 1, otherCount, 0, componentCodes)
		end
		if rule ~= 0 then
			return rule
		end

		local axisRow = 0
		local otherRow = 0
		for i = 1, count do
			local flag = out[i]
			local index, a, b, c = 0, 0, 0, 0
			if flag == 1 then
				axisRow += 1
				index = axes[axisRow]
			else
				otherRow += 1
				index = dropped[otherRow]
				a, b, c = aCodes[otherRow], bCodes[otherRow], cCodes[otherRow]
			end

			if not Leaves.canonicalRotation(flag, index, a, b, c, bits) then
				return 6
			end

			-- Cast: canonical codes decode.
			out[i] = Leaves.rotationOf(flag, index, a, b, c, bits, 0, 0, 0) :: CFrame
		end
		return 0
	elseif codec.kind == "cframe" then
		local positions = table.create(count)
		local rule = readColumns(r, codec.position, count, instances, positions)
		if rule == 0 then
			rule = readColumns(r, codec.rotation, count, instances, out)
		end
		if rule ~= 0 then
			return rule
		end

		for i = 1, count do
			out[i] += positions[i]
		end
		return 0
	elseif codec.kind == "f32" then
		return readRaw32(r, count, out, 1)
	elseif codec.kind == "f64" then
		for i = 1, count do
			local low = Bits.read(r, 32)
			local high = Bits.read(r, 32)
			if low == nil or high == nil then
				return 4
			end

			local value = Leaves.f64Of(low, high)
			if value == nil then
				return 3
			end
			out[i] = value
		end
		return 0
	elseif codec.kind == "custom" then
		local decode = codec.decode
		for i = 1, count do
			local value, rule = decode(r)
			if rule ~= 0 then
				return rule
			end
			out[i] = value
		end
		return 0
	elseif codec.kind == "convert" then
		local rule = readColumns(r, codec.base, count, instances, out)
		if rule ~= 0 then
			return rule
		end

		local decode = codec.decode
		for i = 1, count do
			out[i] = decode(out[i])
		end
		return 0
	end

	return 0
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Reads a column block of values.

	@param  r         the reader
	@param  codec     the values' codec
	@param  count     how many values
	@param  instances the chunk's instance list
	@param  out       where the values are stored, at 1 to `count`
	@return 0, or the v5.md §4.8 rule that refuses the block
]=]
function Columns.read(
	r: Bits.Reader,
	codec: Ir.Codec,
	count: number,
	instances: { Instance? },
	out: { any }
): number
	return readColumns(r, codec, count, instances, out)
end

--[=[
	Writes values as a column block.

	@param  w         the writer
	@param  codec     the values' codec
	@param  values    the values, at `first` to `first + count - 1`
	@param  first     the index of the first value
	@param  count     how many values; 0 writes nothing
	@param  instances the chunk's instances, extended on first references
	@return nil, or the refusal of the first value the codec refuses; the writer then holds part
	        of the block
]=]
function Columns.write(
	w: Bits.Writer,
	codec: Ir.Codec,
	values: { any },
	first: number,
	count: number,
	instances: Leaves.Instances
): Leaves.Refusal?
	return writeColumns(w, codec, values, first, count, instances)
end

return table.freeze(Columns)
