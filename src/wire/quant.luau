--!strict

--[=[
	Quant

	The quantizers of v5.md §3.3 ("Quantizers, exactly"): `t.number`, `t.angle`, octahedral
	`t.direction`, smallest-three `t.rotation` and `t.color3`, as pure arithmetic on numbers.

	Callers check ranges and refusals (NaN, out-of-range values, a zero direction) before
	quantizing; decoders check codes against their widths. Nothing here touches Roblox types.
]=]

-- Module ------------------------------------------------------------------------------------------

local Quant = {}

-- Constants ---------------------------------------------------------------------------------------

const TAU = 2 * math.pi
const SQRT2 = math.sqrt(2)
const STEP_TOLERANCE = 1e-9
const AXIS_TOLERANCE = 1e-6
const COLOR_STEPS = 255

--- The 24 axis-aligned rotation matrices, row-major, in ascending lexicographic order of entries.
const AXIS: { { number } } = {
	{ -1, 0, 0, 0, -1, 0, 0, 0, 1 },
	{ -1, 0, 0, 0, 0, -1, 0, -1, 0 },
	{ -1, 0, 0, 0, 0, 1, 0, 1, 0 },
	{ -1, 0, 0, 0, 1, 0, 0, 0, -1 },
	{ 0, -1, 0, -1, 0, 0, 0, 0, -1 },
	{ 0, -1, 0, 0, 0, -1, 1, 0, 0 },
	{ 0, -1, 0, 0, 0, 1, -1, 0, 0 },
	{ 0, -1, 0, 1, 0, 0, 0, 0, 1 },
	{ 0, 0, -1, -1, 0, 0, 0, 1, 0 },
	{ 0, 0, -1, 0, -1, 0, -1, 0, 0 },
	{ 0, 0, -1, 0, 1, 0, 1, 0, 0 },
	{ 0, 0, -1, 1, 0, 0, 0, -1, 0 },
	{ 0, 0, 1, -1, 0, 0, 0, -1, 0 },
	{ 0, 0, 1, 0, -1, 0, 1, 0, 0 },
	{ 0, 0, 1, 0, 1, 0, -1, 0, 0 },
	{ 0, 0, 1, 1, 0, 0, 0, 1, 0 },
	{ 0, 1, 0, -1, 0, 0, 0, 0, 1 },
	{ 0, 1, 0, 0, 0, -1, -1, 0, 0 },
	{ 0, 1, 0, 0, 0, 1, 1, 0, 0 },
	{ 0, 1, 0, 1, 0, 0, 0, 0, -1 },
	{ 1, 0, 0, 0, -1, 0, 0, 0, -1 },
	{ 1, 0, 0, 0, 0, -1, 0, 1, 0 },
	{ 1, 0, 0, 0, 0, 1, 0, -1, 0 },
	{ 1, 0, 0, 0, 1, 0, 0, 0, 1 },
}

--- The index into AXIS (from 0) of each matrix, keyed by its entries + 1 read as base-3 digits.
const AXIS_INDEX_BY_KEY: { [number]: number } = {}

for i, entries in AXIS do
	local key = 0
	for _, entry in entries do
		key = key * 3 + entry + 1
	end
	AXIS_INDEX_BY_KEY[key] = i - 1
	table.freeze(entries)
end
table.freeze(AXIS)
table.freeze(AXIS_INDEX_BY_KEY)

-- Private -----------------------------------------------------------------------------------------

local function signOf(v: number): number
	return if v < 0 then -1 else 1
end

local function directionCode(c: number, maxCode: number): number
	return math.floor((c + 1) / 2 * maxCode + 0.5)
end

local function componentCode(c: number, maxCode: number): number
	return math.clamp(math.floor((c * SQRT2 + 1) / 2 * maxCode + 0.5), 0, maxCode)
end

local function component(q: number, maxCode: number): number
	return (2 * q / maxCode - 1) / SQRT2
end

local function withDigit(key: number?, entry: number): number?
	if key == nil then
		return nil
	end

	local rounded = math.round(entry)
	if math.abs(entry - rounded) > AXIS_TOLERANCE then
		return nil
	end

	return key * 3 + rounded + 1
end

local function axisIndexOf(
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
): number?
	local key: number? = 0
	key = withDigit(key, r00)
	key = withDigit(key, r01)
	key = withDigit(key, r02)
	key = withDigit(key, r10)
	key = withDigit(key, r11)
	key = withDigit(key, r12)
	key = withDigit(key, r20)
	key = withDigit(key, r21)
	key = withDigit(key, r22)
	if key == nil then
		return nil
	end

	return AXIS_INDEX_BY_KEY[key]
end

