--!strict

--[=[
	Dsl

	The schema language: the codec constructors of v5.md §3.3 (the `t` table) and the definition
	constructors of §3.4.

	Each constructor records the line it was called from (`debug.info(2, "sl")`, the line where
	the call starts) and checks its own arguments, raising declaration errors there. Values are
	frozen. A codec value is a table with a shared metatable whose one method, `:newest()`,
	returns a copy marked newest; a record is a plain table of codecs. Definitions are checked by
	the planner, which knows their names.

	The values are typed for users by `types.luau`; here every argument is `unknown`, since it
	comes from user code.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Fail = require("../diag/fail")
local Quant = require("../wire/quant")


-- Module ------------------------------------------------------------------------------------------

local Dsl = {}
local Codecs = {}
local CodecMethods = {}


-- Types -------------------------------------------------------------------------------------------

--- A codec's arguments, checked; widths are left to the planner.
export type Node =
	| { kind: "bool" }
	| { kind: "int", min: number, max: number }
	| { kind: "varint" }
	| { kind: "number", min: number, max: number, step: number, steps: number }
	| { kind: "f32" }
	| { kind: "f64" }
	| { kind: "angle", step: number, steps: number }
	| { kind: "string", max: number }
	| { kind: "buffer", max: number }
	| { kind: "vector3", min: number, max: number, step: number, steps: number }
	| { kind: "vector3f32" }
	| { kind: "direction", bits: number }
	| { kind: "rotation", bits: number }
	| { kind: "cframe", position: Codec, rotation: Codec }
	| { kind: "color3" }
	| { kind: "enum", items: { string } }
	| { kind: "robloxEnum", name: string, byValue: { [number]: EnumItem } }
	| { kind: "instance", class: string? }
	| { kind: "optional", inner: Part }
	| { kind: "array", inner: Part, max: number }
	| { kind: "map", key: Codec, value: Part, max: number }
	| { kind: "union", variants: { [unknown]: unknown } }
	| {
		kind: "custom",
		name: string,
		version: number,
		maxBits: number,
		maxBytes: number,
		encode: (any, any) -> (),
		decode: (any) -> (any, number),
	}
	| { kind: "convert", base: Part, decode: (any) -> any, encode: (any) -> any }


--[=[
	A codec value.

	@field node     the codec's checked arguments
	@field line     where its constructor was called
	@field source   the source of that call
	@field isNewest whether it was declared with `:newest()`
]=]
export type Codec = {
	node: Node,
	line: number,
	source: string,
	isNewest: boolean,
}


--- A codec, or a record: a plain table of parts by field name, checked by the planner.
export type Part = Codec | { [unknown]: unknown }


--[=[
	A definition value, before the planner checks its options.

	@field kind    which constructor made it
	@field options a frozen copy of the options it was given
	@field line    where the constructor was called
	@field source  the source of that call
]=]
export type Declaration = {
	kind: "event" | "request" | "collection",
	options: { [unknown]: unknown },
	line: number,
	source: string,
}


-- Constants ---------------------------------------------------------------------------------------

const MIN_INT = -2 ^ 52
const MAX_INT = 2 ^ 52 - 1
const MAX_NUMBER_STEPS = 2 ^ 53 - 1
const MAX_ANGLE_STEPS = 2 ^ 53
const MAX_COUNT = 65_535

const CODEC_METATABLE = table.freeze({ __index = CodecMethods })

const CUSTOM_OPTIONS = "encode, decode, maxBits, maxBytes, luauType, tsType, name or version"

const IS_CUSTOM_OPTION: { [string]: boolean } = {
	encode = true,
	decode = true,
	maxBits = true,
	maxBytes = true,
	luauType = true,
	tsType = true,
	name = true,
	version = true,
}
table.freeze(IS_CUSTOM_OPTION)

const IS_MAP_KEY_KIND: { [string]: boolean } = {
	int = true,
	varint = true,
	enum = true,
	string = true,
}
table.freeze(IS_MAP_KEY_KIND)


-- Private -----------------------------------------------------------------------------------------

local function atOf(source: string, line: number): Fail.At
	return { line = line, source = source }
end


local function codecOf(node: Node, at: Fail.At): Codec
	local codec = {
		node = table.freeze(node),
		line = at.line,
		source = at.source,
		isNewest = false,
	}

	return table.freeze(setmetatable(codec, CODEC_METATABLE)) :: any
end


-- The casts are for the old solver, whose `getmetatable` takes no `unknown`.
local function isCodec(value: unknown): boolean
	return typeof(value) == "table" and getmetatable(value :: any) == CODEC_METATABLE
end


local function isRecord(value: unknown): boolean
	return typeof(value) == "table" and getmetatable(value :: any) == nil
end


local function toInteger(value: unknown): number?
	if typeof(value) ~= "number" or not math.isfinite(value) or math.floor(value) ~= value then
		return nil
	end

	return value
end


local function toFinite(value: unknown): number?
	if typeof(value) ~= "number" or not math.isfinite(value) then
		return nil
	end

	return value
end


local function toName(value: unknown): string?
	if typeof(value) ~= "string" or #value < 1 or #value > MAX_COUNT then
		return nil
	end

	return value
end


local function toCount(value: unknown, at: Fail.At, subject: string): number
	local count = toInteger(value)
	if count == nil or count < 1 or count > MAX_COUNT then
		return Fail.declaration("paramRange", at, subject, "be an integer from 1 to 65535", value)
	end

	return count
end


local function toBits(
	value: unknown,
	at: Fail.At,
	subject: string,
	min: number,
	max: number
): number
	local bits = toInteger(value)
	if bits == nil or bits < min or bits > max then
		return Fail.declaration("paramRange", at, subject, `be an integer from {min} to {max}`, value)
	end

	return bits
end


local function toPart(value: unknown, at: Fail.At, subject: string): Part
	if not isCodec(value) and not isRecord(value) then
		return Fail.declaration("notACodec", at, subject, "be a codec or a record of codecs", value)
	end

	return value :: Part
end


local function toCodec(value: unknown, at: Fail.At, subject: string): Codec
	if not isCodec(value) then
		return Fail.declaration("notACodec", at, subject, "be a codec", value)
	end

	return value :: Codec
end


local function toFunction(value: unknown, at: Fail.At, subject: string): (...any) -> ...any
	if typeof(value) ~= "function" then
		return Fail.declaration("paramRange", at, subject, "be a function", value)
	end

	return value :: any
end


-- Checks `t.number` and `t.vector3` arguments, which share their rules (v5.md §3.3).
local function quantizedNode(
	kind: "number" | "vector3",
	min: unknown,
	max: unknown,
	step: unknown,
	at: Fail.At
): Node
	local minValue = toFinite(min)
	if minValue == nil then
		return Fail.declaration("paramRange", at, `t.{kind} min`, "be a finite number", min)
	end

	local maxValue = toFinite(max)
	if maxValue == nil or maxValue <= minValue then
		return Fail.declaration("paramRange", at, `t.{kind} max`, "be a finite number above min", max)
	end

	local stepValue = toFinite(step)
	if stepValue == nil or stepValue <= 0 then
		return Fail.declaration("paramRange", at, `t.{kind} step`, "be a finite number above 0", step)
	end

	if stepValue == 1 and math.floor(minValue) == minValue then
		return Fail.declaration(
			"numberStepIsInt",
			at,
			`t.{kind} step`,
			"not be 1 with an integer min",
			step,
			"use t.int(min, max)"
		)
	end

	local steps = Quant.numberSteps(minValue, maxValue, stepValue)
	if steps == nil then
		return Fail.declaration(
			"numberStep",
			at,
			`t.{kind} step`,
			"divide max - min into a whole number of steps",
			step
		)
	end

	if steps > MAX_NUMBER_STEPS then
		return Fail.declaration("paramRange", at, `t.{kind} step`, "give at most 2^53 - 1 steps", step)
	end

	if kind == "vector3" then
		return { kind = "vector3", min = minValue, max = maxValue, step = stepValue, steps = steps }
	end

	return { kind = "number", min = minValue, max = maxValue, step = stepValue, steps = steps }
end


local function listEnumNode(items: { [unknown]: unknown }, at: Fail.At): Node
	local count = #items
	if count < 1 or count > MAX_COUNT then
		return Fail.declaration("enumItems", at, "t.enum items", "hold 1 to 65535 names", count)
	end

	local entryCount = 0
	for _ in items do
		entryCount += 1
	end

	if entryCount ~= count then
		return Fail.declaration("enumItems", at, "t.enum items", "be a list with no other keys", items)
	end

	local names = table.create(count) :: { string }
	local isSeen: { [string]: boolean } = {}
	for i = 1, count do
		local item = items[i]
		if typeof(item) ~= "string" or #item > MAX_COUNT then
			return Fail.declaration("enumItems", at, "t.enum items", "be strings of at most 65535 bytes", item)
		end

		if isSeen[item] then
			return Fail.declaration("duplicateName", at, "t.enum items", "be distinct", item)
		end

		isSeen[item] = true
		names[i] = item
	end

	return { kind = "enum", items = table.freeze(names) }
end


local function robloxEnumNode(enum: Enum): Node
	local byValue: { [number]: EnumItem } = {}
	for _, item in enum:GetEnumItems() do
		byValue[item.Value] = item
	end

	-- Roblox renders an enum as "Material" and Lune as "Enum.Material"; the hash needs one name.
	local name = string.gsub(tostring(enum), "^Enum%.", "")

	return { kind = "robloxEnum", name = name, byValue = table.freeze(byValue) }
end


local function customNode(spec: unknown, at: Fail.At): Node
	if not isRecord(spec) then
		return Fail.declaration("paramRange", at, "t.custom spec", "be a table", spec)
	end

	local options = spec :: { [unknown]: unknown }
	for key in options do
		if typeof(key) ~= "string" or not IS_CUSTOM_OPTION[key] then
			return Fail.declaration("unknownOption", at, "t.custom spec", `have only {CUSTOM_OPTIONS}`, key)
		end
	end

	if options.encode == nil or options.decode == nil then
		return Fail.declaration("missingOption", at, "t.custom spec", "have encode and decode")
	end

	if options.maxBits == nil and options.maxBytes == nil then
		return Fail.declaration("missingOption", at, "t.custom spec", "have maxBits or maxBytes")
	end

	if options.name == nil or options.version == nil then
		return Fail.declaration("missingOption", at, "t.custom spec", "have name and version")
	end

	local name = toName(options.name)
	if name == nil then
		return Fail.declaration(
			"nameLength",
			at,
			"t.custom name",
			"be a string of 1 to 65535 bytes",
			options.name
		)
	end

	local version = toFinite(options.version)
	if version == nil then
		return Fail.declaration("paramRange", at, "t.custom version", "be a finite number", options.version)
	end

	local maxBits = toInteger(options.maxBits or 0)
	if maxBits == nil or maxBits < 0 then
		return Fail.declaration("paramRange", at, "t.custom maxBits", "be a whole number", options.maxBits)
	end

	local maxBytes = toInteger(options.maxBytes or 0)
	if maxBytes == nil or maxBytes < 0 then
		return Fail.declaration("paramRange", at, "t.custom maxBytes", "be a whole number", options.maxBytes)
	end

	for _, key in { "luauType", "tsType" } do
		local text = options[key]
		if text ~= nil and typeof(text) ~= "string" then
			return Fail.declaration("paramRange", at, `t.custom {key}`, "be a string", text)
		end
	end

	return {
		kind = "custom",
		name = name,
		version = version,
		maxBits = maxBits,
		maxBytes = maxBytes,
		encode = toFunction(options.encode, at, "t.custom encode"),
		decode = toFunction(options.decode, at, "t.custom decode"),
	}
end


local function declarationOf(
	kind: "event" | "request" | "collection",
	options: unknown,
	at: Fail.At
): Declaration
	if not isRecord(options) then
		return Fail.declaration("paramRange", at, `Lync.{kind} options`, "be a table", options)
	end

	local frozenOptions = table.clone(options :: { [unknown]: unknown })
	table.freeze(frozenOptions)

	local declaration = {
		kind = kind,
		options = frozenOptions,
		line = at.line,
		source = at.source,
	}

	-- Frozen, a table's fields are read-only to the checker, which `Declaration` is not.
	return table.freeze(declaration) :: any
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Declares a collection (v5.md §3.4).

	@param  options the collection's options, checked by the planner
	@return the declaration
	@error  paramRange when `options` is not a table
]=]
function Dsl.collection(options: { [string]: any }): any
	return declarationOf("collection", options, atOf(debug.info(2, "sl")))
