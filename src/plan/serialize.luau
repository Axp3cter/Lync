--!strict

--[=[
	Serialize

	The canonical serialization of a planned schema and its hash (v5.md §4.7, §4.6): the bytes
	both ends hash to agree that they run the same schema.

	Everything is little-endian. A `str` is a u16 length and the bytes; a `num` is the f64 bits,
	with -0 written as 0. The planner refuses NaN and infinities before anything is serialized.
	Golden vector G6 (v5.md §4.10) fixes the bytes and the hash.
]=]


-- Imports -----------------------------------------------------------------------------------------

local HalfSipHash = require("../wire/halfsiphash")
local Ir = require("./ir")


-- Module ------------------------------------------------------------------------------------------

local Serialize = {}


-- Constants ---------------------------------------------------------------------------------------

const VERSION = 1

const ZERO_KEY = buffer.create(8)

const KIND_CODE: { [string]: number } = { event = 1, request = 2, collection = 3 }
table.freeze(KIND_CODE)

const FROM_CODE: { [string]: number } = { client = 1, server = 2 }
table.freeze(FROM_CODE)

const LANE_CODE: { [string]: number } = { reliable = 1, unreliable = 2 }
table.freeze(LANE_CODE)

const CODEC_TYPE: { [string]: number } = {
	bool = 1,
	int = 2,
	varint = 3,
	number = 4,
	f32 = 5,
	f64 = 6,
	angle = 7,
	string = 8,
	buffer = 9,
	vector3 = 10,
	vector3f32 = 11,
	direction = 12,
	rotation = 13,
	cframe = 14,
	color3 = 15,
	enum = 16,
	robloxEnum = 17,
	instance = 18,
	optional = 19,
	array = 20,
	map = 21,
	union = 22,
	record = 23,
	custom = 24,
	convert = 25,
}
table.freeze(CODEC_TYPE)


-- Private -----------------------------------------------------------------------------------------

local function writeU8(parts: { string }, value: number)
	table.insert(parts, string.pack("B", value))
end


local function writeU16(parts: { string }, value: number)
	table.insert(parts, string.pack("<I2", value))
end


local function writeNum(parts: { string }, value: number)
	-- -0 == 0, so this writes +0 for both.
	local canonical = if value == 0 then 0 else value
	table.insert(parts, string.pack("<d", canonical))
end


local function writeStr(parts: { string }, text: string)
	writeU16(parts, #text)
	table.insert(parts, text)
end


-- Kinds the chain leaves out have no parameters.
local function writeCodec(parts: { string }, codec: Ir.Codec)
	writeU8(parts, CODEC_TYPE[codec.kind])

	if codec.kind == "int" then
		writeNum(parts, codec.min)
		writeNum(parts, codec.max)
	elseif codec.kind == "number" then
		writeNum(parts, codec.min)
		writeNum(parts, codec.max)
		writeNum(parts, codec.step)
	elseif codec.kind == "angle" then
		writeNum(parts, codec.step)
	elseif codec.kind == "string" or codec.kind == "buffer" then
		writeNum(parts, codec.max)
	elseif codec.kind == "vector3" then
		local axis = codec.axis
		writeNum(parts, axis.min)
		writeNum(parts, axis.max)
		writeNum(parts, axis.step)
	elseif codec.kind == "direction" or codec.kind == "rotation" then
		writeNum(parts, codec.bits)
	elseif codec.kind == "cframe" then
		writeCodec(parts, codec.position)
		writeCodec(parts, codec.rotation)
	elseif codec.kind == "enum" then
		writeU16(parts, #codec.items)
		for _, item in codec.items do
			writeStr(parts, item)
		end
	elseif codec.kind == "robloxEnum" then
		writeStr(parts, codec.name)
	elseif codec.kind == "instance" then
		writeStr(parts, codec.class or "")
	elseif codec.kind == "optional" then
		writeCodec(parts, codec.inner)
	elseif codec.kind == "array" then
		writeCodec(parts, codec.inner)
		writeNum(parts, codec.max)
	elseif codec.kind == "map" then
		writeCodec(parts, codec.key)
		writeCodec(parts, codec.value)
		writeNum(parts, codec.max)
	elseif codec.kind == "union" then
		writeU16(parts, #codec.variants)
		for _, variant in codec.variants do
			writeStr(parts, variant.name)
			writeCodec(parts, variant.record)
		end
	elseif codec.kind == "record" then
		writeU16(parts, #codec.fields)
		for _, field in codec.fields do
			writeStr(parts, field.name)
			writeCodec(parts, field.codec)
			writeU8(parts, if field.newest then 1 else 0)
		end
	elseif codec.kind == "custom" then
		writeStr(parts, codec.name)
		writeNum(parts, codec.version)
	elseif codec.kind == "convert" then
		writeCodec(parts, codec.base)
	end
end


local function writeOptionalCodec(parts: { string }, codec: Ir.Codec?)
	if codec == nil then
		writeU8(parts, 0)
		return
	end

	writeU8(parts, 1)
	writeCodec(parts, codec)
end


local function writeOptionalNum(parts: { string }, value: number?)
	if value == nil then
		writeU8(parts, 0)
		return
	end

	writeU8(parts, 1)
	writeNum(parts, value)
end


local function writeDefinition(parts: { string }, definition: Ir.Definition)
	local isRequest = definition.kind == "request"
	local isCollection = definition.kind == "collection"
	local limit = definition.limit

	writeStr(parts, definition.name)
	writeU8(parts, KIND_CODE[definition.kind])
	writeU8(parts, FROM_CODE[definition.from])
	writeU8(parts, LANE_CODE[definition.lane])

	writeOptionalCodec(parts, definition.data)
	writeOptionalCodec(parts, definition.reply)
	writeOptionalCodec(parts, definition.key)
	writeOptionalNum(parts, if limit == nil then nil else limit.perSecond)
	writeOptionalNum(parts, if limit == nil then nil else limit.burst)
	writeOptionalNum(parts, if isRequest then definition.timeout else nil)
	writeOptionalNum(parts, if isCollection then definition.maxRecords else nil)
	writeOptionalNum(parts, if isCollection then definition.priority else nil)
	writeOptionalNum(parts, definition.reliableRate)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns the canonical serialization of a planned schema (v5.md §4.7).

	Options that take a default (`timeout`, `maxRecords`, `priority`, `limit.burst`) are written
	with their resolved value, since every value of the schema is hashed; options a definition's
	kind does not take are absent.

	@param  namespace the planned schema; its own serialization and hash are not read
	@return the bytes
]=]
function Serialize.bytes(namespace: Ir.Namespace): buffer
	local parts: { string } = {}
	writeU8(parts, VERSION)
	writeStr(parts, namespace.name)
	writeU16(parts, #namespace.definitions)
	for _, definition in namespace.definitions do
		writeDefinition(parts, definition)
	end

	return buffer.fromstring(table.concat(parts))
end


--[=[
	Hashes a serialization: HalfSipHash-2-4 with a zero key and a 64-bit output (v5.md §4.6).

	@param  bytes the serialization
	@return the low u32 of the hash
	@return the high u32 of the hash
]=]
function Serialize.hash(bytes: buffer): (number, number)
	return HalfSipHash.hash(ZERO_KEY, bytes, 0, buffer.len(bytes), 2, 4, 8)
end


return table.freeze(Serialize)
