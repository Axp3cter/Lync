--!strict

--[=[
	Leaves

	What single rows and column blocks share (v5.md §3.3, §4.2): checking a leaf value and
	turning it into its codes, turning codes back into a value, the refusals encoders return, and
	the instance lists that chunks' indices point into.

	A `...Code` function returns nil when the codec refuses the value, and the encoder then builds
	the refusal with `Leaves.refusal`, so no message is formatted on the success path.

	Decoding tracks one chunk's instance list at a time: indices must reference its entries in
	order of first reference, and every entry must be referenced (rule 9). `Leaves.beginInstances`
	starts a chunk; reading an index of another list starts that list instead.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Fail = require("../diag/fail")
local Ints = require("../wire/ints")
local Ir = require("../plan/ir")
local Quant = require("../wire/quant")

-- Module ------------------------------------------------------------------------------------------

local Leaves = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	The instances a chunk references, each listed once in order of first reference (v5.md §4.2).

	@field list  the instances, in order of first reference
	@field index each listed instance's index in `list`, from 0
]=]
export type Instances = { list: { Instance }, index: { [Instance]: number } }

--[=[
	Why an encoder refused a value.

	@field requirement what the value must be, completing "<subject> must"
	@field got         the refused value
	@field path        the place of the value, one segment per level, innermost first
]=]
export type Refusal = { requirement: string, got: any, path: { string } }

-- Constants ---------------------------------------------------------------------------------------

--- The first segment of every refusal's path: payloads are the definitions' `data`.
const ROOT_PATH = "data"

--- The longest list of names a requirement spells out; messages are cut at 200 bytes anyway.
const MAX_NAMES_BYTES = 200

const MAX_F32 = 3.4028234663852886e38
const MIN_VARINT = -2 ^ 52
const MAX_VARINT = 2 ^ 52 - 1

const FLOAT_SCRATCH = buffer.create(8)

-- State -------------------------------------------------------------------------------------------

--- The decoded record shape of each record codec's fields, or union variant, cloned per value.
local templateByShape: { [any]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any

--- The instance list whose first references are being tracked.
local trackedList: { Instance? }? = nil

--- How many of `trackedList`'s entries have been referenced so far.
local referencedCount = 0

local seenInstances: { [Instance]: boolean } = {}

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

local function isFinite(value: number): boolean
	return value - value == 0
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns the angle code of a value.

	@param  value the value given
	@param  steps the codec's steps per turn
	@return the code, or nil when the value is not a finite number
]=]
function Leaves.angleCode(value: any, steps: number): number?
	if typeof(value) ~= "number" or not isFinite(value) then
		return nil
	end

	return Quant.angle(value, steps)
end

--[=[
	Starts tracking a chunk's instance list, and checks that no instance is listed twice.

	@param  list the instances the chunk's header announced; a missing one is nil
	@return 0, or 9 when an instance repeats an earlier entry (v5.md §4.8)
]=]
function Leaves.beginInstances(list: { Instance? }): number
	trackedList = list
	referencedCount = 0

	local rule = 0
	for i = 1, #list do
		local instance = list[i]
		if instance == nil then
			continue
		end

		if seenInstances[instance] then
			rule = 9
			break
		end
		seenInstances[instance] = true
	end
	table.clear(seenInstances)

	return rule
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
	if not isFinite(x + y + z) or (x == 0 and y == 0 and z == 0) then
		return nil, 0
	end

	return Quant.direction(x, y, z, bits)
end

--[=[
	Returns the unit Vector3 that two octahedral codes stand for.

	@param  xCode the x code
	@param  yCode the y code
	@param  bits  the codec's bits per code
	@return the direction
]=]
function Leaves.directionOf(xCode: number, yCode: number, bits: number): Vector3
	return Vector3.new(Quant.undirection(xCode, yCode, bits))
end

--[=[
	Ends the instance tracking that `Leaves.beginInstances` started.

	@param  list the chunk's instance list
	@return 0, or 9 when an entry was never referenced (v5.md §4.8)
]=]
function Leaves.endInstances(list: { Instance? }): number
	return if referencedCount == #list then 0 else 9
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
	if not isFinite(value) then
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
	if typeof(value) ~= "number" or not isFinite(value) then
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
	if not isFinite(value) then
		return nil
	end

	return value
end

--[=[
	Returns the code of a value of `t.int(min, max)`.

	@param  value the value given
	@param  min   the codec's least value
	@param  max   the codec's greatest value
	@return value - min, or nil when the value is not an integer in [min, max]
]=]
function Leaves.intCode(value: any, min: number, max: number): number?
	if typeof(value) ~= "number" or not (value >= min and value <= max) or value // 1 ~= value then
		return nil
	end

	return value - min
end

