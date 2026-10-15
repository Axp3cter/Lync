--!strict

--[=[
	Leaves

	What single rows and column blocks share (v5.md §3.3, §4.2): checking a leaf value and
	turning it into its codes, turning codes back into a value, the refusals encoders return, a
	chunk's instances on both ends, and the public encoders' rollback.

	A `...Code` function returns nil when the codec refuses the value, and the encoder then builds
	the refusal with `Leaves.refusal`, so no message is formatted on the success path.

	Encoding is read-only on a chunk's instance list: `Rows.collect` and `Run.collect` list the
	instances, and an instance not listed is a Lync bug (`internal`). Decoding reads a chunk's
	entries by its offset and count, never `#list`, and records a value it can't resolve (an
	unknown Roblox enum value, a nil instance, an instance of the wrong class) as a miss of its row
	instead of refusing the frame.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Fail = require("../diag/fail")
local Ints = require("../wire/ints")
local Ir = require("../plan/ir")
local Limits = require("../wire/limits")
local Quant = require("../wire/quant")

-- Module ------------------------------------------------------------------------------------------

local Leaves = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	The instances an encoded chunk references, each listed once in order of first reference
	(v5.md §4.2).

	@field list  the instances, in order of first reference; collecting extends it
	@field index each listed instance's index in `list`, from 0
	@field count how many entries encodes have committed; an encode fixes it at `#list` on entry
	             and a failed encode truncates the list back to it
]=]
export type Instances = { list: { Instance }, index: { [Instance]: number }, count: number }

--[=[
	Why an encoder refused a value.

	@field requirement what the value must be, completing "<subject> must"
	@field got         the refused value
	@field path        the place of the value, one segment per level, innermost first
]=]
export type Refusal = { requirement: string, got: any, path: { string } }

--- The value a refusal's path starts from (v5.md §7.1).
export type Root = "data" | "reply" | "record" | "patch"

--[=[
	A decoded chunk's instances: `count` entries of the frame's instance array from `offset`
	(m1-plan.md §6.2).

	@field list      the frame's instance array; an unreplicated instance is nil
	@field offset    how many entries of `list` come before the chunk's
	@field count     the chunk's instance count, from its header
	@field firstSeen how many of the chunk's entries indices have referenced so far
]=]
export type Chunk = { list: { Instance? }, offset: number, count: number, firstSeen: number }

--[=[
	A decoded value the receiver can't resolve (v5.md §7.3 `unresolved`); its row's value is
	undefined.

	@field row   the row of the chunk it is in
	@field what  1 an unknown Roblox enum value, 2 a nil instance, 3 an instance of the wrong class
	@field value the enum value, or the instance's index in its chunk
]=]
export type Miss = { row: number, what: number, value: number }

-- Constants ---------------------------------------------------------------------------------------

--- The longest list of names a requirement spells out; messages are cut at 200 bytes anyway.
const MAX_NAMES_BYTES = 200

const MAX_F32 = 3.4028234663852886e38

--- How many re-encodings the rotation encoder takes to reach a canonical code (v5.md §3.3).
const MAX_ROTATION_STEPS = 4

--- Rotation codes packed into one integer whose order is that of (flag, index, a, b, c).
const FLAG_SCALE = 2 ^ 50
const INDEX_SCALE = 2 ^ 45
const A_SCALE = 2 ^ 30
const B_SCALE = 2 ^ 15

const MISS_ENUM = 1
const MISS_NIL = 2
const MISS_CLASS = 3

const FLOAT_SCRATCH = buffer.create(8)

-- State -------------------------------------------------------------------------------------------

