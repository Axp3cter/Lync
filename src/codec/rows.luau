--!strict

--[=[
	Rows

	Single rows (v5.md §3.3, §4.3): a value written in its codec's single-row encoding, and read
	back. Inside a row, an array or map of `Column.MIN_ROWS` or more elements is its count followed
	by a column block over its elements (or its keys, then its values).

	Writing returns a refusal instead of raising, so each level adds its path segment as it
	unwinds and nothing is formatted on success; `Rows.encodeValue` turns a refusal into the caller
	error `valueRefused`. Reading returns a v5.md §4.8 rule instead of raising.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Column = require("../wire/column")
local Columns = require("./columns")
local Ints = require("../wire/ints")
local Ir = require("../plan/ir")
local Leaves = require("./leaves")
local Quant = require("../wire/quant")

-- Module ------------------------------------------------------------------------------------------

local Rows = {}

-- Types -------------------------------------------------------------------------------------------

export type Instances = Leaves.Instances
export type Refusal = Leaves.Refusal

-- Constants ---------------------------------------------------------------------------------------

const AXIS_INDEX_BITS = 5
const AXIS_COUNT = 24
const DROPPED_BITS = 2
const COLOR_BITS = 8

-- Private -----------------------------------------------------------------------------------------

-- A cframe's rotation codec is always a rotation; the cast names that for the checker.
local function rotationBitsOf(rotation: Ir.Codec): number
	return (rotation :: any).bits
end

local function writeVector3(
	w: Bits.Writer,
	codec: Ir.Codec,
	x: number,
	y: number,
	z: number
): boolean
	if codec.kind == "vector3" then
		local axis = codec.axis
		local xCode, yCode, zCode = Leaves.vector3Codes(x, y, z, axis)
		if xCode == nil then
			return false
		end

		local width = axis.width
		Bits.write(w, width, xCode)
		Bits.write(w, width, yCode)
		Bits.write(w, width, zCode)
		return true
	end

	local xBits, yBits, zBits = Leaves.vector3f32Bits(x, y, z)
	if xBits == nil then
		return false
	end

	Bits.write(w, 32, xBits)
	Bits.write(w, 32, yBits)
	Bits.write(w, 32, zBits)
	return true
end

local function writeRotation(w: Bits.Writer, value: CFrame, bits: number): boolean
	local flag, index, a, b, c = Leaves.rotationCodes(value, bits)
	if flag == nil then
		return false
	end

	Bits.write(w, 1, flag)
	if flag == 1 then
		Bits.write(w, AXIS_INDEX_BITS, index)
		return true
	end

	Bits.write(w, DROPPED_BITS, index)
	Bits.write(w, bits, a)
	Bits.write(w, bits, b)
	Bits.write(w, bits, c)
	return true
end

local function write(w: Bits.Writer, codec: Ir.Codec, value: any, instances: Instances): Refusal?
	if codec.kind == "record" then
		if typeof(value) ~= "table" then
			return Leaves.refusal(codec, value)
		end

		for _, field in codec.fields do
			local refusal = write(w, field.codec, value[field.name], instances)
			if refusal ~= nil then
				return Leaves.extend(refusal, `.{field.name}`)
			end
		end
	elseif codec.kind == "int" then
		local code = Leaves.intCode(value, codec.min, codec.max)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "bool" then
		if value == true then
			Bits.write(w, 1, 1)
		elseif value == false then
			Bits.write(w, 1, 0)
		else
			return Leaves.refusal(codec, value)
		end
	elseif codec.kind == "enum" then
		local code = codec.index[value]
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "optional" then
		if value == nil then
			Bits.write(w, 1, 0)
			return nil
		end

		Bits.write(w, 1, 1)
		return write(w, codec.inner, value, instances)
	elseif codec.kind == "number" then
		local code = Leaves.numberCode(value, codec)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "string" then
		if typeof(value) ~= "string" or #value > codec.max then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, #value)
		Bits.writeTail(w, value)
	elseif codec.kind == "union" then
		local code = if typeof(value) == "table" then codec.byName[value.kind] else nil
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, code)
		return write(w, codec.variants[code + 1].record, value, instances)
	elseif codec.kind == "vector3" or codec.kind == "vector3f32" then
		if typeof(value) ~= "Vector3" or not writeVector3(w, codec, value.X, value.Y, value.Z) then
			return Leaves.refusal(codec, value)
		end
	elseif codec.kind == "array" then
		if typeof(value) ~= "table" or #value > codec.max then
			return Leaves.refusal(codec, value)
		end

		local count = #value
		Bits.write(w, codec.width, count)
		if count >= Column.MIN_ROWS then
			local refusal = Columns.write(w, codec.inner, value, 1, count, instances)
			return if refusal == nil then nil else Leaves.extend(refusal, "[]")
		end

		local inner = codec.inner
		for i = 1, count do
			local refusal = write(w, inner, value[i], instances)
			if refusal ~= nil then
				return Leaves.extend(refusal, "[]")
			end
		end
	elseif codec.kind == "map" then
		local keys, keysRefusal = Leaves.sortedKeys(codec, value)
		if keys == nil then
			return keysRefusal
		end

		local count = #keys
		Bits.write(w, codec.width, count)
		if count >= Column.MIN_ROWS then
			local values = table.create(count)
			for i, key in keys do
				values[i] = value[key]
			end

			local keyRefusal = Columns.write(w, codec.key, keys, 1, count, instances)
			if keyRefusal ~= nil then
				return Leaves.extend(keyRefusal, "[key]")
			end

			local valueRefusal = Columns.write(w, codec.value, values, 1, count, instances)
			return if valueRefusal == nil then nil else Leaves.extend(valueRefusal, "[]")
		end

		for _, key in keys do
			local keyRefusal = write(w, codec.key, key, instances)
			if keyRefusal ~= nil then
				return Leaves.extend(keyRefusal, "[key]")
			end

			local valueRefusal = write(w, codec.value, value[key], instances)
			if valueRefusal ~= nil then
				return Leaves.extend(valueRefusal, "[]")
			end
		end
	elseif codec.kind == "varint" then
		local code = Leaves.varintCode(value)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Ints.writeEg(w, Ints.zigzag(code), 0)
	elseif codec.kind == "f32" then
		local bits = Leaves.f32Bits(value)
		if bits == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, 32, bits)
	elseif codec.kind == "f64" then
		local low, high = Leaves.f64Bits(value)
		if low == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, 32, low)
		Bits.write(w, 32, high)
	elseif codec.kind == "angle" then
		local code = Leaves.angleCode(value, codec.steps)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, code)
	elseif codec.kind == "buffer" then
		if typeof(value) ~= "buffer" or buffer.len(value) > codec.max then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, codec.width, buffer.len(value))
		Bits.writeTail(w, value)
	elseif codec.kind == "direction" then
		local bits = codec.bits
		local xCode, yCode = Leaves.directionCodes(value, bits)
		if xCode == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, bits, xCode)
		Bits.write(w, bits, yCode)
	elseif codec.kind == "rotation" then
		if
			typeof(value) ~= "CFrame"
			or value.X ~= 0
			or value.Y ~= 0
			or value.Z ~= 0
			or not writeRotation(w, value, codec.bits)
		then
			return Leaves.refusal(codec, value)
		end
	elseif codec.kind == "cframe" then
		if typeof(value) ~= "CFrame" then
			return Leaves.refusal(codec, value)
		end

		local position = codec.position
		if not writeVector3(w, position, value.X, value.Y, value.Z) then
			return Leaves.extend(Leaves.refusal(position, value.Position), ".position")
		end

		if not writeRotation(w, value, rotationBitsOf(codec.rotation)) then
			return Leaves.extend(Leaves.refusal(codec.rotation, value.Rotation), ".rotation")
		end
	elseif codec.kind == "color3" then
		local red, green, blue = Leaves.color3Codes(value)
		if red == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, COLOR_BITS, red)
		Bits.write(w, COLOR_BITS, green)
		Bits.write(w, COLOR_BITS, blue)
	elseif codec.kind == "robloxEnum" then
		local code = Leaves.robloxEnumCode(value, codec.byValue)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Ints.writeEg(w, Ints.zigzag(code), 0)
	elseif codec.kind == "instance" then
		local code = Leaves.instanceCode(value, codec.class, instances)
		if code == nil then
			return Leaves.refusal(codec, value)
		end
		Bits.write(w, Leaves.instanceWidth(#instances.list), code)
	elseif codec.kind == "custom" then
		return Leaves.writeCustom(w, codec, value)
	elseif codec.kind == "convert" then
		return write(w, codec.base, codec.encode(value), instances)
	end

	return nil
end

-- Returns nil and the rule, in place of x and y, on refusal.
local function readVector3(r: Bits.Reader, codec: Ir.Codec): (number?, number, number)
	if codec.kind == "vector3" then
		local axis = codec.axis
		local width, steps = axis.width, axis.steps
		local xCode = Bits.read(r, width)
		local yCode = Bits.read(r, width)
		local zCode = Bits.read(r, width)
		if xCode == nil or yCode == nil or zCode == nil then
			return nil, 4, 0
		end

		if xCode > steps or yCode > steps or zCode > steps then
			return nil, 2, 0
		end

		local min, step, max = axis.min, axis.step, axis.max
		return Quant.unnumber(xCode, min, step, max),
			Quant.unnumber(yCode, min, step, max),
			Quant.unnumber(zCode, min, step, max)
	end

	local xBits = Bits.read(r, 32)
	local yBits = Bits.read(r, 32)
	local zBits = Bits.read(r, 32)
	if xBits == nil or yBits == nil or zBits == nil then
		return nil, 4, 0
	end

	local x = Leaves.f32Of(xBits)
	local y = Leaves.f32Of(yBits)
	local z = Leaves.f32Of(zBits)
	if x == nil or y == nil or z == nil then
		return nil, 3, 0
	end

	return x, y, z
end

local function readRotation(
	r: Bits.Reader,
	bits: number,
	x: number,
	y: number,
	z: number
): (CFrame?, number)
	local flag = Bits.read(r, 1)
	if flag == nil then
		return nil, 4
	end

	local index, a, b, c = 0, 0, 0, 0
	if flag == 1 then
		local axisIndex = Bits.read(r, AXIS_INDEX_BITS)
		if axisIndex == nil then
			return nil, 4
		end

		if axisIndex >= AXIS_COUNT then
			return nil, 2
		end
		index = axisIndex
	else
		local dropped = Bits.read(r, DROPPED_BITS)
		local aCode = Bits.read(r, bits)
		local bCode = Bits.read(r, bits)
		local cCode = Bits.read(r, bits)
		if dropped == nil or aCode == nil or bCode == nil or cCode == nil then
			return nil, 4
		end
		index, a, b, c = dropped, aCode, bCode, cCode
	end

	if not Leaves.canonicalRotation(flag, index, a, b, c, bits) then
		return nil, 6
	end

	-- Cast: canonical codes decode.
	return Leaves.rotationOf(flag, index, a, b, c, bits, x, y, z) :: CFrame, 0
end

local function read(r: Bits.Reader, codec: Ir.Codec, instances: { Instance? }): (any, number)
	if codec.kind == "record" then
		local record = Leaves.newRecord(codec.fields)
		for _, field in codec.fields do
			local value, rule = read(r, field.codec, instances)
			if rule ~= 0 then
				return nil, rule
			end
			record[field.name] = value
		end
		return record, 0
	elseif codec.kind == "int" then
		local code = Bits.read(r, codec.width)
		if code == nil then
			return nil, 4
		end

		local value = code + codec.min
		if value > codec.max then
			return nil, 3
		end
		return value, 0
	elseif codec.kind == "bool" then
		local code = Bits.read(r, 1)
		if code == nil then
			return nil, 4
		end
		return code == 1, 0
	elseif codec.kind == "enum" then
		local code = Bits.read(r, codec.width)
		if code == nil then
			return nil, 4
		end

		local item = codec.items[code + 1]
		if item == nil then
			return nil, 2
		end
		return item, 0
	elseif codec.kind == "optional" then
		local presence = Bits.read(r, 1)
		if presence == nil then
			return nil, 4
		end

		if presence == 0 then
			return nil, 0
		end
		return read(r, codec.inner, instances)
	elseif codec.kind == "number" then
		local code = Bits.read(r, codec.width)
		if code == nil then
			return nil, 4
		end

		if code > codec.steps then
			return nil, 2
		end
		return Quant.unnumber(code, codec.min, codec.step, codec.max), 0
	elseif codec.kind == "string" or codec.kind == "buffer" then
		local length = Bits.read(r, codec.width)
		if length == nil then
			return nil, 4
		end

		if length > codec.max then
			return nil, 2
		end

		local value = Bits.readTail(r, length, codec.kind == "buffer")
		if value == nil then
			return nil, 4
		end
		return value, 0
	elseif codec.kind == "union" then
		local code = Bits.read(r, codec.width)
		if code == nil then
			return nil, 4
		end

		local variant = codec.variants[code + 1]
		if variant == nil then
			return nil, 2
		end

		-- A union variant's record codec is always a record; the cast names that for the checker.
		local fields: { Ir.Field } = (variant.record :: any).fields
		local record = Leaves.newRecord(fields, variant)
		for _, field in fields do
			local value, rule = read(r, field.codec, instances)
			if rule ~= 0 then
				return nil, rule
			end
			record[field.name] = value
		end
		return record, 0
	elseif codec.kind == "vector3" or codec.kind == "vector3f32" then
		local x, y, z = readVector3(r, codec)
		if x == nil then
			return nil, y
		end
		return Vector3.new(x, y, z), 0
	elseif codec.kind == "array" then
		local count = Bits.read(r, codec.width)
		if count == nil then
			return nil, 4
		end

		if count > codec.max then
			return nil, 2
		end

		local array = table.create(count)
		if count >= Column.MIN_ROWS then
			local rule = Columns.read(r, codec.inner, count, instances, array)
			if rule ~= 0 then
				return nil, rule
			end
			return array, 0
		end

		local inner = codec.inner
		for i = 1, count do
			local value, rule = read(r, inner, instances)
			if rule ~= 0 then
				return nil, rule
			end
			array[i] = value
		end
		return array, 0
	elseif codec.kind == "map" then
		local count = Bits.read(r, codec.width)
		if count == nil then
			return nil, 4
		end

		if count > codec.max then
			return nil, 2
		end

		local keyCodec = codec.key
		local valueCodec = codec.value
		local map = {}
		if count >= Column.MIN_ROWS then
			local keys = table.create(count)
			local rule = Columns.read(r, keyCodec, count, instances, keys)
			if rule ~= 0 then
				return nil, rule
			end

			local values = table.create(count)
			rule = Columns.read(r, valueCodec, count, instances, values)
			if rule ~= 0 then
				return nil, rule
			end

			for i, key in keys do
				if i > 1 and not Leaves.isAscending(keyCodec, keys[i - 1], key) then
					return nil, 5
				end
				map[key] = values[i]
			end
			return map, 0
		end

		local previous = nil
		for i = 1, count do
			local key, keyRule = read(r, keyCodec, instances)
			if keyRule ~= 0 then
				return nil, keyRule
			end

			if i > 1 and not Leaves.isAscending(keyCodec, previous, key) then
				return nil, 5
			end

			local value, valueRule = read(r, valueCodec, instances)
			if valueRule ~= 0 then
				return nil, valueRule
			end
			map[key] = value
			previous = key
		end
		return map, 0
	elseif codec.kind == "varint" then
		local code, rule = Ints.readEg(r, 0)
		if code == nil then
			return nil, rule
		end
		return Ints.unzigzag(code), 0
	elseif codec.kind == "f32" then
		local bits = Bits.read(r, 32)
		if bits == nil then
			return nil, 4
		end

		local value = Leaves.f32Of(bits)
		if value == nil then
			return nil, 3
		end
		return value, 0
	elseif codec.kind == "f64" then
		local low = Bits.read(r, 32)
		local high = Bits.read(r, 32)
		if low == nil or high == nil then
			return nil, 4
		end

		local value = Leaves.f64Of(low, high)
		if value == nil then
			return nil, 3
		end
		return value, 0
	elseif codec.kind == "angle" then
		local code = Bits.read(r, codec.width)
		if code == nil then
			return nil, 4
		end

		if code >= codec.steps then
			return nil, 2
		end
		return Quant.unangle(code, codec.steps), 0
	elseif codec.kind == "direction" then
		local bits = codec.bits
		local xCode = Bits.read(r, bits)
		local yCode = Bits.read(r, bits)
		if xCode == nil or yCode == nil then
			return nil, 4
		end
		return Leaves.directionOf(xCode, yCode, bits), 0
	elseif codec.kind == "rotation" then
		return readRotation(r, codec.bits, 0, 0, 0)
	elseif codec.kind == "cframe" then
		local x, y, z = readVector3(r, codec.position)
		if x == nil then
			return nil, y
		end

		return readRotation(r, rotationBitsOf(codec.rotation), x, y, z)
	elseif codec.kind == "color3" then
		local red = Bits.read(r, COLOR_BITS)
		local green = Bits.read(r, COLOR_BITS)
		local blue = Bits.read(r, COLOR_BITS)
		if red == nil or green == nil or blue == nil then
			return nil, 4
		end
		return Leaves.color3Of(red, green, blue), 0
	elseif codec.kind == "robloxEnum" then
		local code, rule = Ints.readEg(r, 0)
		if code == nil then
			return nil, rule
		end
		return codec.byValue[Ints.unzigzag(code)], 0
	elseif codec.kind == "instance" then
		local index = Bits.read(r, Leaves.instanceWidth(#instances))
		if index == nil then
			return nil, 4
		end
		return Leaves.instanceOf(instances, index, codec.class)
	elseif codec.kind == "custom" then
		return codec.decode(r)
	elseif codec.kind == "convert" then
		local value, rule = read(r, codec.base, instances)
		if rule ~= 0 then
			return nil, rule
		end
		return codec.decode(value), 0
	end

	return nil, 0
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Encodes a value as one row, or raises `valueRefused` at the caller's line.

	@param w         the writer, unchanged when the value is refused
	@param codec     the value's codec, a definition's `data`
	@param value     the value
	@param instances the chunk's instances, collected beforehand (`Run.collect`)
	@param subject   the definition and call, such as `arena.buy:invoke`
	@error valueRefused, naming `subject` and the value's path from `data`
]=]
function Rows.encodeValue(
	w: Bits.Writer,
	codec: Ir.Codec,
	value: any,
	instances: Instances,
	subject: string
)
	local startBit = w.bit
	local startTailCount = #w.tail
	local startTailBytes = w.tailBytes
	local refusal = write(w, codec, value, instances)
	if refusal == nil then
		return
	end

	Leaves.reset(w, startBit, startTailCount, startTailBytes)
	Leaves.raise(refusal, subject)
end

--[=[
	Decodes one row.

	A chunk's instance list is checked whole (rule 9) by `Run.decode`; reading a row checks only
	that indices reference its entries in order of first reference.

	@param  r         the reader
	@param  codec     the row's codec
	@param  instances the chunk's instance list; a missing instance is nil
	@return the value, or nil on refusal; an unknown Roblox enum value, a nil instance and an
	        instance of the wrong class also decode to nil (milestone 2's `unresolved`)
	@return 0, or the v5.md §4.8 rule that refuses the row
]=]
function Rows.read(r: Bits.Reader, codec: Ir.Codec, instances: { Instance? }): (any, number)
	return read(r, codec, instances)
end

--[=[
	Encodes a value as one row.

	@param  w         the writer
	@param  codec     the value's codec
	@param  value     the value
	@param  instances the chunk's instances, extended on first references
	@return nil, or the refusal; the writer then holds part of the row
]=]
function Rows.write(w: Bits.Writer, codec: Ir.Codec, value: any, instances: Instances): Refusal?
	return write(w, codec, value, instances)
end

return table.freeze(Rows)
