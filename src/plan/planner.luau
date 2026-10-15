--!strict

--[=[
	Planner

	Turns a schema's definitions into its IR: checks every option (v5.md §3.4), orders names
	(§3.1), checks `:newest()` (§3.3) and union variants, computes widths, the three id spaces
	(§4.6), worst-case message sizes against §4.9's caps, and the serialization and hash (§4.7).

	Errors are declaration errors, raised at the line the definition's or the codec's constructor
	recorded; a record has no line of its own and uses the nearest enclosing one. Subjects name
	the definition as `namespace.definition` and the place in it as a path such as `data.aim`:
	`.name` for a record field or union variant, `[]` for an array element or map value, `[key]`
	for a map key.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Dsl = require("./dsl")
local Fail = require("../diag/fail")
local Ints = require("../wire/ints")
local Ir = require("./ir")
local Serialize = require("./serialize")

-- Module ------------------------------------------------------------------------------------------

local Planner = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	Where a codec sits while it is planned.

	@field subject         the definition, as `namespace.definition`
	@field path            the place in the definition, such as `data.aim`
	@field at              the nearest recorded constructor line
	@field isNewestAllowed whether the codec is a collection's top-level data field
]=]
type Place = {
	subject: string,
	path: string,
	at: Fail.At,
	isNewestAllowed: boolean,
}

type Record = { [unknown]: unknown }

-- Constants ---------------------------------------------------------------------------------------

const MAX_NAMESPACE_BYTES = 64
const MAX_COUNT = 65_535
const MAX_RECORDS = 65_536

const MAX_MESSAGE_BYTES = 16_000
const MAX_UNRELIABLE_BYTES = 960

-- An EG-0 code of a zigzagged `t.int()` value is at most 2 × 53 + 1 bits (v5.md §4.10, G9).
const VARINT_BITS = 107
-- A frame counts its instances in a u16 (v5.md §4.5), so an index into a chunk's list of them
-- needs at most 16 bits.
const INSTANCE_INDEX_BITS = 16
-- An ask row starts `slot:u4 epoch:u1`, an answer row also `outcome:u2` (v5.md §5.2).
const ASK_PREFIX_BITS = 5
const ANSWER_PREFIX_BITS = 7
-- A `:newest()` row carries a 2-bit generation after its slot (v5-collections.md §3).
const GENERATION_BITS = 2

const DEFAULT_TIMEOUT = 10
const DEFAULT_MAX_RECORDS = 1024
const DEFAULT_PRIORITY = 1

const MIN_TIMEOUT = 0.1
const MAX_TIMEOUT = 300
const MIN_RELIABLE_RATE = 1
const MAX_RELIABLE_RATE = 60
const MAX_BURST = 1000

const MAX_BYTES_BY_CODE: { [string]: number } = {
	messageTooLarge = MAX_MESSAGE_BYTES,
	unreliableTooLarge = MAX_UNRELIABLE_BYTES,
}
table.freeze(MAX_BYTES_BY_CODE)

const OPTION_NAMES: { [string]: string } = {
	event = "from, data, lane and limit",
	request = "from, data, reply, timeout and limit",
	collection = "key, data, maxRecords, priority and reliableRate",
}
table.freeze(OPTION_NAMES)

-- `limit` throttles what clients send, so server-sent definitions do not take it.
const SERVER_OPTION_NAMES: { [string]: string } = {
	event = "from, data and lane",
	request = "from, data, reply and timeout",
}
table.freeze(SERVER_OPTION_NAMES)

const IS_OPTION_BY_KIND: { [string]: { [string]: boolean } } = {
	event = { from = true, data = true, lane = true, limit = true },
	request = { from = true, data = true, reply = true, timeout = true, limit = true },
	collection = {
		key = true,
		data = true,
		maxRecords = true,
		priority = true,
		reliableRate = true,
	},
}
table.freeze(IS_OPTION_BY_KIND)
for _, isOption in IS_OPTION_BY_KIND do
	table.freeze(isOption)
end

const IS_KEY_KIND: { [string]: boolean } = {
	int = true,
	varint = true,
	enum = true,
	string = true,
}
table.freeze(IS_KEY_KIND)

