--!strict

--[=[
	min_rows

	Lune script that measures `columnMinRows` (m1-plan.md §3, unit C; v5.md §4.9), from the repo
	root: `lune run test/codec/min_rows.luau`.

	For `strike`'s, `announce`'s and `fighters`' data and a `{ t.int(0, 100) }` record, it prints the
	bits of n single rows against one column block for n = 1 to 8, on four synthetic patterns of
	each leaf's codes: constant, ±1 noise, Gaussian with σ = 50, and changes in 10% of rows. Each
	figure is the mean over many draws. The smallest n where the column block is no larger, summed
	over the four codecs, in at least three of the four patterns is `Column.MIN_ROWS`.
]=]

-- Imports -----------------------------------------------------------------------------------------

local roblox = require("@lune/roblox")

-- The codecs need Roblox datatypes as globals, as `test/run.luau` provides them.
local environment = getfenv(0)
environment.Vector3 = roblox.Vector3
environment.CFrame = roblox.CFrame
environment.Color3 = roblox.Color3
environment.Instance = roblox.Instance
environment.Enum = roblox.Enum

local Bits = require("../../src/wire/bits")
local Columns = require("../../src/codec/columns")
local Frame = require("../support/frame")
local Gen = require("../support/gen")
local Ir = require("../../src/plan/ir")
local Leaves = require("../../src/codec/leaves")
local Lync = require("../../src")
local Quant = require("../../src/wire/quant")
local Rows = require("../../src/codec/rows")

-- Types -------------------------------------------------------------------------------------------

type Pattern = "constant" | "noise" | "gaussian" | "sparse"

--- A leaf's code stream: its base code and the current offset from it.
type Stream = { base: number, offset: number }

-- Constants ---------------------------------------------------------------------------------------

const MAX_N = 8
const DRAWS = 200
const PATTERNS: { Pattern } = { "constant", "noise", "gaussian", "sparse" }
const SIGMA = 50
const SPARSE_CHANCE = 0.1
const SPARSE_JUMP = 50

--- Rotation components stay within this many codes of the centre, so `w` is always dropped.
const ROTATION_SPREAD = 100

-- Private -----------------------------------------------------------------------------------------

local function gaussian(): number
	return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
end

local function nextCode(
	streams: { [string]: Stream },
	key: string,
	n: number,
	pattern: Pattern
): number
	local stream = streams[key]
	if stream == nil then
		stream = { base = math.floor(math.random() * n), offset = 0 }
		streams[key] = stream
	end

	if pattern == "noise" then
		stream.offset = math.random(-1, 1)
	elseif pattern == "gaussian" then
		stream.offset = math.floor(gaussian() * SIGMA + 0.5)
	elseif pattern == "sparse" and math.random() < SPARSE_CHANCE then
		stream.offset += math.random(-SPARSE_JUMP, SPARSE_JUMP)
	end

	return math.clamp(stream.base + stream.offset, 0, n - 1)
end