--[=[
	Returns the index of an instance in a chunk's list, listing it on its first reference.

	@param  value     the value given
	@param  class     the class the instance must be (`IsA`), or nil for any
	@param  instances the chunk's instances, extended on a first reference
	@return the index, from 0, or nil when the value is not an instance of the class
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
	if index ~= nil then
		return index
	end

	local list = instances.list
	table.insert(list, instance)
	index = #list - 1
	instances.index[instance] = index

	return index
end

--[=[
	Returns the instance an index refers to, checking the order of first references.

	@param  list  the chunk's instance list
	@param  index the decoded index
	@param  class the class the instance must be (`IsA`), or nil for any
	@return the instance, or nil when the index is refused, the entry is nil, or the instance is
	        not of the class (milestone 2's `unresolved`)
	@return 0, or the rule: 2 when the index is past the list, 9 when it skips an entry not yet
	        referenced
]=]
function Leaves.instanceOf(list: { Instance? }, index: number, class: string?): (Instance?, number)
	if index >= #list then
		return nil, 2
	end

	if trackedList ~= list then
		trackedList = list
		referencedCount = 0
	end

	if index == referencedCount then
		referencedCount += 1
	elseif index > referencedCount then
		return nil, 9
	end

	local instance = list[index + 1]
	if instance == nil or (class ~= nil and not instance:IsA(class)) then
		return nil, 0
	end

	return instance, 0
end

--[=[
	Returns the width of an index into an instance list.

	@param  count how many instances the list holds
	@return ceil(log2 count) bits, 0 for 0 or 1
]=]
function Leaves.instanceWidth(count: number): number
	if count == 0 then
		return 0
	end

	return Ints.width(count)
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
	Returns the code of a value of `t.number`, or of one component of `t.vector3`.

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
	@error always
]=]
function Leaves.raise(refusal: Refusal, subject: string): never
	local path = refusal.path
	local segments = table.create(#path + 1)
	segments[1] = ROOT_PATH
	for i = #path, 1, -1 do
		table.insert(segments, path[i])
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
	Moves a writer back to an earlier state, dropping what was written since.

	@param w         the writer
	@param bit       the writer's `bit` then
	@param tailCount the length of its `tail` then
	@param tailBytes its `tailBytes` then
]=]
function Leaves.reset(w: Bits.Writer, bit: number, tailCount: number, tailBytes: number)
	w.bit = bit
	local tail = w.tail
	for i = #tail, tailCount + 1, -1 do
		tail[i] = nil
	end
	w.tailBytes = tailBytes
end

--[=[
	Returns the code of a Roblox enum item: its `Value`.

	@param  value  the value given
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
	Returns the smallest-three or axis codes of a CFrame's rotation, ignoring its position.

	@param  value a CFrame
	@param  bits  the codec's bits per component
	@return the flag, or nil when the rotation is not finite
	@return the axis index (flag 1) or the dropped component (flag 0)
	@return the first kept component's code
	@return the second kept component's code
	@return the third kept component's code
]=]
function Leaves.rotationCodes(
	value: CFrame,
	bits: number
): (number?, number, number, number, number)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
	if not isFinite(r00 + r01 + r02 + r10 + r11 + r12 + r20 + r21 + r22) then
		return nil, 0, 0, 0, 0
	end

	return Quant.rotation(r00, r01, r02, r10, r11, r12, r20, r21, r22, bits)
end

--[=[
	Returns the CFrame that a rotation's codes and a position stand for.

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
function Leaves.sortedKeys(codec: Ir.Codec, value: any): ({ any }?, Refusal?)
	assert(codec.kind == "map", "a map codec")
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
		or not (value >= MIN_VARINT and value <= MAX_VARINT)
		or value // 1 ~= value
	then
		return nil
	end

	return value
end

--[=[
	Returns the codes of a position's components under a `t.vector3` axis.

	@param  x    the x component
	@param  y    the y component
	@param  z    the z component
	@param  axis the axis codec
	@return the x code, or nil when a component is outside [min, max]
	@return the y code
	@return the z code
]=]
function Leaves.vector3Codes(
	x: number,
	y: number,
	z: number,
	axis: Ir.NumberCodec
): (number?, number, number)
	local min, max = axis.min, axis.max
	if
		not (x >= min and x <= max)
		or not (y >= min and y <= max)
		or not (z >= min and z <= max)
	then
		return nil, 0, 0
	end

	local step, steps = axis.step, axis.steps
	return Quant.number(x, min, step, steps),
		Quant.number(y, min, step, steps),
		Quant.number(z, min, step, steps)
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
function Leaves.writeCustom(w: Bits.Writer, codec: Ir.Codec, value: any): Refusal?
	assert(codec.kind == "custom", "a custom codec")
	local startBit = w.bit
	local startBytes = w.tailBytes
	codec.encode(w, value)
	if w.bit - startBit > codec.maxBits or w.tailBytes - startBytes > codec.maxBytes then
		return Leaves.refusal(codec, value)
	end

	return nil
end

return table.freeze(Leaves)