-- The kinds a `:newest()` field cannot hold: their rows have counts, lengths, Exp-Golomb codes,
-- instance indices or opaque custom encodings.
const IS_VARIABLE_WIDTH_KIND: { [string]: boolean } = {
	string = true,
	buffer = true,
	array = true,
	map = true,
	varint = true,
	robloxEnum = true,
	instance = true,
	custom = true,
}
table.freeze(IS_VARIABLE_WIDTH_KIND)

-- Private -----------------------------------------------------------------------------------------

-- The casts are for the old solver, whose `getmetatable` and `table.isfrozen` take no `unknown`.
local function isRecord(value: unknown): boolean
	return typeof(value) == "table" and getmetatable(value :: any) == nil
end

local function toName(value: unknown, maxBytes: number): string?
	if typeof(value) ~= "string" or #value < 1 or #value > maxBytes then
		return nil
	end

	return value
end

local function toFinite(value: unknown): number?
	-- selene's standard library predates math.isfinite.
	-- selene: allow(incorrect_standard_library_use)
	if typeof(value) ~= "number" or not math.isfinite(value) then
		return nil
	end

	return value
end

local function toDeclaration(value: unknown): Dsl.Declaration?
	if typeof(value) ~= "table" or not table.isfrozen(value :: any) then
		return nil
	end

	local declaration = value :: Record
	local kind = declaration.kind
	if kind ~= "event" and kind ~= "request" and kind ~= "collection" then
		return nil
	end

	if
		not isRecord(declaration.options)
		or typeof(declaration.line) ~= "number"
		or typeof(declaration.source) ~= "string"
	then
		return nil
	end

	return value :: any
end

-- Freezes the IR once it is complete. Tables from the DSL are frozen already, and user
-- functions and Roblox values are left alone.
local function freezeDeeply(value: unknown)
	if typeof(value) ~= "table" or table.isfrozen(value :: any) then
		return
	end

	local tableValue = value :: Record
	table.freeze(tableValue)
	for _, child in tableValue do
		freezeDeeply(child)
	end
end

-- `Ints.width` needs at least one value; an empty id space has no ids to write.
local function widthOf(count: number): number
	if count == 0 then
		return 0
	end

	return Ints.width(count)
end