--- The decoded record shape of each record codec's fields, or union variant, cloned per value.
local templateByShape: { [any]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any

--- Whether each codec can hold an instance, filled as codecs are asked about.
local hasInstanceByCodec: { [Ir.Codec]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Whether each codec can hold a value the receiver can't resolve.
local canMissByCodec: { [Ir.Codec]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Private -----------------------------------------------------------------------------------------

local function namesOf(names: { string }): string
	local shown = {}
	local shownBytes = 0
	for _, name in names do
		local text = Fail.show(name)
		table.insert(shown, text)
		shownBytes += #text + 2
		if shownBytes > MAX_NAMES_BYTES then
			break
		end
	end

	return table.concat(shown, ", ")
end

local function variantNamesOf(variants: { Ir.Variant }): { string }
	local names = table.create(#variants, "")
	for i, variant in variants do
		names[i] = variant.name
	end

	return names
end

local function requirementOf(codec: Ir.Codec): string
	if codec.kind == "bool" then
		return "be a boolean"
	elseif codec.kind == "int" then
		return `be an integer from {Fail.show(codec.min)} to {Fail.show(codec.max)}`
	elseif codec.kind == "varint" then
		return "be an integer from -2^52 to 2^52 - 1"
	elseif codec.kind == "number" then
		return `be a number from {Fail.show(codec.min)} to {Fail.show(codec.max)}`
	elseif codec.kind == "f32" then
		return "be a finite number within the f32 range"
	elseif codec.kind == "f64" or codec.kind == "angle" then
		return "be a finite number"
	elseif codec.kind == "string" then
		return `be a string of at most {codec.max} bytes`
	elseif codec.kind == "buffer" then
		return `be a buffer of at most {codec.max} bytes`
	elseif codec.kind == "vector3" then
		local axis = codec.axis
		return `be a Vector3 with components from {Fail.show(axis.min)} to {Fail.show(axis.max)}`
	elseif codec.kind == "vector3f32" then
		return "be a Vector3 with components within the f32 range"
	elseif codec.kind == "direction" then
		return "be a finite non-zero Vector3"
	elseif codec.kind == "rotation" then
		return "be a finite CFrame with no position (pass cf.Rotation)"
	elseif codec.kind == "cframe" then
		return "be a CFrame"
	elseif codec.kind == "color3" then
		return "be a Color3 with channels from 0 to 1"
	elseif codec.kind == "enum" then
		return `be one of {namesOf(codec.items)}`
	elseif codec.kind == "robloxEnum" then
		return `be an item of Enum.{codec.name}`
	elseif codec.kind == "instance" then
		if codec.class == nil then
			return "be an Instance"
		end
		return `be an Instance of class {codec.class}`
	elseif codec.kind == "array" then
		return `be an array of at most {codec.max} elements`
	elseif codec.kind == "map" then
		return `be a table of at most {codec.max} pairs`
	elseif codec.kind == "union" then
		return "be a table with a kind"
	elseif codec.kind == "custom" then
		return `encode in at most {codec.maxBits} bits and {codec.maxBytes} tail bytes`
	end

	return "be a table"
end

local function packedRotation(flag: number, index: number, a: number, b: number, c: number): number
	return flag * FLAG_SCALE + index * INDEX_SCALE + a * A_SCALE + b * B_SCALE + c
end

local function unpackedRotation(key: number): (number, number, number, number, number)
	return key // FLAG_SCALE,
		key // INDEX_SCALE % 32,
		key // A_SCALE % B_SCALE,
		key // B_SCALE % B_SCALE,
		key % B_SCALE
end

local function quantizedRotation(rotation: CFrame, bits: number): number
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rotation:GetComponents()

	return packedRotation(Quant.rotation(r00, r01, r02, r10, r11, r12, r20, r21, r22, bits))
end

-- E(q) of v5.md §3.3: the packed codes of the f32 CFrame that packed codes decode to, or nil when
-- they do not decode.
local function reencodedRotation(key: number, bits: number): number?
	local flag, index, a, b, c = unpackedRotation(key)
	local decoded = Leaves.rotationOf(flag, index, a, b, c, bits, 0, 0, 0)
	if decoded == nil then
		return nil
	end

	return quantizedRotation(decoded, bits)
end

-- Returns the code of a vector component, or nil when it is past a bound by more than the f32
-- spacing there.
local function componentCode(value: number, axis: Ir.NumberCodec): number?
	local min, max = axis.min, axis.max
	if value >= min and value <= max then
		return Quant.number(value, min, axis.step, axis.steps)
	end

	if value < min and value >= min - Limits.f32Spacing(min) then
		return 0
	end

	if value > max and value <= max + Limits.f32Spacing(max) then
		return axis.steps
	end

	return nil
end

local function addMiss(misses: { Miss }, row: number, what: number, value: number)
	table.insert(misses, { row = row, what = what, value = value })
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns the angle code of a value.

	@param  value the value given
	@param  steps the codec's steps per turn
	@return the code, or nil when the value is not a finite number
]=]
function Leaves.angleCode(value: any, steps: number): number?
	if typeof(value) ~= "number" or not Limits.isFinite(value) then
		return nil
	end

	return Quant.angle(value, steps)
end

--[=[
	Returns whether a codec can hold a value the receiver can't resolve: a Roblox enum or an
	instance.

	@param  codec the codec
	@return true when a decoded value of it can be a miss
]=]
function Leaves.canMiss(codec: Ir.Codec): boolean
	local known = canMissByCodec[codec]
	if known ~= nil then
		return known
	end

	local canMiss = false
	if codec.kind == "robloxEnum" or codec.kind == "instance" then
		canMiss = true
	elseif codec.kind == "optional" or codec.kind == "array" then
		canMiss = Leaves.canMiss(codec.inner)
	elseif codec.kind == "map" then
		canMiss = Leaves.canMiss(codec.key) or Leaves.canMiss(codec.value)
	elseif codec.kind == "convert" then
		canMiss = Leaves.canMiss(codec.base)
	elseif codec.kind == "union" then
		for _, variant in codec.variants do
			canMiss = canMiss or Leaves.canMiss(variant.record)
		end
	elseif codec.kind == "record" then
		for _, field in codec.fields do
			canMiss = canMiss or Leaves.canMiss(field.codec)
		end
	end
	canMissByCodec[codec] = canMiss

	return canMiss
end

--[=[
	Returns the CFrame a rotation's codes decode to, when the codes are canonical (v5.md §3.3):
	with E(q) the codes of the f32 CFrame q decodes to, E(q) = q, or E(E(q)) = q and q is the lower
	of the 2-cycle. The check ignores the position.

	@param  flag  1 for an axis-aligned rotation, else 0
	@param  index the axis index, below 24 (flag 1), or the dropped component (flag 0)
	@param  a     the first kept component's code; 0 for flag 1
	@param  b     the second kept component's code; 0 for flag 1
	@param  c     the third kept component's code; 0 for flag 1
	@param  bits  the codec's bits per component
	@param  x     the position's x
	@param  y     the position's y
	@param  z     the position's z
	@return the CFrame, or nil when the codes do not decode or are not canonical (rule 6)
]=]
function Leaves.canonicalRotation(
	flag: number,
	index: number,
	a: number,
	b: number,
	c: number,
	bits: number,
	x: number,
	y: number,
	z: number
): CFrame?
	local decoded = Leaves.rotationOf(flag, index, a, b, c, bits, x, y, z)
	if decoded == nil then
		return nil
	end

	local key = packedRotation(flag, index, a, b, c)
	local reencoded = quantizedRotation(decoded, bits)
	if reencoded == key or (reencoded > key and reencodedRotation(reencoded, bits) == key) then
		return decoded
	end

	return nil
end

--[=[
	Returns the channel codes of a Color3.

	@param  value the value given
	@return the red code, or nil when the value is not a Color3 with channels in [0, 1]
	@return the green code
	@return the blue code
]=]
function Leaves.color3Codes(value: any): (number?, number, number)
	if typeof(value) ~= "Color3" then
		return nil, 0, 0
	end

	local red, green, blue = value.R, value.G, value.B
	if
		not (red >= 0 and red <= 1)
		or not (green >= 0 and green <= 1)
		or not (blue >= 0 and blue <= 1)
	then
		return nil, 0, 0
	end

	return Quant.color(red), Quant.color(green), Quant.color(blue)
end

--[=[
	Returns the Color3 that three channel codes stand for.

	@param  red   the red code, 0 to 255
	@param  green the green code
	@param  blue  the blue code
	@return the colour
]=]
function Leaves.color3Of(red: number, green: number, blue: number): Color3
	return Color3.new(Quant.uncolor(red), Quant.uncolor(green), Quant.uncolor(blue))
end

--[=[
	Returns the octahedral codes of a direction.

	@param  value the value given
	@param  bits  the codec's bits per code
	@return the x code, or nil when the value is not a finite non-zero Vector3
	@return the y code
]=]
function Leaves.directionCodes(value: any, bits: number): (number?, number)
	if typeof(value) ~= "Vector3" then
		return nil, 0
	end

	local x, y, z = value.X, value.Y, value.Z
	if not Limits.isFinite(x + y + z) or (x == 0 and y == 0 and z == 0) then
		return nil, 0
	end

	return Quant.direction(x, y, z, bits)
end

--[=[
	Returns the unit Vector3 that two octahedral codes stand for, when they are canonical.

	@param  xCode the x code
	@param  yCode the y code
	@param  bits  the codec's bits per code
	@return the direction, or nil when the codes are not canonical (rule 6)
]=]
function Leaves.directionOf(xCode: number, yCode: number, bits: number): Vector3?
	if not Quant.directionIsCanonical(xCode, yCode, bits) then
		return nil
	end

	return Vector3.new(Quant.undirection(xCode, yCode, bits))
end

--[=[
	Adds a segment to a refusal's path as it unwinds through a level.

	@param  refusal the refusal, changed
	@param  segment the level's place: `.field`, `[]` for an element or map value, `[key]`
	@return the refusal
]=]
function Leaves.extend(refusal: Refusal, segment: string): Refusal
	table.insert(refusal.path, segment)

	return refusal
end

--[=[
	Returns the IEEE-754 bits of a value as an f32.

	@param  value the value given
	@return the u32, or nil when the value is not a finite number within the f32 range
]=]
function Leaves.f32Bits(value: any): number?
	if typeof(value) ~= "number" or not (math.abs(value) <= MAX_F32) then
		return nil
	end

	buffer.writef32(FLOAT_SCRATCH, 0, value)

	return buffer.readu32(FLOAT_SCRATCH, 0)
end

--[=[
	Returns the number an f32's bits stand for.

	@param  bits the u32
	@return the number, or nil when it is NaN or infinite (rule 3)
]=]
function Leaves.f32Of(bits: number): number?
	buffer.writeu32(FLOAT_SCRATCH, 0, bits)
	local value = buffer.readf32(FLOAT_SCRATCH, 0)
	if not Limits.isFinite(value) then
		return nil
	end

	return value
end

--[=[
	Returns the IEEE-754 bits of a value as an f64.

	@param  value the value given
	@return the low u32, or nil when the value is not a finite number
	@return the high u32
]=]
function Leaves.f64Bits(value: any): (number?, number)
	if typeof(value) ~= "number" or not Limits.isFinite(value) then
		return nil, 0
	end

	buffer.writef64(FLOAT_SCRATCH, 0, value)

	return buffer.readu32(FLOAT_SCRATCH, 0), buffer.readu32(FLOAT_SCRATCH, 4)
end

--[=[
	Returns the number an f64's bits stand for.

	@param  low  the low u32
	@param  high the high u32
	@return the number, or nil when it is NaN or infinite (rule 3)
]=]
function Leaves.f64Of(low: number, high: number): number?
	buffer.writeu32(FLOAT_SCRATCH, 0, low)
	buffer.writeu32(FLOAT_SCRATCH, 4, high)
	local value = buffer.readf64(FLOAT_SCRATCH, 0)
	if not Limits.isFinite(value) then
		return nil
	end

	return value
end

--[=[
	Returns whether a codec can hold an instance.

	@param  codec the codec
	@return true when a value of it can reference an instance
]=]
function Leaves.hasInstance(codec: Ir.Codec): boolean
	local known = hasInstanceByCodec[codec]
	if known ~= nil then
		return known
	end

	local hasInstance = false
	if codec.kind == "instance" then
		hasInstance = true
	elseif codec.kind == "optional" or codec.kind == "array" then
		hasInstance = Leaves.hasInstance(codec.inner)
	elseif codec.kind == "map" then
		hasInstance = Leaves.hasInstance(codec.key) or Leaves.hasInstance(codec.value)
	elseif codec.kind == "convert" then
		hasInstance = Leaves.hasInstance(codec.base)
	elseif codec.kind == "union" then
		for _, variant in codec.variants do
			hasInstance = hasInstance or Leaves.hasInstance(variant.record)
		end
	elseif codec.kind == "record" then
		for _, field in codec.fields do
			hasInstance = hasInstance or Leaves.hasInstance(field.codec)
		end
	end
	hasInstanceByCodec[codec] = hasInstance

	return hasInstance
end

--[=[
	Returns the index of a listed instance, for encoding.

	@param  value     the value given
	@param  class     the class the instance must be (`IsA`), or nil for any
	@param  instances the chunk's instances, read only
	@return the index, from 0, or nil when the value is not an instance of the class
	@error  internal, when the instance was not listed by `Rows.collect` or `Run.collect`
]=]
function Leaves.instanceCode(value: any, class: string?, instances: Instances): number?
	if typeof(value) ~= "Instance" then
		return nil
	end

	local instance: Instance = value
	if class ~= nil and not instance:IsA(class) then
		return nil
	end

	local index = instances.index[instance]
	if index == nil then
		return Fail.caller(
			"internal",
			"an encoded instance",
			"be listed by Rows.collect or Run.collect before encoding",
			Fail.NONE,
			"report this as a Lync bug"
		)
	end

	return index
end

--[=[
	Returns the instance an index refers to, checking the order of first references.

	@param  chunk  the chunk's instances, its `firstSeen` advanced
	@param  index  the decoded index
	@param  class  the class the instance must be (`IsA`), or nil for any
	@param  misses where a nil instance or one of the wrong class is recorded
	@param  row    the row the index is in
	@return the instance, or nil
	@return 0, or the rule: 2 when the index is past the chunk's count, 9 when it skips an entry
	        not yet referenced
]=]
function Leaves.instanceOf(
	chunk: Chunk,
	index: number,
	class: string?,
	misses: { Miss },
	row: number
): (Instance?, number)
	if index >= chunk.count then
		return nil, 2
	end

	local firstSeen = chunk.firstSeen
	if index == firstSeen then
		chunk.firstSeen = firstSeen + 1
	elseif index > firstSeen then
		return nil, 9
	end

	local instance = chunk.list[chunk.offset + index + 1]
	if instance == nil then
		addMiss(misses, row, MISS_NIL, index)
		return nil, 0
	end

	if class ~= nil and not instance:IsA(class) then
		addMiss(misses, row, MISS_CLASS, index)
		return nil, 0
	end

	return instance, 0
end

--[=[
	Returns the width of an index into a chunk's instances.

	@param  count how many instances the chunk lists
	@return ceil(log2 count) bits, 0 for 0 or 1
]=]
function Leaves.instanceWidth(count: number): number
	if count == 0 then
		return 0
	end

	return Ints.width(count)
end

--[=[
	Returns the code of a value of `t.int(min, max)`.

	@param  value the value given
	@param  min   the codec's least value
	@param  max   the codec's greatest value
	@return value - min, or nil when the value is not an integer in [min, max]
]=]
function Leaves.intCode(value: any, min: number, max: number): number?
	if
		typeof(value) ~= "number"
		or not (value >= min and value <= max)
		or not Limits.isInteger(value)
	then
		return nil
	end

	return value - min
end

--[=[
	Returns whether two decoded map keys are strictly ascending (v5.md §3.3).

	@param  codec    the map's key codec
	@param  previous the earlier key
	@param  key      the later key
	@return true when `key` sorts after `previous`: integers by value, list enums by index,
	        strings bytewise
]=]
function Leaves.isAscending(codec: Ir.Codec, previous: any, key: any): boolean
	if codec.kind == "enum" then
		return codec.index[previous] < codec.index[key]
	end

	return previous < key
end

--[=[
	Lists an instance on its first reference, for collecting; a value the encoder would refuse is
	left out.

	@param value the value given
	@param class the class the instance must be (`IsA`), or nil for any
	@param into  the chunk's instances, extended
]=]
function Leaves.listInstance(value: any, class: string?, into: Instances)
	if typeof(value) ~= "Instance" then
		return
	end

	local instance: Instance = value
	if into.index[instance] ~= nil or (class ~= nil and not instance:IsA(class)) then
		return
	end

	table.insert(into.list, instance)
	into.index[instance] = #into.list - 1
end

--[=[
	Returns a new decoded record, its fields allocated and set to false.

	@param  fields  the record's fields
	@param  variant the union variant the record is, whose name is set as `kind`; nil for a record
	@return the record
]=]
function Leaves.newRecord(fields: { Ir.Field }, variant: Ir.Variant?): { [string]: any }
	local shape: any = if variant == nil then fields else variant
	local template = templateByShape[shape]
	if template == nil then
		template = {}
		for _, field in fields do
			template[field.name] = false
		end
		if variant ~= nil then
			template.kind = variant.name
		end
		templateByShape[shape] = template
	end

	return table.clone(template)
end

--[=[
	Returns the code of a value of `t.number`.

	@param  value the value given
	@param  codec the number codec
	@return the code q, or nil when the value is not a number in [min, max]
]=]
function Leaves.numberCode(value: any, codec: Ir.NumberCodec): number?
	if typeof(value) ~= "number" or not (value >= codec.min and value <= codec.max) then
		return nil
	end

	return Quant.number(value, codec.min, codec.step, codec.steps)
end

--[=[
	Raises the caller error for a refusal (`valueRefused`).

	@param refusal the refusal
	@param subject the definition and call, such as `arena.buy:invoke`
	@param root    the value the path starts from
	@error always
]=]
function Leaves.raise(refusal: Refusal, subject: string, root: Root): never
	local path = refusal.path
	local segments = table.create(#path + 1, "")
	segments[1] = root
	for i = #path, 1, -1 do
		segments[#path - i + 2] = path[i]
	end

	return Fail.caller(
		"valueRefused",
		`{subject} {table.concat(segments)}`,
		refusal.requirement,
		refusal.got
	)
end

--[=[
	Builds a codec's refusal of a value, with an empty path; a union refuses a table's `kind`.

	@param  codec the codec that refused
	@param  value the refused value
	@return the refusal
]=]
function Leaves.refusal(codec: Ir.Codec, value: any): Refusal
	if codec.kind == "union" and typeof(value) == "table" then
		local requirement = `be one of {namesOf(variantNamesOf(codec.variants))}`
		return { requirement = requirement, got = value.kind, path = { ".kind" } }
	end

	return { requirement = requirementOf(codec), got = value, path = {} }
end

--[=[
	Returns the code of a Roblox enum item: its `Value`.

	@param  value   the value given
	@param  byValue the codec's items by value
	@return the item's value, or nil when the value is not an item of the codec's enum
]=]
function Leaves.robloxEnumCode(value: any, byValue: { [number]: EnumItem }): number?
	if typeof(value) ~= "EnumItem" or byValue[value.Value] ~= value then
		return nil
	end

	return value.Value
end

--[=[
	Records a decoded Roblox enum value, returning its item, or recording a miss when the engine
	lacks it.

	@param  code    the decoded value
	@param  byValue the codec's items by value
	@param  misses  where an unknown value is recorded
	@param  row     the row the value is in
	@return the item, or nil when it is unknown
]=]
function Leaves.robloxEnumOf(
	code: number,
	byValue: { [number]: EnumItem },
	misses: { Miss },
	row: number
): EnumItem?
	local item = byValue[code]
	if item == nil then
		addMiss(misses, row, MISS_ENUM, code)
	end

	return item
end

--[=[
	Undoes a public encode that raised or refused: moves the writer back, and drops the
	instances listed since the last committed encode.

	@param w         the writer
	@param bit       the writer's `bit` on entry
	@param tailCount the length of its `tail` on entry
	@param tailBytes its `tailBytes` on entry
	@param instances the chunk's instances
	@param committed `instances.count` on entry
]=]
function Leaves.rollBack(
	w: Bits.Writer,
	bit: number,
	tailCount: number,
	tailBytes: number,
	instances: Instances,
	committed: number
)
	w.bit = bit
	local tail = w.tail
	for i = #tail, tailCount + 1, -1 do
		tail[i] = nil
	end
	w.tailBytes = tailBytes

	local list = instances.list
	for i = #list, committed + 1, -1 do
		instances.index[list[i]] = nil
		list[i] = nil
	end
	instances.count = committed
end

--[=[
	Returns the canonical smallest-three or axis codes of a CFrame's rotation, ignoring its
	position (v5.md §3.3).

	From the first encoding q, it takes q <- E(q), E(q) the codes of the f32 CFrame q decodes to,
	until q is a fixed point or the codes enter a 2-cycle, whose lower member it returns.

	@param  value a CFrame
	@param  bits  the codec's bits per component
	@return the flag, or nil when the rotation is not finite
	@return the axis index (flag 1) or the dropped component (flag 0)
	@return the first kept component's code
	@return the second kept component's code
	@return the third kept component's code
	@error  internal, when no canonical code is reached within 4 re-encodings
]=]
function Leaves.rotationCodes(
	value: CFrame,
	bits: number
): (number?, number, number, number, number)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
	if not Limits.isFinite(r00 + r01 + r02 + r10 + r11 + r12 + r20 + r21 + r22) then
		return nil, 0, 0, 0, 0
	end

	local previous = -1
	local current = quantizedRotation(value, bits)
	for _ = 1, MAX_ROTATION_STEPS do
		-- Cast: an encoding keeps the three smallest components, whose squares sum to at most
		-- 3/4, so it always decodes.
		local reencoded = reencodedRotation(current, bits) :: number
		if reencoded == current then
			return unpackedRotation(current)
		end

		if reencoded == previous then
			return unpackedRotation(math.min(previous, current))
		end

		previous, current = current, reencoded
	end

	-- `Fail.caller` never returns; neither solver accepts its call as a pack of five results.
	local unreachable: any = Fail.caller(
		"internal",
		"t.rotation encode",
		`reach a fixed point or a 2-cycle of encode(decode(q)) within {MAX_ROTATION_STEPS} steps`,
		Fail.NONE,
		"report this as a Lync bug"
	)
	return unreachable, 0, 0, 0, 0
end

--[=[
	Returns the CFrame that a rotation's codes and a position stand for, without checking that
	the codes are canonical.

	@param  flag  1 for an axis-aligned rotation, else 0
	@param  index the axis index, below 24 (flag 1), or the dropped component (flag 0)
	@param  a     the first kept component's code
	@param  b     the second kept component's code
	@param  c     the third kept component's code
	@param  bits  the codec's bits per component
	@param  x     the position's x
	@param  y     the position's y
	@param  z     the position's z
	@return the CFrame, or nil when the kept components' squares sum past 1 (rule 6)
]=]
function Leaves.rotationOf(
	flag: number,
	index: number,
	a: number,
	b: number,
	c: number,
	bits: number,
	x: number,
	y: number,
	z: number
): CFrame?
	if flag == 1 then
		local m = Quant.AXIS[index + 1]
		return CFrame.new(x, y, z, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
	end

	local qx, qy, qz, qw = Quant.unrotation(0, index, a, b, c, bits)
	if qx == nil then
		return nil
	end

	return CFrame.new(x, y, z, qx, qy, qz, qw)
end

--[=[
	Returns a map's keys in the order they are sent, checking their kind and count.

	@param  codec the map codec
	@param  value the value given
	@return the keys, integers by value, list enums by index and strings bytewise; nil on refusal
	@return the refusal: the map's when the value is not a table or has too many pairs, the key
	        codec's when a key is of the wrong kind
]=]
function Leaves.sortedKeys(codec: Ir.MapCodec, value: any): ({ any }?, Refusal?)
	if typeof(value) ~= "table" then
		return nil, Leaves.refusal(codec, value)
	end

	local keyCodec = codec.key
	local keyType = if keyCodec.kind == "int" or keyCodec.kind == "varint"
		then "number"
		else "string"
	local keys = {}
	for key in value do
		if typeof(key) ~= keyType then
			return nil, Leaves.extend(Leaves.refusal(keyCodec, key), "[key]")
		end

		if #keys == codec.max then
			return nil, Leaves.refusal(codec, value)
		end
		table.insert(keys, key)
	end

	if keyCodec.kind ~= "enum" then
		table.sort(keys)
		return keys, nil
	end

	local index = keyCodec.index
	for i, key in keys do
		local code = index[key]
		if code == nil then
			return nil, Leaves.extend(Leaves.refusal(keyCodec, key), "[key]")
		end
		keys[i] = code
	end
	table.sort(keys)

	local items = keyCodec.items
	for i, code in keys do
		keys[i] = items[code + 1]
	end

	return keys, nil
end

--[=[
	Returns the code of a value of `t.int()`: the value itself.

	@param  value the value given
	@return the value, or nil when it is not an integer in [-2^52, 2^52 - 1]
]=]
function Leaves.varintCode(value: any): number?
	if
		typeof(value) ~= "number"
		or not (value >= Limits.INT_MIN and value <= Limits.INT_MAX)
		or not Limits.isInteger(value)
	then
		return nil
	end

	return value
end

--[=[
	Returns the codes of a position's components under a `t.vector3` axis.

	Positions are stored in f32, so a component up to the f32 spacing at a bound past it,
	2^(floor(log2 |bound|) - 23), takes the end code (v5.md §3.3).

	@param  x    the x component
	@param  y    the y component
	@param  z    the z component
	@param  axis the axis codec
	@return the x code, or nil when a component is past [min, max] by more than that spacing
	@return the y code
	@return the z code
]=]
function Leaves.vector3Codes(
	x: number,
	y: number,
	z: number,
	axis: Ir.NumberCodec
): (number?, number, number)
	local xCode = componentCode(x, axis)
	local yCode = componentCode(y, axis)
	local zCode = componentCode(z, axis)
	if xCode == nil or yCode == nil or zCode == nil then
		return nil, 0, 0
	end

	return xCode, yCode, zCode
end

--[=[
	Returns the f32 bits of a position's components.

	@param  x the x component
	@param  y the y component
	@param  z the z component
	@return the x bits, or nil when a component is not finite
	@return the y bits
	@return the z bits
]=]
function Leaves.vector3f32Bits(x: number, y: number, z: number): (number?, number, number)
	local xBits = Leaves.f32Bits(x)
	local yBits = Leaves.f32Bits(y)
	local zBits = Leaves.f32Bits(z)
	if xBits == nil or yBits == nil or zBits == nil then
		return nil, 0, 0
	end

	return xBits, yBits, zBits
end

--[=[
	Writes a `t.custom` value with its own encoder, checking its declared sizes.

	@param  w     the writer
	@param  codec the custom codec
	@param  value the value given
	@return nil, or the refusal when the encoder wrote more than `maxBits` bits or `maxBytes`
	        tail bytes
]=]
function Leaves.writeCustom(w: Bits.Writer, codec: Ir.CustomCodec, value: any): Refusal?
	local startBit = w.bit
	local startBytes = w.tailBytes
	codec.encode(w, value)
	if w.bit - startBit > codec.maxBits or w.tailBytes - startBytes > codec.maxBytes then
		return Leaves.refusal(codec, value)
	end

	return nil
end

return table.freeze(Leaves)