-- Takes the quaternion by the branch with the largest of (trace, r00, r11, r22), ties in that order.
local function quaternionOf(
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
): (number, number, number, number)
	local trace = r00 + r11 + r22
	if trace >= r00 and trace >= r11 and trace >= r22 then
		local w = math.sqrt(1 + trace) / 2
		return (r21 - r12) / (4 * w), (r02 - r20) / (4 * w), (r10 - r01) / (4 * w), w
	end

	if r00 >= r11 and r00 >= r22 then
		local s = 2 * math.sqrt(1 + r00 - r11 - r22)
		return s / 4, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s
	end

	if r11 >= r22 then
		local s = 2 * math.sqrt(1 + r11 - r00 - r22)
		return (r01 + r10) / s, s / 4, (r12 + r21) / s, (r02 - r20) / s
	end

	local s = 2 * math.sqrt(1 + r22 - r00 - r11)
	return (r02 + r20) / s, (r12 + r21) / s, s / 4, (r10 - r01) / s
end

-- Public ------------------------------------------------------------------------------------------

Quant.AXIS = AXIS

--[=[
	Quantizes an angle to one of `n` equal steps of a turn.

	@param  v an angle in radians, finite
	@param  n the steps per turn, from `Quant.angleSteps`
	@return q = floor(wrap(v) * n / 2pi + 0.5) mod n, wrap(v) in [0, 2pi)
]=]
function Quant.angle(v: number, n: number): number
	return math.floor(v % TAU * n / TAU + 0.5) % n
end

--[=[
	Returns the steps per turn of `t.angle(step)`.

	@param  step the declared step in radians, positive
	@return 2pi / step rounded when within 1e-9 * max(1, r) of an integer, else rounded up
]=]
function Quant.angleSteps(step: number): number
	local ratio = TAU / step
	local nearest = math.round(ratio)
	if math.abs(ratio - nearest) <= STEP_TOLERANCE * math.max(1, ratio) then
		return nearest
	end

	return math.ceil(ratio)
end

--[=[
	Quantizes a colour channel.

	@param  c the channel, in [0, 1]
	@return floor(c * 255 + 0.5)
]=]
function Quant.color(c: number): number
	return math.floor(c * COLOR_STEPS + 0.5)
end

--[=[
	Quantizes a direction by the octahedral mapping.

	@param  x    the direction's x, finite
	@param  y    the direction's y, finite
	@param  z    the direction's z, finite; x, y and z are not all zero
	@param  bits the width of each code, 8 to 16
	@return the code of the mapped x, in [0, 2^bits - 1]
	@return the code of the mapped y, in [0, 2^bits - 1]
]=]
function Quant.direction(x: number, y: number, z: number, bits: number): (number, number)
	local sum = math.abs(x) + math.abs(y) + math.abs(z)
	local px = x / sum
	local py = y / sum
	if z < 0 then
		local foldedX = (1 - math.abs(py)) * signOf(px)
		local foldedY = (1 - math.abs(px)) * signOf(py)
		px = foldedX
		py = foldedY
	end

	local maxCode = 2 ^ bits - 1
	return directionCode(px, maxCode), directionCode(py, maxCode)
end

--[=[
	Returns whether a direction code is canonical: the code its own decoded direction encodes to
	(v5.md §3.3). Codes on the fold edge that decode to one direction as another code does are not.

	@param  qx   the code of the mapped x
	@param  qy   the code of the mapped y
	@param  bits the width of each code
	@return true when `Quant.direction(Quant.undirection(qx, qy, bits))` is `(qx, qy)`
]=]
function Quant.directionIsCanonical(qx: number, qy: number, bits: number): boolean
	local x, y, z = Quant.undirection(qx, qy, bits)
	local encodedX, encodedY = Quant.direction(x, y, z, bits)

	return encodedX == qx and encodedY == qy
end

--[=[
	Quantizes a number to its step on a declared range.

	@param  v    the value, in [min, max]
	@param  min  the range's lowest value
	@param  step the declared step
	@param  n    the range's steps, from `Quant.numberSteps`
	@return q = min(floor((v - min) / step + 0.5), n)
]=]
function Quant.number(v: number, min: number, step: number, n: number): number
	return math.min(math.floor((v - min) / step + 0.5), n)
end

--[=[
	Returns the steps of `t.number(min, max, step)`.

	@param  min  the range's lowest value
	@param  max  the range's highest value
	@param  step the declared step, positive
	@return n, the integer within 1e-9 * max(1, r) of r = (max - min) / step, or nil when there is
	        none (`numberStep`)
]=]
function Quant.numberSteps(min: number, max: number, step: number): number?
	local ratio = (max - min) / step
	local nearest = math.round(ratio)
	if math.abs(ratio - nearest) > STEP_TOLERANCE * math.max(1, ratio) then
		return nil
	end

	return nearest
end

