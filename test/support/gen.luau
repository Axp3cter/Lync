--!strict

--[=[
	Gen

	Random values for an `Ir.Codec`, and random codecs, for property tests. Randomness is
	`math.random`, so `Prop.check`'s seed replays a run.

	Values are generated as their codec decodes them: a quantized number is min + q·step, a
	direction or rotation is the decoding of its codes, an f32 is already rounded. A round trip
	then gives back exactly the value generated.

	A `t.custom` is taken to code an unsigned integer of `maxBits` bits; a `t.convert` value is
	generated as its base value, then decoded.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Column = require("../../src/wire/column")
local Ir = require("../../src/plan/ir")
local Leaves = require("../../src/codec/leaves")
local Lync = require("../../src")
local Quant = require("../../src/wire/quant")

-- Module ------------------------------------------------------------------------------------------

local Gen = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	How values are drawn.

	@field absentChance how often an optional is absent, 0 to 1
	@field variantCount how many of a union's first variants are used; nil for all
	@field instances    the instances a `t.instance` value is drawn from
]=]
export type Style = {
	absentChance: number,
	variantCount: number?,
	instances: { Instance },
}

-- Constants ---------------------------------------------------------------------------------------

const MAX_F32 = 3.4028234663852886e38
const MAX_ELEMENTS = 2 * Column.MIN_ROWS + 1
const FLOAT_SCRATCH = buffer.create(4)

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function chance(probability: number): boolean
	return math.random() < probability
end

local function integerBetween(min: number, max: number): number
	if max - min < 2 ^ 31 then
		return math.random(0, max - min) + min
	end

	local span = max - min + 1
	local bitCount = math.random(0, math.ceil(math.log(span, 2)))
	local offset = math.floor(math.random() * 2 ^ bitCount)
	return min + math.min(offset, max - min)
end

local function codeBelow(n: number): number
	local roll = math.random(1, 8)
	if roll == 1 then
		return 0
	elseif roll == 2 then
		return n - 1
	end

	return integerBetween(0, n - 1)
end

local function f32Near(value: number): number
	buffer.writef32(FLOAT_SCRATCH, 0, value)

	return buffer.readf32(FLOAT_SCRATCH, 0)
end

local function randomF32(): number
	local roll = math.random(1, 8)
	if roll == 1 then
		return if chance(0.5) then MAX_F32 else -MAX_F32
	elseif roll == 2 then
		return 0
	end

	return f32Near((math.random() * 2 - 1) * 2 ^ math.random(-40, 40))
end

local function randomF64(): number
	if chance(0.1) then
		return 0
	end

	return (math.random() * 2 - 1) * 2 ^ math.random(-1000, 1000)
end

local function randomBytes(length: number): string
	local bytes = table.create(length, "")
	for i = 1, length do
		bytes[i] = string.char(math.random(0, 255))
	end

	return table.concat(bytes)
end

local function lengthUpTo(max: number, size: number): number
	return math.random(0, math.min(max, size))
end

local function numberOf(codec: Ir.NumberCodec): number
	return Quant.unnumber(codeBelow(codec.steps + 1), codec.min, codec.step)
end

local function rotationOf(bits: number): CFrame
	if chance(0.25) then
		return Leaves.rotationOf(1, math.random(0, 23), 0, 0, 0, bits, 0, 0, 0) :: CFrame
	end

	-- Smallest-three is not idempotent: a decoded kept component can outgrow the recomputed
	-- dropped one (1.5% of codes at 7 bits, 0.02% at 15), so the next encoding drops another. Only
	-- rotations that re-encode to their own codes are drawn.
	while true do
		local x, y, z, w =
			math.random() - 0.5, math.random() - 0.5, math.random() - 0.5, math.random() - 0.5
		local length = math.sqrt(x * x + y * y + z * z + w * w)
		local raw = CFrame.new(0, 0, 0, x / length, y / length, z / length, w / length)
		local flag, index, a, b, c = Leaves.rotationCodes(raw, bits)
		local rotation = Leaves.rotationOf(flag :: number, index, a, b, c, bits, 0, 0, 0) :: CFrame
		local _, decodedIndex = Leaves.rotationCodes(rotation, bits)
		if decodedIndex == index then
			return rotation
		end
	end
end

local function positionOf(codec: Ir.Codec): Vector3
	if codec.kind == "vector3" then
		return Vector3.new(numberOf(codec.axis), numberOf(codec.axis), numberOf(codec.axis))
	end

	return Vector3.new(randomF32(), randomF32(), randomF32())
