--!strict

--[=[
	column.bench

	Measures the column coder (v5.md §4.3), EG-0 decoding and HalfSipHash on the Luau CLI, which
	has no Roblox types. Run from the repo root, once interpreted and once native, appending to the
	results file of the current commit:

	luau -O2 bench/column.bench.luau -a interpreted >> bench/results/<short sha>.json
	luau -O2 --codegen bench/column.bench.luau -a native >> bench/results/<short sha>.json

	Each result is one JSON line. Column encodes run the reference encoder's full search over every
	mode and k ("full") and, for comparison, a plain EG-0 encode of the same residuals ("k0"); the
	"searchRatio" line divides the first by the second. Columns are 64 rows of codes in [0, 2^16),
	in four patterns: constant, ±1 noise, Gaussian noise of σ 50, and 10% sparse changes. The data
	comes from a fixed xorshift32 seed, so runs compare.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../src/wire/bits")
local Column = require("../src/wire/column")
local HalfSipHash = require("../src/wire/halfsiphash")
local Ints = require("../src/wire/ints")

-- Types -------------------------------------------------------------------------------------------

type Pattern = {
	name: string,
	codes: { number },
}

-- Constants ---------------------------------------------------------------------------------------

const ROWS = 64
const INTERVAL = 0x1_0000
const BASE_CODE = 0x8000
const COLUMNS_PER_ROUND = 300
const ROUNDS = 25
const EG_VALUES = 1024
const EG_ROUNDS = 80
const HASH_ROUNDS = 4000

-- State -------------------------------------------------------------------------------------------

local seed = 12345

-- Private -----------------------------------------------------------------------------------------

local function nextRandom(): number
	seed = bit32.bxor(seed, bit32.lshift(seed, 13))
	seed = bit32.bxor(seed, bit32.rshift(seed, 17))
	seed = bit32.bxor(seed, bit32.lshift(seed, 5))

	return seed / 0x1_0000_0000
end

local function nextGaussian(): number
	local radius = math.sqrt(-2 * math.log(1 - nextRandom()))
	return radius * math.cos(2 * math.pi * nextRandom())
end

local function patternsOf(): { Pattern }
	local constant = table.create(ROWS, BASE_CODE)
	local noise = table.create(ROWS, 0)
	local gaussian = table.create(ROWS, 0)
	local sparse = table.create(ROWS, 0)
	local sparseCode = BASE_CODE
	for i = 1, ROWS do
		noise[i] = BASE_CODE + math.floor(nextRandom() * 3) - 1
		gaussian[i] = BASE_CODE + math.round(nextGaussian() * 50)
		if nextRandom() < 0.1 then
			sparseCode = math.floor(nextRandom() * INTERVAL)
		end
		sparse[i] = sparseCode
	end

	return {
		{ name = "constant", codes = constant },
		{ name = "noise1", codes = noise },
		{ name = "gaussian50", codes = gaussian },
		{ name = "sparse10", codes = sparse },
	}
end

-- The baseline for the k search: the residuals of `Column.write`, each written as EG-0.
local function writeEgZero(w: Bits.Writer, codes: { number })
	local half = INTERVAL // 2
	Bits.write(w, 2, 1)
	Bits.write(w, 4, 0)

	local previous = 0
	for i = 1, ROWS do
		local code = codes[i]
		local residual = code - previous
		if residual >= half then
			residual -= INTERVAL
		elseif residual < -half then
			residual += INTERVAL
		end

		Ints.writeEg(w, if residual >= 0 then 2 * residual else -2 * residual - 1, 0)
		previous = code
	end
end

-- Interleaves the actions round by round, so that drift in machine speed affects them alike, and
-- returns each one's fastest round.
local function bestSecondsOf(repeats: number, actions: { () -> () }): { number }
	local best = table.create(#actions, math.huge)
	for _ = 1, ROUNDS do
		for i, action in actions do
			local startedAt = os.clock()
			for _ = 1, repeats do
				action()
			end
			best[i] = math.min(best[i], os.clock() - startedAt)
		end
	end

	return best
end

local function report(label: string, fields: string, nanoseconds: number)
	print(string.format('{"label":"%s",%s,"ns":%.1f}', label, fields, nanoseconds))
end

local function benchColumns(label: string)
	local w = Bits.writer()
	for _, pattern in patternsOf() do
		local codes = pattern.codes
		w.bit = 0
		Column.write(w, codes, 1, ROWS, 0, INTERVAL)
		local encoded = Bits.finish(w)
		local mode, k, bits = Column.choose(codes, 1, ROWS, 0, INTERVAL)
		local out = table.create(ROWS, 0)

		local seconds = bestSecondsOf(COLUMNS_PER_ROUND, {
			function()
				w.bit = 0
				Column.write(w, codes, 1, ROWS, 0, INTERVAL)
			end,
			function()
				w.bit = 0
				writeEgZero(w, codes)
			end,
			function()
				Column.read(Bits.reader(encoded), out, 1, ROWS, 0, INTERVAL)
			end,
		})
		local fullSeconds = seconds[1]
		local zeroSeconds = seconds[2]
		local decodeSeconds = seconds[3]

		local perValue = 1e9 / (COLUMNS_PER_ROUND * ROWS)
		local subject = string.format(
			'"bench":"column","pattern":"%s","rows":%d,"mode":%d,"k":%d,"bits":%d',
			pattern.name,
			ROWS,
			mode,
			k,
			bits
		)
		report(
			label,
			`{subject},"op":"encode","search":"full","unit":"ns/value"`,
			fullSeconds * perValue
		)
		report(
			label,
			`{subject},"op":"encode","search":"k0","unit":"ns/value"`,
			zeroSeconds * perValue
		)
		report(label, `{subject},"op":"decode","unit":"ns/value"`, decodeSeconds * perValue)
		print(
			string.format(
				'{"label":"%s",%s,"op":"searchRatio","ratio":%.2f}',
				label,
				subject,
				fullSeconds / zeroSeconds
			)
		)
	end
end

local function benchEgZeroDecode(label: string)
	local w = Bits.writer()
	for _ = 1, EG_VALUES do
		local value = if nextRandom() < 0.45
			then 0
			else 1 + math.floor(-math.log(1 - nextRandom()) * 1.6)
		Ints.writeEg(w, value, 0)
	end
	local encoded = Bits.finish(w)

	local seconds = bestSecondsOf(EG_ROUNDS, {
		function()
			local r = Bits.reader(encoded)
			for _ = 1, EG_VALUES do
				Ints.readEg(r, 0)
			end
		end,
	})
	report(
		label,
		'"bench":"ints","op":"readEg0","values":"small","unit":"ns/value"',
		seconds[1] * 1e9 / (EG_ROUNDS * EG_VALUES)
	)
end

local function benchHalfSipHash(label: string)
	local key = buffer.create(8)
	for _, length in { 64, 1024 } do
		local message = buffer.create(length)
		for i = 0, length - 1 do
			buffer.writeu8(message, i, i % 256)
		end

		local seconds = bestSecondsOf(HASH_ROUNDS, {
			function()
				HalfSipHash.hash(key, message, 0, length, 1, 3, 4)
			end,
		})
		local fields =
			`"bench":"halfsiphash","rounds":"1-3","outBytes":4,"bytes":{length},"unit":"ns/hash"`
		report(label, fields, seconds[1] * 1e9 / HASH_ROUNDS)
	end
end

-- Main --------------------------------------------------------------------------------------------

local label = ... or "unlabelled"

benchColumns(label)
benchEgZeroDecode(label)
benchHalfSipHash(label)
