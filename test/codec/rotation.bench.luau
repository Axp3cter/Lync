--!strict

--[=[
	rotation.bench

	Measures `t.rotation` decoding with and without the canonical check of v5.md §3.3, on the Luau
	CLI, from the repo root:

	luau -O2 test/codec/rotation.bench.luau -a interpreted
	luau -O2 --codegen test/codec/rotation.bench.luau -a native

	The CLI has no `CFrame`, so a stand-in builds the f32 matrix a `CFrame` stores from a
	quaternion, in a table, and returns its entries as `GetComponents` does. A decode builds one
	`CFrame`; a checked decode builds the check's `CFrame`, re-encodes it (twice for a 2-cycle code),
	then builds the decoded `CFrame`, as `Leaves.canonicalRotation` and the decoders do. The cost
	of the engine's own `CFrame` is not measured. Each figure is the median of 15 interleaved samples,
	one JSON line each.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Quant = require("../../src/wire/quant")

-- Constants ---------------------------------------------------------------------------------------

const BITS = 9
const CODE_COUNT = 1024
const ROUNDS = 100
const SAMPLES = 15
const FLOAT_SCRATCH = buffer.create(4)

-- State -------------------------------------------------------------------------------------------

local seed = 12345

-- Private -----------------------------------------------------------------------------------------

local function nextRandom(): number
	seed = bit32.bxor(seed, bit32.lshift(seed, 13))
	seed = bit32.bxor(seed, bit32.rshift(seed, 17))
	seed = bit32.bxor(seed, bit32.lshift(seed, 5))

	return seed / 0x1_0000_0000
end

local function f32(value: number): number
	buffer.writef32(FLOAT_SCRATCH, 0, value)

	return buffer.readf32(FLOAT_SCRATCH, 0)
end

-- The stand-in for `CFrame.new(0, 0, 0, x, y, z, w)`: the normalised quaternion's matrix in f32.
local function matrixOf(x: number, y: number, z: number, w: number): { number }
	local length = math.sqrt(x * x + y * y + z * z + w * w)
	x, y, z, w = x / length, y / length, z / length, w / length

	return {
		f32(1 - 2 * (y * y + z * z)),
		f32(2 * (x * y - z * w)),
		f32(2 * (x * z + y * w)),
		f32(2 * (x * y + z * w)),
		f32(1 - 2 * (x * x + z * z)),
		f32(2 * (y * z - x * w)),
		f32(2 * (x * z - y * w)),
		f32(2 * (y * z + x * w)),
		f32(1 - 2 * (x * x + y * y)),
	}
end

local function decodedMatrix(codes: { number }): { number }?
	local x, y, z, w = Quant.unrotation(codes[1], codes[2], codes[3], codes[4], codes[5], BITS)
	if x == nil then
		return nil
	end

	return matrixOf(x, y, z, w)
end

local function reencoded(codes: { number }): { number }?
	local m = decodedMatrix(codes)
	if m == nil then
		return nil
	end

	return { Quant.rotation(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], BITS) }
end

local function isSame(left: { number }, right: { number }): boolean
	return left[1] == right[1]
		and left[2] == right[2]
		and left[3] == right[3]
		and left[4] == right[4]
		and left[5] == right[5]
end

local function isLower(left: { number }, right: { number }): boolean
	for i = 1, 5 do
		if left[i] ~= right[i] then
			return left[i] < right[i]
		end
	end

	return false
end

local function isCanonical(codes: { number }): boolean
	local once = reencoded(codes)
	if once == nil then
		return false
	end

	if isSame(once, codes) then
		return true
	end

	if not isLower(codes, once) then
		return false
	end

	local twice = reencoded(once)
	return twice ~= nil and isSame(twice, codes)
end

local function codeSet(): { { number } }
	local codes = {}
	while #codes < CODE_COUNT do
		local m =
			matrixOf(nextRandom() - 0.5, nextRandom() - 0.5, nextRandom() - 0.5, nextRandom() - 0.5)
		local candidate =
			{ Quant.rotation(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], BITS) }
		if isCanonical(candidate) then
			table.insert(codes, candidate)
		end
	end

	return codes
end

local function nanosecondsPerDecode(codes: { { number } }, isChecked: boolean): number
	local start = os.clock()
	for _ = 1, ROUNDS do
		for _, code in codes do
			if isChecked and not isCanonical(code) then
				error("a benchmark code must be canonical")
			end
			decodedMatrix(code)
		end
	end

	return (os.clock() - start) / (ROUNDS * #codes) * 1e9
end

-- Main --------------------------------------------------------------------------------------------

local args = { ... }
local label = args[1] or "unlabelled"
local codes = codeSet()
nanosecondsPerDecode(codes, true)

local plainSamples = {}
local checkedSamples = {}
for i = 1, SAMPLES do
	plainSamples[i] = nanosecondsPerDecode(codes, false)
	checkedSamples[i] = nanosecondsPerDecode(codes, true)
end
table.sort(plainSamples)
table.sort(checkedSamples)

local median = (SAMPLES + 1) // 2
local plain = plainSamples[median]
local checked = checkedSamples[median]
print(
	string.format(
		'{"bench":"rotationDecode","bits":%d,"mode":"%s","check":false,"ns":%.1f}',
		BITS,
		label,
		plain
	)
)
print(
	string.format(
		'{"bench":"rotationDecode","bits":%d,"mode":"%s","check":true,"ns":%.1f}',
		BITS,
		label,
		checked
	)
)
print(
	string.format(
		'{"bench":"rotationDecode","bits":%d,"mode":"%s","checkRatio":%.2f}',
		BITS,
		label,
		checked / plain
	)
)