end


--[=[
	Declares an event (v5.md §3.4).

	@param  options the event's options, checked by the planner
	@return the declaration
	@error  paramRange when `options` is not a table
]=]
function Dsl.event(options: { [string]: any }): any
	return declarationOf("event", options, atOf(debug.info(2, "sl")))
end


--[=[
	Returns whether a value is a codec made by a constructor of `t`.

	@param  value any value
	@return true for a codec value; false for anything else, records included
]=]
function Dsl.isCodec(value: any): boolean
	return isCodec(value)
end


--[=[
	Declares a request (v5.md §3.4).

	@param  options the request's options, checked by the planner
	@return the declaration
	@error  paramRange when `options` is not a table
]=]
function Dsl.request(options: { [string]: any }): any
	return declarationOf("request", options, atOf(debug.info(2, "sl")))
end


--[=[
	Returns a copy of a codec marked as a `:newest()` collection field (v5-collections.md).

	@return the marked copy, at the original's line
]=]
function CodecMethods.newest(self: Codec): Codec
	local marked = {
		node = self.node,
		line = self.line,
		source = self.source,
		isNewest = true,
	}

	return table.freeze(setmetatable(marked, CODEC_METATABLE)) :: any
end


--[=[
	Declares an angle in radians, quantized to `step` (v5.md §3.3).

	@param  step the quantization step in radians, above 0
	@return the codec
	@error  paramRange when `step` is not a finite number above 0
]=]
function Codecs.angle(step: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	local stepValue = toFinite(step)
	if stepValue == nil or stepValue <= 0 then
		return Fail.declaration("paramRange", at, "t.angle step", "be a finite number above 0", step)
	end

	local steps = Quant.angleSteps(stepValue)
	if steps > MAX_ANGLE_STEPS then
		return Fail.declaration("paramRange", at, "t.angle step", "give at most 2^53 steps", step)
	end

	return codecOf({ kind = "angle", step = stepValue, steps = steps }, at)
end


--[=[
	Declares an array.

	@param  codec    the elements' codec or record
	@param  maxCount the most elements, 1 to 65,535
	@return the codec
	@error  notACodec or paramRange when an argument is not as described
]=]
function Codecs.array(codec: unknown, maxCount: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	local inner = toPart(codec, at, "t.array codec")
	local max = toCount(maxCount, at, "t.array maxCount")

	return codecOf({ kind = "array", inner = inner, max = max }, at)
end


--- Declares a boolean.
function Codecs.bool(): Codec
	return codecOf({ kind = "bool" }, atOf(debug.info(2, "sl")))
end


--[=[
	Declares a buffer.

	@param  maxBytes the most bytes, 1 to 65,535
	@return the codec
	@error  paramRange when `maxBytes` is out of range
]=]
function Codecs.buffer(maxBytes: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	local max = toCount(maxBytes, at, "t.buffer maxBytes")

	return codecOf({ kind = "buffer", max = max }, at)
end


--[=[
	Declares a CFrame as a position, then a rotation.

	@param  position a `t.vector3` or `t.vector3f32` codec
	@param  rotation a `t.rotation` codec
	@return the codec
	@error  notACodec or paramRange when an argument is not as described
]=]
function Codecs.cframe(position: unknown, rotation: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	local positionCodec = toCodec(position, at, "t.cframe position")
	local positionKind = positionCodec.node.kind
	if positionKind ~= "vector3" and positionKind ~= "vector3f32" then
		return Fail.declaration(
			"paramRange",
			at,
			"t.cframe position",
			"be a t.vector3 or t.vector3f32 codec",
			positionKind
		)
	end

	local rotationCodec = toCodec(rotation, at, "t.cframe rotation")
	local rotationKind = rotationCodec.node.kind
	if rotationKind ~= "rotation" then
		return Fail.declaration("paramRange", at, "t.cframe rotation", "be a t.rotation codec", rotationKind)
	end

	return codecOf({ kind = "cframe", position = positionCodec, rotation = rotationCodec }, at)
end


--- Declares a Color3 as three bytes.
function Codecs.color3(): Codec
	return codecOf({ kind = "color3" }, atOf(debug.info(2, "sl")))
end


--[=[
	Declares a codec that converts values to and from a base codec's (v5.md §8).

	@param  base   the codec or record the values travel as
	@param  decode turns a base value into the user's value
	@param  encode turns the user's value into a base value
	@return the codec
	@error  notACodec or paramRange when an argument is not as described
]=]
function Codecs.convert(base: unknown, decode: unknown, encode: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	local node: Node = {
		kind = "convert",
		base = toPart(base, at, "t.convert base"),
		decode = toFunction(decode, at, "t.convert decode"),
		encode = toFunction(encode, at, "t.convert encode"),
	}

	return codecOf(node, at)
end


--[=[
	Declares a codec of the user's own (v5.md §8).

	@param  spec `encode`, `decode`, `maxBits` or `maxBytes`, `name`, `version`, and optionally
	             `luauType` and `tsType`
	@return the codec
	@error  unknownOption, missingOption, nameLength or paramRange when `spec` is not as described
]=]
function Codecs.custom(spec: unknown): Codec
	local at = atOf(debug.info(2, "sl"))

	return codecOf(customNode(spec, at), at)
end


--[=[
	Declares a unit direction, octahedral (v5.md §3.3).

	@param  bits the bits per component, 8 to 16
	@return the codec
	@error  paramRange when `bits` is out of range
]=]
function Codecs.direction(bits: unknown): Codec
	local at = atOf(debug.info(2, "sl"))

	return codecOf({ kind = "direction", bits = toBits(bits, at, "t.direction bits", 8, 16) }, at)
end


--[=[
	Declares an enum of a list of names, or of a Roblox Enum.

	@param  items a list of 1 to 65,535 distinct names, or an Enum such as `Enum.Material`
	@return the codec
	@error  enumItems or duplicateName when `items` is not as described
]=]
function Codecs.enum(items: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	if typeof(items) == "Enum" then
		return codecOf(robloxEnumNode(items), at)
	end

	if not isRecord(items) then
		return Fail.declaration("enumItems", at, "t.enum items", "be a list of strings or an Enum", items)
	end

	return codecOf(listEnumNode(items :: { [unknown]: unknown }, at), at)
end


--- Declares a 32-bit float.
function Codecs.f32(): Codec
	return codecOf({ kind = "f32" }, atOf(debug.info(2, "sl")))
end


--- Declares a 64-bit float.
function Codecs.f64(): Codec
	return codecOf({ kind = "f64" }, atOf(debug.info(2, "sl")))
end


--[=[
	Declares an instance.

	@param  className the class every value must be (`IsA`), or nil for any instance
	@return the codec
	@error  paramRange when `className` is not nil or a non-empty string
]=]
function Codecs.instance(className: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	if className == nil then
		return codecOf({ kind = "instance", class = nil }, at)
	end

	local class = toName(className)
	if class == nil then
		return Fail.declaration(
			"paramRange",
			at,
			"t.instance className",
			"be nil or a string of 1 to 65535 bytes",
			className
		)
	end

	return codecOf({ kind = "instance", class = class }, at)
end


--[=[
	Declares an integer in [`min`, `max`], or with neither, any integer from -2^52 to 2^52 - 1.

	@param  min the least value, an integer from -2^52 to 2^52 - 1
	@param  max the greatest value, an integer from `min` to 2^52 - 1
	@return the codec
	@error  intBounds when the bounds are not as described
]=]
function Codecs.int(min: unknown, max: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	if min == nil and max == nil then
		return codecOf({ kind = "varint" }, at)
	end

	local minValue = toInteger(min)
	if minValue == nil or minValue < MIN_INT or minValue > MAX_INT then
		return Fail.declaration("intBounds", at, "t.int min", "be an integer from -2^52 to 2^52 - 1", min)
	end

	local maxValue = toInteger(max)
	if maxValue == nil or maxValue < minValue or maxValue > MAX_INT then
		return Fail.declaration("intBounds", at, "t.int max", "be an integer from min to 2^52 - 1", max)
	end

	return codecOf({ kind = "int", min = minValue, max = maxValue }, at)
end


--[=[
	Declares a map, sent with its keys in ascending order.

	@param  key      a `t.int`, list `t.enum` or `t.string` codec
	@param  value    the values' codec or record
	@param  maxCount the most pairs, 1 to 65,535
	@return the codec
	@error  mapKey, notACodec or paramRange when an argument is not as described
]=]
function Codecs.map(key: unknown, value: unknown, maxCount: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	if not isCodec(key) then
		return Fail.declaration("mapKey", at, "t.map key", "be a t.int, list t.enum or t.string codec", key)
	end

	local keyCodec = key :: Codec
	local keyKind = keyCodec.node.kind
	if not IS_MAP_KEY_KIND[keyKind] then
		return Fail.declaration(
			"mapKey",
			at,
			"t.map key",
			"be a t.int, list t.enum or t.string codec",
			keyKind
		)
	end

	local node: Node = {
		kind = "map",
		key = keyCodec,
		value = toPart(value, at, "t.map value"),
		max = toCount(maxCount, at, "t.map maxCount"),
	}

	return codecOf(node, at)
end


--[=[
	Declares a number in [`min`, `max`], quantized to `step` (v5.md §3.3).

	@param  min  the least value
	@param  max  the greatest value, above `min`
	@param  step the quantization step, dividing `max - min` into a whole number of steps
	@return the codec
	@error  numberStep, numberStepIsInt or paramRange when an argument is not as described
]=]
function Codecs.number(min: unknown, max: unknown, step: unknown): Codec
	local at = atOf(debug.info(2, "sl"))

	return codecOf(quantizedNode("number", min, max, step, at), at)
end


--[=[
	Declares a value that may be nil.

	@param  codec the present value's codec or record
	@return the codec
	@error  notACodec when `codec` is neither
]=]
function Codecs.optional(codec: unknown): Codec
	local at = atOf(debug.info(2, "sl"))

	return codecOf({ kind = "optional", inner = toPart(codec, at, "t.optional codec") }, at)
end


--[=[
	Declares a rotation, smallest-three (v5.md §3.3).

	@param  bits the bits per component, 7 to 15
	@return the codec
	@error  paramRange when `bits` is out of range
]=]
function Codecs.rotation(bits: unknown): Codec
	local at = atOf(debug.info(2, "sl"))

	return codecOf({ kind = "rotation", bits = toBits(bits, at, "t.rotation bits", 7, 15) }, at)
end


--[=[
	Declares a string.

	@param  maxBytes the most bytes, 1 to 65,535
	@return the codec
	@error  paramRange when `maxBytes` is out of range
]=]
function Codecs.string(maxBytes: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	local max = toCount(maxBytes, at, "t.string maxBytes")

	return codecOf({ kind = "string", max = max }, at)
end


--[=[
	Declares a union of records, discriminated on `kind` (v5.md §3.3).

	@param  variants 1 to 65,535 records by variant name; the planner checks the records
	@return the codec
	@error  paramRange or nameLength when `variants` is not as described
]=]
function Codecs.union(variants: unknown): Codec
	local at = atOf(debug.info(2, "sl"))
	if not isRecord(variants) then
		return Fail.declaration("paramRange", at, "t.union variants", "be a table of records", variants)
	end

	local variantByName = variants :: { [unknown]: unknown }
	local count = 0
	for name in variantByName do
		if toName(name) == nil then
			return Fail.declaration(
				"nameLength",
				at,
				"t.union variants",
				"be named by strings of 1 to 65535 bytes",
				name
			)
		end

		count += 1
	end

	if count < 1 or count > MAX_COUNT then
		return Fail.declaration("paramRange", at, "t.union variants", "number 1 to 65535", count)
	end

	local variantsCopy = table.clone(variantByName)
	table.freeze(variantsCopy)

	return codecOf({ kind = "union", variants = variantsCopy }, at)
end


--[=[
	Declares a Vector3 whose components are each `t.number(min, max, step)`.

	@param  min  the least component
	@param  max  the greatest component, above `min`
	@param  step the quantization step, dividing `max - min` into a whole number of steps
	@return the codec
	@error  numberStep, numberStepIsInt or paramRange when an argument is not as described
]=]
function Codecs.vector3(min: unknown, max: unknown, step: unknown): Codec
	local at = atOf(debug.info(2, "sl"))

	return codecOf(quantizedNode("vector3", min, max, step, at), at)
end


--- Declares a Vector3 of three 32-bit floats.
function Codecs.vector3f32(): Codec
	return codecOf({ kind = "vector3f32" }, atOf(debug.info(2, "sl")))
end


--- The `t` table: every codec constructor of v5.md §3.3.
Dsl.types = table.freeze(Codecs)

table.freeze(CodecMethods)


return table.freeze(Dsl)