end

local function instanceOf(class: string?, style: Style): Instance
	local candidates = {}
	for _, instance in style.instances do
		if class == nil or instance:IsA(class) then
			table.insert(candidates, instance)
		end
	end

	return candidates[math.random(1, #candidates)]
end

local function leafCodec(size: number): any
	local roll = math.random(1, 22)
	if roll == 1 then
		return t.bool()
	elseif roll == 2 then
		local min = integerBetween(-2 ^ 52, 2 ^ 52 - 1)
		local span = if chance(0.5) then math.random(0, 300) else integerBetween(0, 2 ^ 52 - 1)
		return t.int(min, math.min(min + span, 2 ^ 52 - 1))
	elseif roll == 3 then
		return t.int()
	elseif roll == 4 then
		return t.number(-64, 64, 1 / 8)
	elseif roll == 5 then
		return t.f32()
	elseif roll == 6 then
		return t.f64()
	elseif roll == 7 then
		return t.angle(math.rad(math.random(1, 90)))
	elseif roll == 8 then
		return t.string(math.random(1, 12))
	elseif roll == 9 then
		return t.buffer(math.random(1, 12))
	elseif roll == 10 then
		return t.vector3(-2048, 2048, 1 / 32)
	elseif roll == 11 then
		return t.vector3f32()
	elseif roll == 12 then
		return t.direction(math.random(8, 16))
	elseif roll == 13 then
		return t.rotation(math.random(7, 15))
	elseif roll == 14 then
		return t.cframe(t.vector3(-1024, 1024, 1 / 64), t.rotation(math.random(7, 15)))
	elseif roll == 15 then
		return t.cframe(t.vector3f32(), t.rotation(math.random(7, 15)))
	elseif roll == 16 then
		return t.color3()
	elseif roll == 17 then
		local items = {}
		for i = 1, math.random(1, 5) do
			items[i] = `item{i}`
		end
		return t.enum(items)
	elseif roll == 18 then
		return t.enum(Enum.Material)
	elseif roll == 19 then
		return if chance(0.5) then t.instance() else t.instance("BasePart")
	elseif roll == 20 then
		return Gen.custom()
	elseif roll == 21 then
		return t.convert(t.int(0, 255), string.char, string.byte)
	end

	return t.int(0, math.min(size, 100))
end

local function keyCodec(): any
	local roll = math.random(1, 4)
	if roll == 1 then
		return t.int(-50, 50)
	elseif roll == 2 then
		return t.int()
	elseif roll == 3 then
		return t.enum({ "a", "b", "c", "d", "e", "f" })
	end

	return t.string(4)
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns a random codec from the DSL, nested to at most `depth` levels.

	@param  depth how many levels of optional, array, map, union and record may wrap the leaves
	@param  size  how large its parameters may grow
	@return the codec or record, for `Gen.plan`
]=]
function Gen.codec(depth: number, size: number): any
	if depth <= 0 or chance(0.3) then
		return leafCodec(size)
	end

	local roll = math.random(1, 5)
	if roll == 1 then
		return t.optional(Gen.codec(depth - 1, size))
	elseif roll == 2 then
		return t.array(Gen.codec(depth - 1, size), math.random(1, MAX_ELEMENTS))
	elseif roll == 3 then
		return t.map(keyCodec(), Gen.codec(depth - 1, size), math.random(1, MAX_ELEMENTS))
	elseif roll == 4 then
		local variants = {}
		for i = 1, math.random(1, 3) do
			local record = {}
			for j = 1, math.random(0, 2) do
				record[`field{j}`] = Gen.codec(depth - 1, size)
			end
			variants[`variant{i}`] = record
		end
		return t.union(variants)
	end

	local record = {}
	for i = 1, math.random(1, 4) do
		record[`field{i}`] = Gen.codec(depth - 1, size)
	end
	return record
end

--[=[
	Returns a `t.custom` codec of an unsigned 10-bit integer.

	@return the codec
]=]
function Gen.custom(): any
	return t.custom({
		name = "u10",
		version = 1,
		maxBits = 10,
		encode = function(w, value: number)
			Bits.write(w, 10, value)
		end,
		decode = function(r): (number?, number)
			local value = Bits.read(r, 10)
			if value == nil then
				return nil, 4
			end
			return value, 0
		end,
	})
