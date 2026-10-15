--!strict
-- Column decode: Column.read (one Ints.readEg call per value, plus a Bits.read call per value for
-- k > 0) against a batched reader that keeps the cursor in a local and inlines the 12-bit lookup
-- and the k-bit remainder. Same bits, same results (checked). Luau CLI:
--   luau -O2 p6_eg_batch.bench.luau ; luau -O2 --codegen p6_eg_batch.bench.luau
local Bits = require("../../../../src/wire/bits")
local Column = require("../../../../src/wire/column")
local Ints = require("../../../../src/wire/ints")

const ROWS = 64
const INTERVAL = 0x1_0000
const ROUNDS = 25
const REPEATS = 300

local LOOKUP_VALUE: { number } = table.create(4096, 0)
local LOOKUP_LENGTH: { number } = table.create(4096, 0)
for window = 0, 4095 do
	local zeroCount = bit32.countrz(window)
	local length = 2 * zeroCount + 1
	if length <= 12 then
		LOOKUP_VALUE[window + 1] = 2 ^ zeroCount - 1 + (if zeroCount > 0 then bit32.extract(window, zeroCount + 1, zeroCount) else 0)
		LOOKUP_LENGTH[window + 1] = length
	end
end

-- Batched EG-k: the lookup inline while 32 bits remain in the buffer, Ints.readEg otherwise.
local function readEgBatch(r: Bits.Reader, k: number, count: number, out: { number }, maxCode: number): number
	local buf = r.buf
	local bit = r.bit
	local safeBit = math.min(r.stop * 8, (buffer.len(buf) - 4) * 8) - 12 - k
	local scale = 2 ^ k
	for i = 1, count do
		if bit <= safeBit then
			local window = bit32.extract(buffer.readu32(buf, bit // 8), bit % 8, 12)
			local length = LOOKUP_LENGTH[window + 1]
			if length > 0 then
				bit += length
				local value = LOOKUP_VALUE[window + 1]
				if k > 0 then
					value = value * scale + bit32.extract(buffer.readu32(buf, bit // 8), bit % 8, k)
					bit += k
				end
				if value > maxCode then
					r.bit = bit
					return 2
				end
				out[i] = value
				continue
			end
		end
		r.bit = bit
		local value, rule = Ints.readEg(r, k)
		if value == nil then
			return rule
		end
		if value > maxCode then
			return 2
		end
		bit = r.bit
		out[i] = value
	end
	r.bit = bit
	return 0
end

local seed = 12345
local function nextRandom(): number
	seed = bit32.bxor(seed, bit32.lshift(seed, 13))
	seed = bit32.bxor(seed, bit32.rshift(seed, 17))
	seed = bit32.bxor(seed, bit32.lshift(seed, 5))
	return seed / 0x1_0000_0000
end

local function residualsOf(codes: { number }): { number }
	local out = table.create(ROWS, 0)
	local previous = 0
	for i = 1, ROWS do
		local residual = codes[i] - previous
		if residual >= INTERVAL // 2 then residual -= INTERVAL elseif residual < -INTERVAL // 2 then residual += INTERVAL end
		out[i] = if residual >= 0 then 2 * residual else -2 * residual - 1
		previous = codes[i]
	end
	return out
end

for _, pattern in { "noise1", "gaussian50" } do
	local codes = table.create(ROWS, 0)
	for i = 1, ROWS do
		if pattern == "noise1" then
			codes[i] = 0x8000 + math.floor(nextRandom() * 3) - 1
		else
			codes[i] = 0x8000 + math.round(math.sqrt(-2 * math.log(1 - nextRandom())) * math.cos(2 * math.pi * nextRandom()) * 50)
		end
	end
	local w = Bits.writer()
	Column.write(w, codes, 1, ROWS, 0, INTERVAL)
	local encoded = Bits.finish(w)
	local _, k = Column.choose(codes, 1, ROWS, 0, INTERVAL)

	-- Both decode the same residuals.
	local expected = residualsOf(codes)
	local check = table.create(ROWS, 0)
	local cr = Bits.reader(encoded)
	Bits.read(cr, 2); Bits.read(cr, 4)
	assert(readEgBatch(cr, k, ROWS, check, INTERVAL - 1) == 0)
	for i = 1, ROWS do assert(check[i] == expected[i], "batched decode differs") end

	local out = table.create(ROWS, 0)
	local best = { math.huge, math.huge }
	for _ = 1, ROUNDS do
		local t0 = os.clock()
		for _ = 1, REPEATS do
			Column.read(Bits.reader(encoded), out, 1, ROWS, 0, INTERVAL)
		end
		best[1] = math.min(best[1], os.clock() - t0)
		t0 = os.clock()
		for _ = 1, REPEATS do
			local r = Bits.reader(encoded)
			Bits.read(r, 2); Bits.read(r, 4)
			readEgBatch(r, k, ROWS, out, INTERVAL - 1)
		end
		best[2] = math.min(best[2], os.clock() - t0)
	end
	local per = 1e9 / (REPEATS * ROWS)
	print(string.format("%-10s k=%d  Column.read %.1f ns/value (whole column decode); batched EG-k residual read %.1f ns/value", pattern, k, best[1] * per, best[2] * per))
end

-- EG-0 alone, as bench/column.bench.luau measures it: one Ints.readEg call per value vs batched.
local w = Bits.writer()
for _ = 1, 1024 do
	Ints.writeEg(w, if nextRandom() < 0.45 then 0 else 1 + math.floor(-math.log(1 - nextRandom()) * 1.6), 0)
end
local encoded = Bits.finish(w)
local out = table.create(1024, 0)
local best = { math.huge, math.huge }
for _ = 1, ROUNDS do
	local t0 = os.clock()
	for _ = 1, 80 do
		local r = Bits.reader(encoded)
		for _ = 1, 1024 do Ints.readEg(r, 0) end
	end
	best[1] = math.min(best[1], os.clock() - t0)
	t0 = os.clock()
	for _ = 1, 80 do
		readEgBatch(Bits.reader(encoded), 0, 1024, out, 2 ^ 53)
	end
	best[2] = math.min(best[2], os.clock() - t0)
end
print(string.format("EG-0 small values: Ints.readEg per value %.1f ns/value; batched %.1f ns/value", best[1] * 1e9 / 81920, best[2] * 1e9 / 81920))