--[=[
	Quantizes a rotation matrix: an axis-aligned one by its index, any other by smallest-three.

	@param  r00  row 0, column 0 of the matrix, as `CFrame:GetComponents()` gives it
	@param  r01  row 0, column 1
	@param  r02  row 0, column 2
	@param  r10  row 1, column 0
	@param  r11  row 1, column 1
	@param  r12  row 1, column 2
	@param  r20  row 2, column 0
	@param  r21  row 2, column 1
	@param  r22  row 2, column 2
	@param  bits the width of each component code, 7 to 15
	@return the flag: 1 when every entry is within 1e-6 of 0 or ±1, else 0
	@return flag 1: the matrix's index in Quant.AXIS, from 0; flag 0: the dropped component, 0 to
	        3 for x y z w
	@return the first kept component's code in x y z w order; 0 for flag 1
	@return the second kept component's code; 0 for flag 1
	@return the third kept component's code; 0 for flag 1
]=]
function Quant.rotation(
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number,
	bits: number
): (number, number, number, number, number)
	local axisIndex = axisIndexOf(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	if axisIndex ~= nil then
		return 1, axisIndex, 0, 0, 0
	end

	local x, y, z, w = quaternionOf(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	local dropped = 0
	local droppedComponent = x
	if math.abs(y) > math.abs(droppedComponent) then
		dropped = 1
		droppedComponent = y
	end
	if math.abs(z) > math.abs(droppedComponent) then
		dropped = 2
		droppedComponent = z
	end
	if math.abs(w) > math.abs(droppedComponent) then
		dropped = 3
		droppedComponent = w
	end

	local sign = signOf(droppedComponent)
	local maxCode = 2 ^ bits - 1
	local xCode = componentCode(sign * x, maxCode)
	local yCode = componentCode(sign * y, maxCode)
	local zCode = componentCode(sign * z, maxCode)
	local wCode = componentCode(sign * w, maxCode)
	if dropped == 0 then
		return 0, 0, yCode, zCode, wCode
	elseif dropped == 1 then
		return 0, 1, xCode, zCode, wCode
	elseif dropped == 2 then
		return 0, 2, xCode, yCode, wCode
	end

	return 0, 3, xCode, yCode, zCode
end

--[=[
	Returns the angle a step code stands for.

	@param  q the code, in [0, n - 1]
	@param  n the steps per turn
	@return q * 2pi / n radians
]=]
function Quant.unangle(q: number, n: number): number
	return q * TAU / n
end

--[=[
	Returns the channel a colour code stands for.

	@param  q the code, in [0, 255]
	@return q / 255
]=]
function Quant.uncolor(q: number): number
	return q / COLOR_STEPS
end

--[=[
	Returns the unit direction two octahedral codes stand for.

	@param  qx   the code of the mapped x, in [0, 2^bits - 1]
	@param  qy   the code of the mapped y, in [0, 2^bits - 1]
	@param  bits the width of each code
	@return the direction's x
	@return the direction's y
	@return the direction's z
]=]
function Quant.undirection(qx: number, qy: number, bits: number): (number, number, number)
	local maxCode = 2 ^ bits - 1
	local cx = 2 * qx / maxCode - 1
	local cy = 2 * qy / maxCode - 1
	local z = 1 - math.abs(cx) - math.abs(cy)
	if z < 0 then
		local foldedX = (1 - math.abs(cy)) * signOf(cx)
		local foldedY = (1 - math.abs(cx)) * signOf(cy)
		cx = foldedX
		cy = foldedY
	end

	local length = math.sqrt(cx * cx + cy * cy + z * z)
	return cx / length, cy / length, z / length
end

--[=[
	Returns the number a step code stands for.

	@param  q    the code, in [0, n]
	@param  min  the range's lowest value
	@param  step the declared step
	@param  max  the range's highest value
	@return min(min + q * step, max), so the top code decodes to a value its encoder accepts
]=]
function Quant.unnumber(q: number, min: number, step: number, max: number): number
	return math.min(min + q * step, max)
end

--[=[
	Returns the quaternion a rotation's codes stand for.

	@param  flag  1 for an axis-aligned rotation, else 0
	@param  index flag 1: the index in Quant.AXIS, 0 to 23; flag 0: the dropped component, 0 to 3
	@param  a     the first kept component's code; ignored for flag 1
	@param  b     the second kept component's code; ignored for flag 1
	@param  c     the third kept component's code; ignored for flag 1
	@param  bits  the width of each component code
	@return the quaternion's x, or nil when the kept components' squares sum past 1 (rule 6)
	@return the quaternion's y
	@return the quaternion's z
	@return the quaternion's w
]=]
function Quant.unrotation(
	flag: number,
	index: number,
	a: number,
	b: number,
	c: number,
	bits: number
): (number?, number, number, number)
	if flag == 1 then
		local entries = AXIS[index + 1]
		return quaternionOf(table.unpack(entries))
	end

	local maxCode = 2 ^ bits - 1
	local first = component(a, maxCode)
	local second = component(b, maxCode)
	local third = component(c, maxCode)
	local squares = first * first + second * second + third * third
	if squares > 1 then
		return nil, 0, 0, 0
	end

	local dropped = math.sqrt(math.max(0, 1 - squares))
	if index == 0 then
		return dropped, first, second, third
	elseif index == 1 then
		return first, dropped, second, third
	elseif index == 2 then
		return first, second, dropped, third
	end

	return first, second, third, dropped
end

return table.freeze(Quant)