end

--[=[
	Plans a codec as the data of an event.

	@param  codec the codec or record
	@return its IR
]=]
function Gen.plan(codec: any): Ir.Codec
	local schema = Lync.schema("gen", { e = Lync.event({ from = "client", data = codec }) })

	return (schema :: any).ir.byName.e.data
end

--[=[
	Returns a style that draws from every case.

	@param  instances the instances that `t.instance` values are drawn from
	@return the style
]=]
function Gen.style(instances: { Instance }): Style
	local roll = math.random(1, 4)

	return {
		absentChance = if roll == 1 then 1 elseif roll == 2 then 0 else 0.4,
		variantCount = if roll == 3 then 1 else nil,
		instances = instances,
	}
end

--[=[
	Returns a random value of a codec, as the codec decodes it.

	@param  codec the codec
	@param  size  how large arrays, maps and strings may grow
	@param  style how optionals, unions and instances are drawn
	@return the value
]=]
function Gen.value(codec: Ir.Codec, size: number, style: Style): any
	if codec.kind == "bool" then
		return chance(0.5)
	elseif codec.kind == "int" then
		return codec.min + codeBelow(codec.max - codec.min + 1)
	elseif codec.kind == "varint" then
		return integerBetween(-2 ^ 52, 2 ^ 52 - 1)
	elseif codec.kind == "number" then
		return numberOf(codec)
	elseif codec.kind == "f32" then
		return randomF32()
	elseif codec.kind == "f64" then
		return randomF64()
	elseif codec.kind == "angle" then
		return Quant.unangle(codeBelow(codec.steps), codec.steps)
	elseif codec.kind == "string" then
		return randomBytes(lengthUpTo(codec.max, size))
	elseif codec.kind == "buffer" then
		return buffer.fromstring(randomBytes(lengthUpTo(codec.max, size)))
	elseif codec.kind == "vector3" or codec.kind == "vector3f32" then
		return positionOf(codec)
	elseif codec.kind == "direction" then
		local maxCode = 2 ^ codec.bits
		return Leaves.directionOf(codeBelow(maxCode), codeBelow(maxCode), codec.bits)
	elseif codec.kind == "rotation" then
		return rotationOf(codec.bits)
	elseif codec.kind == "cframe" then
		return rotationOf((codec.rotation :: any).bits) + positionOf(codec.position)
	elseif codec.kind == "color3" then
		return Leaves.color3Of(codeBelow(256), codeBelow(256), codeBelow(256))
	elseif codec.kind == "enum" then
		return codec.items[math.random(1, #codec.items)]
	elseif codec.kind == "robloxEnum" then
		local items = {}
		for _, item in codec.byValue do
			table.insert(items, item)
		end
		return items[math.random(1, #items)]
	elseif codec.kind == "instance" then
		return instanceOf(codec.class, style)
	elseif codec.kind == "optional" then
		if chance(style.absentChance) then
			return nil
		end
		return Gen.value(codec.inner, size, style)
	elseif codec.kind == "array" then
		-- An absent element would leave a hole, and an array's length is then any border.
		local inner = codec.inner
		local elementStyle = if inner.kind == "optional"
			then { absentChance = 0, variantCount = style.variantCount, instances = style.instances }
			else style
		local array = {}
		for i = 1, lengthUpTo(codec.max, size) do
			array[i] = Gen.value(inner, size, elementStyle)
		end
		return array
	elseif codec.kind == "map" then
		local map = {}
		for _ = 1, lengthUpTo(codec.max, size) do
			map[Gen.value(codec.key, size, style)] = Gen.value(codec.value, size, style)
		end
		return map
	elseif codec.kind == "union" then
		local variantCount = math.min(style.variantCount or #codec.variants, #codec.variants)
		local variant = codec.variants[math.random(1, variantCount)]
		local value = Gen.value(variant.record, size, style)
		value.kind = variant.name
		return value
	elseif codec.kind == "record" then
		local record = {}
		for _, field in codec.fields do
			record[field.name] = Gen.value(field.codec, size, style)
		end
		return record
	elseif codec.kind == "custom" then
		return math.random(0, 2 ^ codec.maxBits - 1)
	elseif codec.kind == "convert" then
		return codec.decode(Gen.value(codec.base, size, style))
	end

	error(`Gen.value must know the codec kind {codec.kind}`)
end

return table.freeze(Gen)