local function valueOf(
	codec: Ir.Codec,
	key: string,
	streams: { [string]: Stream },
	pattern: Pattern
): any
	if codec.kind == "bool" then
		return nextCode(streams, key, 2, pattern) == 1
	elseif codec.kind == "int" then
		return codec.min + nextCode(streams, key, codec.max - codec.min + 1, pattern)
	elseif codec.kind == "enum" then
		return codec.items[nextCode(streams, key, #codec.items, pattern) + 1]
	elseif codec.kind == "string" then
		return string.rep("x", nextCode(streams, key, codec.max + 1, pattern))
	elseif codec.kind == "vector3" then
		local axis = codec.axis
		local n = axis.steps + 1
		local x = nextCode(streams, `{key}.x`, n, pattern)
		local y = nextCode(streams, `{key}.y`, n, pattern)
		local z = nextCode(streams, `{key}.z`, n, pattern)
		return Vector3.new(
			Quant.unnumber(x, axis.min, axis.step, axis.max),
			Quant.unnumber(y, axis.min, axis.step, axis.max),
			Quant.unnumber(z, axis.min, axis.step, axis.max)
		)
	elseif codec.kind == "direction" then
		local n = 2 ^ codec.bits
		local x = nextCode(streams, `{key}.x`, n, pattern)
		local y = nextCode(streams, `{key}.y`, n, pattern)
		return Leaves.directionOf(x, y, codec.bits)
	elseif codec.kind == "rotation" then
		local bits = codec.bits
		local low = (2 ^ bits - 1) // 2 - ROTATION_SPREAD
		local spread = 2 * ROTATION_SPREAD + 1
		local a = low + nextCode(streams, `{key}.a`, spread, pattern)
		local b = low + nextCode(streams, `{key}.b`, spread, pattern)
		local c = low + nextCode(streams, `{key}.c`, spread, pattern)
		return Leaves.rotationOf(0, 3, a, b, c, bits, 0, 0, 0)
	elseif codec.kind == "optional" then
		if nextCode(streams, `{key}?`, 2, pattern) == 0 then
			return nil
		end
		return valueOf(codec.inner, key, streams, pattern)
	elseif codec.kind == "union" then
		local variant = codec.variants[nextCode(streams, `{key}#`, #codec.variants, pattern) + 1]
		local value = valueOf(variant.record, `{key}.{variant.name}`, streams, pattern)
		value.kind = variant.name
		return value
	elseif codec.kind == "record" then
		local record = {}
		for _, field in codec.fields do
			record[field.name] = valueOf(field.codec, `{key}.{field.name}`, streams, pattern)
		end
		return record
	end

	error(`the benchmark must know the codec kind {codec.kind}`)
end

-- Returns the mean bits of n single rows and of one column block over `DRAWS` draws.
local function bitsOf(codec: Ir.Codec, n: number, pattern: Pattern): (number, number)
	local rowBits = 0
	local blockBits = 0
	for _ = 1, DRAWS do
		local streams = {}
		local values = {}
		for i = 1, n do
			values[i] = valueOf(codec, "", streams, pattern)
		end

		local rows = Bits.writer()
		for i = 1, n do
			assert(Rows.write(rows, codec, values[i], { list = {}, index = {} }) == nil, "rows")
		end
		local block = Bits.writer()
		assert(Columns.write(block, codec, values, 1, n, { list = {}, index = {} }) == nil, "block")

		rowBits += rows.bit
		blockBits += block.bit
	end

	return rowBits / DRAWS, blockBits / DRAWS
end

-- Main --------------------------------------------------------------------------------------------

math.randomseed(20261015)

local arena = Frame.arena()
local codecs: { { name: string, codec: Ir.Codec } } = {
	{ name = "strike", codec = arena.byName.strike.data :: Ir.Codec },
	{ name = "announce", codec = arena.byName.announce.data :: Ir.Codec },
	{ name = "fighters", codec = arena.byName.fighters.data :: Ir.Codec },
	{ name = "{ t.int(0, 100) }", codec = Gen.plan({ value = Lync.types.int(0, 100) }) },
}

print("bits: n single rows / one column block (mean of " .. DRAWS .. " draws)")
local totalRows: { [Pattern]: { number } } = {}
local totalBlocks: { [Pattern]: { number } } = {}
for _, pattern in PATTERNS do
	totalRows[pattern] = table.create(MAX_N, 0)
	totalBlocks[pattern] = table.create(MAX_N, 0)
end

for _, entry in codecs do
	print(`\n{entry.name}`)
	for _, pattern in PATTERNS do
		local cells = {}
		for n = 1, MAX_N do
			local rowBits, blockBits = bitsOf(entry.codec, n, pattern)
			totalRows[pattern][n] += rowBits
			totalBlocks[pattern][n] += blockBits
			table.insert(cells, string.format("%7.1f/%-7.1f", rowBits, blockBits))
		end
		print(string.format("  %-9s %s", pattern, table.concat(cells, " ")))
	end
end

print("\nsum of the four codecs")
local minRows = nil
for n = 1, MAX_N do
	local wins = 0
	local cells = {}
	for _, pattern in PATTERNS do
		local rowBits, blockBits = totalRows[pattern][n], totalBlocks[pattern][n]
		if blockBits <= rowBits then
			wins += 1
		end
		table.insert(cells, string.format("%s %.1f/%.1f", pattern, rowBits, blockBits))
	end
	print(
		string.format(
			"  n = %d: %s; block no larger in %d of 4",
			n,
			table.concat(cells, ", "),
			wins
		)
	)
	if minRows == nil and wins >= 3 then
		minRows = n
	end
end

print(`\ncolumnMinRows = {minRows}`)