-- Returns the names of a record or definitions table in bytewise order.
local function sortedNamesOf(
	record: Record,
	maxBytes: number,
	at: Fail.At,
	subject: string,
	requirement: string
): { string }
	local names: { string } = {}
	for key in record do
		local name = toName(key, maxBytes)
		if name == nil then
			return Fail.declaration("nameLength", at, subject, requirement, key)
		end

		table.insert(names, name)
	end

	if #names > MAX_COUNT then
		return Fail.declaration("paramRange", at, subject, "have at most 65535 entries", #names)
	end

	table.sort(names)

	return names
end

local function placeAt(place: Place, path: string, at: Fail.At, isNewestAllowed: boolean): Place
	return { subject = place.subject, path = path, at = at, isNewestAllowed = isNewestAllowed }
end

local function subjectOf(place: Place): string
	return `{place.subject} {place.path}`
end

local function numberCodecOf(min: number, max: number, step: number, steps: number): Ir.NumberCodec
	local codec: Ir.NumberCodec = {
		kind = "number",
		min = min,
		max = max,
		step = step,
		steps = steps,
		width = Ints.width(steps + 1),
	}

	return codec
end

-- Returns the worst-case bits and tail bytes of a codec's single-row encoding (v5.md §3.3).
local function sizeOf(codec: Ir.Codec): (number, number)
	if codec.kind == "bool" then
		return 1, 0
	elseif codec.kind == "varint" then
		return VARINT_BITS, 0
	elseif codec.kind == "f32" then
		return 32, 0
	elseif codec.kind == "f64" then
		return 64, 0
	elseif codec.kind == "vector3f32" then
		return 96, 0
	elseif codec.kind == "color3" then
		return 24, 0
	elseif codec.kind == "instance" then
		return INSTANCE_INDEX_BITS, 0
	elseif
		codec.kind == "int"
		or codec.kind == "number"
		or codec.kind == "angle"
		or codec.kind == "enum"
	then
		return codec.width, 0
	elseif codec.kind == "string" or codec.kind == "buffer" then
		return codec.width, codec.max
	elseif codec.kind == "vector3" then
		return 3 * codec.axis.width, 0
	elseif codec.kind == "direction" then
		return 2 * codec.bits, 0
	elseif codec.kind == "rotation" then
		-- Flag 1 writes a u5 axis index; flag 0 a u2 dropped index and three components.
		return 1 + math.max(5, 2 + 3 * codec.bits), 0
	elseif codec.kind == "cframe" then
		local positionBits, positionTail = sizeOf(codec.position)
		local rotationBits, rotationTail = sizeOf(codec.rotation)
		return positionBits + rotationBits, positionTail + rotationTail
	elseif codec.kind == "robloxEnum" then
		local maxBits = 0
		for value in codec.byValue do
			maxBits = math.max(maxBits, Ints.egBits(Ints.zigzag(value), 0))
		end
		return maxBits, 0
	elseif codec.kind == "optional" then
		local innerBits, innerTail = sizeOf(codec.inner)
		return 1 + innerBits, innerTail
	elseif codec.kind == "array" then
		local innerBits, innerTail = sizeOf(codec.inner)
		return codec.width + codec.max * innerBits, codec.max * innerTail
	elseif codec.kind == "map" then
		local keyBits, keyTail = sizeOf(codec.key)
		local valueBits, valueTail = sizeOf(codec.value)
		return codec.width + codec.max * (keyBits + valueBits), codec.max * (keyTail + valueTail)
	elseif codec.kind == "union" then
		local maxBits = 0
		local maxTail = 0
		for _, variant in codec.variants do
			local variantBits, variantTail = sizeOf(variant.record)
			maxBits = math.max(maxBits, variantBits)
			maxTail = math.max(maxTail, variantTail)
		end
		return codec.width + maxBits, maxTail
	elseif codec.kind == "record" then
		local totalBits = 0
		local totalTail = 0
		for _, field in codec.fields do
			local fieldBits, fieldTail = sizeOf(field.codec)
			totalBits += fieldBits
			totalTail += fieldTail
		end
		return totalBits, totalTail
	elseif codec.kind == "custom" then
		return codec.maxBits, codec.maxBytes
	elseif codec.kind == "convert" then
		return sizeOf(codec.base)
	end

	error(`a codec must have a known kind, got {codec.kind}`)
end

local function hasInstance(codec: Ir.Codec): boolean
	if codec.kind == "instance" then
		return true
	elseif codec.kind == "cframe" then
		return hasInstance(codec.position) or hasInstance(codec.rotation)
	elseif codec.kind == "optional" or codec.kind == "array" then
		return hasInstance(codec.inner)
	elseif codec.kind == "map" then
		return hasInstance(codec.key) or hasInstance(codec.value)
	elseif codec.kind == "convert" then
		return hasInstance(codec.base)
	elseif codec.kind == "union" then
		for _, variant in codec.variants do
			if hasInstance(variant.record) then
				return true
			end
		end
	elseif codec.kind == "record" then
		for _, field in codec.fields do
			if hasInstance(field.codec) then
				return true
			end
		end
	end

	return false
end

local function hasAnyInstance(data: Ir.Codec?, reply: Ir.Codec?): boolean
	if data ~= nil and hasInstance(data) then
		return true
	end

	return reply ~= nil and hasInstance(reply)
end

local function isFixedWidth(codec: Ir.Codec): boolean
	if IS_VARIABLE_WIDTH_KIND[codec.kind] then
		return false
	elseif codec.kind == "cframe" then
		return isFixedWidth(codec.position) and isFixedWidth(codec.rotation)
	elseif codec.kind == "optional" then
		return isFixedWidth(codec.inner)
	elseif codec.kind == "convert" then
		return isFixedWidth(codec.base)
	elseif codec.kind == "union" then
		for _, variant in codec.variants do
			if not isFixedWidth(variant.record) then
				return false
			end
		end
	elseif codec.kind == "record" then
		for _, field in codec.fields do
			if not isFixedWidth(field.codec) then
				return false
			end
		end
	end

	return true
end

local planCodec: (value: unknown, place: Place) -> Ir.Codec

local function planRecord(record: Record, place: Place, areFieldsNewestAllowed: boolean): Ir.Codec
	local names = sortedNamesOf(
		record,
		MAX_COUNT,
		place.at,
		subjectOf(place),
		"name its fields with strings of 1 to 65535 bytes"
	)

	local fields = table.create(#names) :: { Ir.Field }
	for i, name in names do
		local value = record[name]
		local fieldPlace = placeAt(place, `{place.path}.{name}`, place.at, areFieldsNewestAllowed)
		fields[i] = {
			name = name,
			codec = planCodec(value, fieldPlace),
			newest = Dsl.isCodec(value) and (value :: Dsl.Codec).isNewest,
		}
	end

	return { kind = "record", fields = fields }
end

local function planUnion(variants: Record, place: Place): Ir.Codec
	local names = sortedNamesOf(
		variants,
		MAX_COUNT,
		place.at,
		subjectOf(place),
		"name its variants with strings of 1 to 65535 bytes"
	)

	local planned = table.create(#names) :: { Ir.Variant }
	local byName: { [string]: number } = {}
	for i, name in names do
		local variantPlace = placeAt(place, `{place.path}.{name}`, place.at, false)
		local record = variants[name]
		if not isRecord(record) then
			return Fail.declaration(
				"notACodec",
				place.at,
				subjectOf(variantPlace),
				"be a record of codecs",
				record
			)
		end

		local fields = record :: Record
		if fields.kind ~= nil then
			return Fail.declaration(
				"unionKindField",
				place.at,
				subjectOf(variantPlace),
				"not have a field named kind, the union's discriminant",
				nil,
				"rename the field"
			)
		end

		planned[i] = { name = name, record = planRecord(fields, variantPlace, false) }
		byName[name] = i - 1
	end

	return { kind = "union", variants = planned, byName = byName, width = Ints.width(#names) }
end

local function planNode(node: Dsl.Node, place: Place): Ir.Codec
	if node.kind == "int" then
		return {
			kind = "int",
			min = node.min,
			max = node.max,
			width = Ints.width(node.max - node.min + 1),
		}
	elseif node.kind == "number" then
		return numberCodecOf(node.min, node.max, node.step, node.steps)
	elseif node.kind == "angle" then
		return {
			kind = "angle",
			step = node.step,
			steps = node.steps,
			width = Ints.width(node.steps),
		}
	elseif node.kind == "string" then
		return { kind = "string", max = node.max, width = Ints.width(node.max + 1) }
	elseif node.kind == "buffer" then
		return { kind = "buffer", max = node.max, width = Ints.width(node.max + 1) }
	elseif node.kind == "vector3" then
		local axis = numberCodecOf(node.min, node.max, node.step, node.steps)
		return { kind = "vector3", axis = axis }
	elseif node.kind == "direction" then
		return { kind = "direction", bits = node.bits }
	elseif node.kind == "rotation" then
		return { kind = "rotation", bits = node.bits }
	elseif node.kind == "cframe" then
		return {
			kind = "cframe",
			position = planCodec(
				node.position,
				placeAt(place, `{place.path}.position`, place.at, false)
			),
			rotation = planCodec(
				node.rotation,
				placeAt(place, `{place.path}.rotation`, place.at, false)
			),
		}
	elseif node.kind == "enum" then
		local index: { [string]: number } = {}
		for i, item in node.items do
			index[item] = i - 1
		end
		return {
			kind = "enum",
			items = node.items,
			index = index,
			width = Ints.width(#node.items),
		}
	elseif node.kind == "robloxEnum" then
		return { kind = "robloxEnum", name = node.name, byValue = node.byValue }
	elseif node.kind == "instance" then
		return { kind = "instance", class = node.class }
	elseif node.kind == "optional" then
		return { kind = "optional", inner = planCodec(node.inner, place) }
	elseif node.kind == "array" then
		local elementPlace = placeAt(place, `{place.path}[]`, place.at, false)
		return {
			kind = "array",
			inner = planCodec(node.inner, elementPlace),
			max = node.max,
			width = Ints.width(node.max + 1),
		}
	elseif node.kind == "map" then
		local keyPlace = placeAt(place, `{place.path}[key]`, place.at, false)
		local valuePlace = placeAt(place, `{place.path}[]`, place.at, false)
		return {
			kind = "map",
			key = planCodec(node.key, keyPlace),
			value = planCodec(node.value, valuePlace),
			max = node.max,
			width = Ints.width(node.max + 1),
		}
	elseif node.kind == "union" then
		return planUnion(node.variants, place)
	elseif node.kind == "custom" then
		return {
			kind = "custom",
			name = node.name,
			version = node.version,
			maxBits = node.maxBits,
			maxBytes = node.maxBytes,
			encode = node.encode,
			decode = node.decode,
		}
	elseif node.kind == "convert" then
		return {
			kind = "convert",
			base = planCodec(node.base, place),
			decode = node.decode,
			encode = node.encode,
		}
	end

	-- The rest have no parameters, so the IR codec is the node.
	return node :: any
end

function planCodec(value: unknown, place: Place): Ir.Codec
	if isRecord(value) then
		return planRecord(value :: Record, placeAt(place, place.path, place.at, false), false)
	end

	if not Dsl.isCodec(value) then
		return Fail.declaration(
			"notACodec",
			place.at,
			subjectOf(place),
			"be a codec or a record of codecs",
			value
		)
	end

	local codec = value :: Dsl.Codec
	local at: Fail.At = { line = codec.line, source = codec.source }
	if codec.isNewest and not place.isNewestAllowed then
		return Fail.declaration(
			"newestPlacement",
			at,
			subjectOf(place),
			"be a top-level data field of a collection to use :newest()"
		)
	end

	local planned = planNode(codec.node, placeAt(place, place.path, at, false))
	if codec.isNewest and not isFixedWidth(planned) then
		return Fail.declaration(
			"newestWidth",
			at,
			subjectOf(place),
			"have a fixed-width codec to use :newest()",
			planned.kind
		)
	end

	return planned
end

local function checkSize(
	code: "messageTooLarge" | "unreliableTooLarge",
	bits: number,
	tail: number,
	at: Fail.At,
	subject: string
)
	local maxBytes = MAX_BYTES_BY_CODE[code]
	local bytes = math.ceil(bits / 8) + tail
	if bytes > maxBytes then
		Fail.declaration(code, at, subject, `encode in at most {maxBytes} bytes`, bytes)
	end
end

local function fromOf(
	declaration: Dsl.Declaration,
	at: Fail.At,
	subject: string
): "client" | "server"
	if declaration.kind == "collection" then
		return "server"
	end

	local from = declaration.options.from
	if from == nil then
		return Fail.declaration(
			"missingOption",
			at,
			subject,
			`have the option from, "client" or "server"`
		)
	end

	if from == "client" then
		return "client"
	end

	if from == "server" then
		return "server"
	end

	return Fail.declaration("paramRange", at, `{subject} from`, `be "client" or "server"`, from)
end

local function checkOptionNames(declaration: Dsl.Declaration, at: Fail.At, subject: string)
	local kind = declaration.kind
	local isOption: { [string]: boolean } = IS_OPTION_BY_KIND[kind]
	local optionNames = OPTION_NAMES[kind]
	for key in declaration.options do
		if typeof(key) ~= "string" or not isOption[key] then
			Fail.declaration(
				"unknownOption",
				at,
				subject,
				`have only the options {optionNames}`,
				key
			)
		end
	end
end

local function checkLimitSide(
	declaration: Dsl.Declaration,
	from: "client" | "server",
	at: Fail.At,
	subject: string
)
	if from == "client" or declaration.options.limit == nil then
		return
	end

	local optionNames = SERVER_OPTION_NAMES[declaration.kind]
	Fail.declaration("unknownOption", at, subject, `have only the options {optionNames}`, "limit")
end

local function laneOf(
	declaration: Dsl.Declaration,
	at: Fail.At,
	subject: string
): "reliable" | "unreliable"
	local lane = declaration.options.lane
	if lane == nil or lane == "reliable" then
		return "reliable"
	end

	if lane == "unreliable" then
		return "unreliable"
	end

	return Fail.declaration(
		"paramRange",
		at,
		`{subject} lane`,
		`be "reliable" or "unreliable"`,
		lane
	)
end

local function planKey(value: unknown, at: Fail.At, subject: string): Ir.Codec
	if not Dsl.isCodec(value) then
		return Fail.declaration(
			"mapKey",
			at,
			`{subject} key`,
			"be a t.int, list t.enum or t.string codec",
			value
		)
	end

	local keyKind = (value :: Dsl.Codec).node.kind
	if not IS_KEY_KIND[keyKind] then
		return Fail.declaration(
			"mapKey",
			at,
			`{subject} key`,
			"be a t.int, list t.enum or t.string codec",
			keyKind
		)
	end

	return planCodec(value, { subject = subject, path = "key", at = at, isNewestAllowed = false })
end

local function planLimit(
	value: unknown,
	at: Fail.At,
	subject: string
): { perSecond: number, burst: number }
	if not isRecord(value) then
		return Fail.declaration(
			"paramRange",
			at,
			`{subject} limit`,
			"be a table with perSecond and burst",
			value
		)
	end

	local limit = value :: Record
	for key in limit do
		if key ~= "perSecond" and key ~= "burst" then
			return Fail.declaration(
				"unknownOption",
				at,
				`{subject} limit`,
				"have only perSecond and burst",
				key
			)
		end
	end

	if limit.perSecond == nil then
		return Fail.declaration("missingOption", at, `{subject} limit`, "have perSecond")
	end

	local perSecond = toFinite(limit.perSecond)
	if perSecond == nil or perSecond <= 0 then
		return Fail.declaration(
			"paramRange",
			at,
			`{subject} limit.perSecond`,
			"be a finite number above 0",
			limit.perSecond
		)
	end

	local burst = limit.burst
	if burst == nil then
		return { perSecond = perSecond, burst = math.max(1, math.ceil(perSecond)) }
	end

	local burstCount = toFinite(burst)
	if
		burstCount == nil
		or burstCount < 1
		or burstCount > MAX_BURST
		or math.floor(burstCount) ~= burstCount
	then
		return Fail.declaration(
			"paramRange",
			at,
			`{subject} limit.burst`,
			"be an integer from 1 to 1000",
			burst
		)
	end

	return { perSecond = perSecond, burst = burstCount }
end

local function timeoutOf(value: unknown, at: Fail.At, subject: string): number
	if value == nil then
		return DEFAULT_TIMEOUT
	end

	local timeout = toFinite(value)
	if timeout == nil or timeout < MIN_TIMEOUT or timeout > MAX_TIMEOUT then
		return Fail.declaration(
			"paramRange",
			at,
			`{subject} timeout`,
			"be from 0.1 to 300 seconds",
			value
		)
	end

	return timeout
end

local function maxRecordsOf(value: unknown, at: Fail.At, subject: string): number
	if value == nil then
		return DEFAULT_MAX_RECORDS
	end

	local maxRecords = toFinite(value)
	if
		maxRecords == nil
		or maxRecords < 1
		or maxRecords > MAX_RECORDS
		or math.floor(maxRecords) ~= maxRecords
	then
		return Fail.declaration(
			"paramRange",
			at,
			`{subject} maxRecords`,
			"be an integer from 1 to 65536",
			value
		)
	end

	return maxRecords
end

local function priorityOf(value: unknown, at: Fail.At, subject: string): number
	if value == nil then
		return DEFAULT_PRIORITY
	end

	local priority = toFinite(value)
	if priority == nil or priority <= 0 then
		return Fail.declaration(
			"paramRange",
			at,
			`{subject} priority`,
			"be a finite number above 0",
			value
		)
	end

	return priority
end

local function reliableRateOf(value: unknown, at: Fail.At, subject: string): number?
	if value == nil then
		return nil
	end

	local rate = toFinite(value)
	if rate == nil or rate < MIN_RELIABLE_RATE or rate > MAX_RELIABLE_RATE then
		return Fail.declaration(
			"paramRange",
			at,
			`{subject} reliableRate`,
			"be nil or from 1 to 60 Hz",
			value
		)
	end

	return rate
end

local function planData(declaration: Dsl.Declaration, at: Fail.At, subject: string): Ir.Codec?
	local value = declaration.options.data
	if value == nil then
		return nil
	end

	local place: Place = { subject = subject, path = "data", at = at, isNewestAllowed = false }
	if declaration.kind ~= "collection" then
		return planCodec(value, place)
	end

	if not isRecord(value) then
		return Fail.declaration("notACodec", at, `{subject} data`, "be a record of codecs", value)
	end

	return planRecord(value :: Record, place, true)
end

local function planReply(value: unknown, at: Fail.At, subject: string): Ir.Codec?
	if value == nil then
		return nil
	end

	return planCodec(value, { subject = subject, path = "reply", at = at, isNewestAllowed = false })
end

local function sizeOrZeroOf(codec: Ir.Codec?): (number, number)
	if codec == nil then
		return 0, 0
	end

	return sizeOf(codec)
end

local function newestBitsOf(data: Ir.Codec?): number
	if data == nil or data.kind ~= "record" then
		return 0
	end

	local bits = 0
	for _, field in data.fields do
		if field.newest then
			bits += sizeOf(field.codec)
		end
	end

	return bits
end

-- Checks a definition's worst-case messages against v5.md §4.9's caps.
local function checkSizes(definition: Ir.Definition, at: Fail.At, subject: string)
	local dataSubject = `{subject} data`
	if definition.kind == "event" and definition.lane == "unreliable" then
		checkSize(
			"unreliableTooLarge",
			definition.dataMaxBits,
			definition.dataMaxTail,
			at,
			dataSubject
		)
	elseif definition.kind == "event" then
		checkSize(
			"messageTooLarge",
			definition.dataMaxBits,
			definition.dataMaxTail,
			at,
			dataSubject
		)
	elseif definition.kind == "request" then
		local askBits = ASK_PREFIX_BITS + definition.dataMaxBits
		local answerBits = ANSWER_PREFIX_BITS + definition.replyMaxBits
		checkSize("messageTooLarge", askBits, definition.dataMaxTail, at, dataSubject)
		checkSize("messageTooLarge", answerBits, definition.replyMaxTail, at, `{subject} reply`)
	else
		-- An add row carries the slot, the key and every field; a `:newest()` row the slot, the
		-- generation and the newest fields (v5-collections.md §3).
		local slotBits = widthOf(definition.maxRecords)
		local keyBits, keyTail = sizeOrZeroOf(definition.key)
		local addBits = slotBits + keyBits + definition.dataMaxBits
		local addTail = keyTail + definition.dataMaxTail
		local rowBits = slotBits + GENERATION_BITS + newestBitsOf(definition.data)
		checkSize("messageTooLarge", addBits, addTail, at, dataSubject)
		checkSize("unreliableTooLarge", rowBits, 0, at, dataSubject)
	end
end

local function planDefinition(
	namespaceName: string,
	name: string,
	declaration: Dsl.Declaration
): Ir.Definition
	local subject = `{namespaceName}.{name}`
	local at: Fail.At = { line = declaration.line, source = declaration.source }
	local options = declaration.options
	-- Annotated for the old solver, which widens a singleton in a local.
	local kind: "event" | "request" | "collection" = declaration.kind

	checkOptionNames(declaration, at, subject)
	local from: "client" | "server" = fromOf(declaration, at, subject)
	checkLimitSide(declaration, from, at, subject)

	local data = planData(declaration, at, subject)
	local reply = planReply(options.reply, at, subject)
	local dataBits, dataTail = sizeOrZeroOf(data)
	local replyBits, replyTail = sizeOrZeroOf(reply)

	local definition: Ir.Definition = {
		name = name,
		kind = kind,
		from = from,
		lane = if kind == "event" then laneOf(declaration, at, subject) else "reliable",
		data = data,
		reply = reply,
		key = if options.key == nil then nil else planKey(options.key, at, subject),
		limit = if options.limit == nil then nil else planLimit(options.limit, at, subject),
		timeout = if kind == "request" then timeoutOf(options.timeout, at, subject) else 0,
		maxRecords = if kind == "collection"
			then maxRecordsOf(options.maxRecords, at, subject)
			else 0,
		priority = if kind == "collection" then priorityOf(options.priority, at, subject) else 0,
		reliableRate = reliableRateOf(options.reliableRate, at, subject),
		dataMaxBits = dataBits,
		dataMaxTail = dataTail,
		replyMaxBits = replyBits,
		replyMaxTail = replyTail,
		hasInstances = hasAnyInstance(data, reply),
		line = declaration.line,
		source = declaration.source,
	}
	checkSizes(definition, at, subject)

	return definition
end

local function entryOf(
	definition: Ir.Definition,
	role: "event" | "ask" | "answer",
	space: { Ir.Entry }
)
	local entry: Ir.Entry = { definition = definition, role = role, id = #space }
	table.insert(space, entry)
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Plans a schema.

	@param  name        the namespace's name, 1 to 64 bytes
	@param  definitions the definitions by name, each made by `Lync.event`, `Lync.request` or
	                    `Lync.collection`
	@param  at          where `Lync.schema` was called
	@return the frozen IR
	@error  a declaration error, at the line of the constructor that declared the mistake
]=]
function Planner.plan(name: string, definitions: { [string]: any }, at: Fail.At): Ir.Namespace
	local namespaceName = toName(name, MAX_NAMESPACE_BYTES)
	if namespaceName == nil then
		return Fail.declaration(
			"nameLength",
			at,
			"Lync.schema name",
			"be a string of 1 to 64 bytes",
			name
		)
	end

	if not isRecord(definitions) then
		return Fail.declaration(
			"paramRange",
			at,
			namespaceName,
			"be given a table of definitions",
			definitions
		)
	end

	local names = sortedNamesOf(
		definitions :: any,
		MAX_COUNT,
		at,
		namespaceName,
		"name its definitions with strings of 1 to 65535 bytes"
	)

	local planned = table.create(#names) :: { Ir.Definition }
	local byName: { [string]: Ir.Definition } = {}
	local up: { Ir.Entry } = {}
	local down: { Ir.Entry } = {}
	local collections: { Ir.Definition } = {}
	for i, definitionName in names do
		local value = definitions[definitionName]
		local declaration = toDeclaration(value)
		if declaration == nil then
			return Fail.declaration(
				"paramRange",
				at,
				`{namespaceName}.{definitionName}`,
				"be made by Lync.event, Lync.request or Lync.collection",
				value
			)
		end

		local definition = planDefinition(namespaceName, definitionName, declaration)
		planned[i] = definition
		byName[definitionName] = definition

		local isFromClient = definition.from == "client"
		if definition.kind == "event" then
			entryOf(definition, "event", if isFromClient then up else down)
		elseif definition.kind == "request" then
			entryOf(definition, "ask", if isFromClient then up else down)
			entryOf(definition, "answer", if isFromClient then down else up)
		else
			table.insert(collections, definition)
		end
	end

	local namespace: Ir.Namespace = {
		name = namespaceName,
		definitions = planned,
		byName = byName,
		up = up,
		down = down,
		collections = collections,
		upWidth = widthOf(#up),
		downWidth = widthOf(#down),
		collectionWidth = widthOf(#collections),
		serialization = buffer.create(0),
		hashLow = 0,
		hashHigh = 0,
		line = at.line,
		source = at.source,
	}
	namespace.serialization = Serialize.bytes(namespace)
	namespace.hashLow, namespace.hashHigh = Serialize.hash(namespace.serialization)
	freezeDeeply(namespace)

	return namespace
end

return table.freeze(Planner)
