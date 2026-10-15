--!strict

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Ints = require("../../src/wire/ints")
local Prop = require("../support/prop")

type Case = { codes: { number }, first: number, count: number, lo: number, n: number }

-- An independent reference for the column cost, written from v5.md §4.3 directly.
local function slowBitLength(v: number): number
	local length = 0
	while v >= 1 do
		v = math.floor(v / 2)
		length += 1
	end

	return length
end

local function slowEgBits(u: number, k: number): number
	return 2 * slowBitLength(math.floor(u / 2 ^ k) + 1) - 1 + k
end

local function slowZigzags(case: Case): { number }
	local floorHalf = math.floor(case.n / 2)
	local zigzags = {}
	local previous = 0
	for i = case.first, case.first + case.count - 1 do
		local code = case.codes[i]
		-- math.fmod is exact, so the reference stays exact for n up to 2^53.
		local residual = math.fmod(code - previous, case.n)
		if residual > case.n - floorHalf - 1 then
			residual -= case.n
		elseif residual < -floorHalf then
			residual += case.n
		end
		table.insert(zigzags, if residual >= 0 then 2 * residual else -2 * residual - 1)
		previous = code
	end

	return zigzags
end

local function slowChoice(case: Case): (number, number, number)
	local zigzags = slowZigzags(case)
	local best = { mode = 0, k = 0, bits = math.huge }
	local function consider(mode: number, k: number, bits: number)
		if bits < best.bits then
			best = { mode = mode, k = k, bits = bits }
		end
	end

	local minimum, maximum = math.huge, 0
	for _, z in zigzags do
		minimum = math.min(minimum, z)
		maximum = math.max(maximum, z)
	end
	if maximum == 0 then
		consider(0, 0, 2)
	end
	for k = 0, 15 do
		local bits = 6
		for _, z in zigzags do
			bits += slowEgBits(z, k)
		end
		consider(1, k, bits)
	end
	for k = 0, 15 do
		local bits, nonzeroCount, lastRow = 6, 0, 0
		for i, z in zigzags do
			if z ~= 0 then
				nonzeroCount += 1
				bits += slowEgBits(i - 1 - lastRow, 0) + slowEgBits(z - 1, k)
				lastRow = i
			end
		end
		consider(2, k, bits + slowEgBits(nonzeroCount, 0))
	end
	consider(3, 0, 2 + slowEgBits(minimum, 0) + 6 + #zigzags * slowBitLength(maximum - minimum))

	return best.mode, best.k, best.bits
end

local function randomBelow(n: number): number
	local fraction = (math.random(0, 2 ^ 26 - 1) * 2 ^ 27 + math.random(0, 2 ^ 27 - 1)) / 2 ^ 53
	return math.min(n - 1, math.floor(fraction * n))
end

local function intervalOf(): (number, number)
	local kind = math.random(1, 5)
	if kind == 1 then
		return 0, 1
	elseif kind == 2 then
		return 0, 2
	elseif kind == 3 then
		return 0, 2 ^ math.random(2, 52)
	elseif kind == 4 then
		return 0, 2 ^ math.random(1, 52) + 1
	end

	return -(2 ^ 52), 2 ^ 53
end

local function caseOf(size: number): Case
	local lo, n = intervalOf()
	local count = math.random(0, math.min(40, size))
	local first = math.random(1, 3)
	local pattern = math.random(1, 4)
	local spread = 2 ^ math.random(0, 12)
	local codes = {}
	for i = 1, first - 1 do
		codes[i] = lo
	end

	local code = lo + randomBelow(n)
	for i = first, first + count - 1 do
		if pattern == 2 then
			code = lo + (code - lo + math.random(-1, 1)) % n
		elseif pattern == 3 then
			code = lo + (code - lo + math.floor((math.random() - 0.5) * spread)) % n
		elseif pattern == 4 and math.random() < 0.1 then
			code = lo + randomBelow(n)
		elseif pattern == 1 and math.random() < 0.5 then
			code = lo + randomBelow(n)
		end
		codes[i] = code
	end

	return { codes = codes, first = first, count = count, lo = lo, n = n }
end

local function wideCaseOf(size: number): Case
	local kind = math.random(1, 6)
	local lo, n = 0, 2 ^ 53
	if kind == 2 then
		lo = -(2 ^ 52)
	elseif kind == 3 then
		n = 2 ^ 53 - 1
	elseif kind == 4 then
		n = 2 ^ 53 - math.random(1, 2 ^ 20)
	elseif kind == 5 then
		n = 2 ^ 52 + 1
	elseif kind == 6 then
		n = 2 ^ 52 + math.random(1, 2 ^ 30) * 2 ^ 21
	end

	local half = n // 2
	local edges = { lo, lo + 1, lo + n - 1, lo + n - 2, lo + half, lo + half - 1, lo + half + 1 }
	local codes = {}
	for i = 1, math.random(1, math.min(40, size)) do
		codes[i] = if math.random() < 0.7
			then edges[math.random(1, #edges)]
			else lo + randomBelow(n)
	end

	return { codes = codes, first = 1, count = #codes, lo = lo, n = n }
end

local function encodedOf(case: Case): Bits.Writer
	local w = Bits.writer()
	Column.write(w, case.codes, case.first, case.count, case.lo, case.n)

	return w
end

local function bitsOf(digits: string): buffer
	local w = Bits.writer()
	for i = 1, #digits do
		Bits.write(w, 1, if string.sub(digits, i, i) == "1" then 1 else 0)
	end

	return Bits.finish(w)
end

local function readRule(bytes: buffer, count: number, lo: number, n: number): number
	return Column.read(Bits.reader(bytes), {}, 1, count, lo, n)
end

return {
	["codes intervals near and at 2^53 exactly"] = function()
		Prop.check("wide column", wideCaseOf, function(case: Case)
			local w = encodedOf(case)
			local chosen = { Column.choose(case.codes, case.first, case.count, case.lo, case.n) }
			Check.expectEqual(chosen, { slowChoice(case) }, "choice against the exact reference")
			Check.expectEqual(w.bit, chosen[3], "bits written against chosen")

			local out = {}
			local r = Bits.reader(Bits.finish(w))
			Check.expectEqual(Column.read(r, out, 1, case.count, case.lo, case.n), 0)
			Check.expectEqual(out, case.codes)
		end, { runs = 1000 })

		local n = 2 ^ 53 - 1
		local codes = { n - 1, 0, n - 1, n // 2, n // 2 + 1, 0 }
		local w = Bits.writer()
		Column.write(w, codes, 1, #codes, 0, n)
		local out = {}
		Check.expectEqual(Column.read(Bits.reader(Bits.finish(w)), out, 1, #codes, 0, n), 0)
		Check.expectEqual(out, codes)
	end,

	["round-trips every interval kind at counts 0 to 40"] = function()
		Prop.check("column round trip", caseOf, function(case: Case)
			local w = encodedOf(case)
			local _, _, bits = Column.choose(case.codes, case.first, case.count, case.lo, case.n)
			Check.expectEqual(w.bit, bits, "bits written against chosen")

			local r = Bits.reader(Bits.finish(w))
			local out = {}
			Check.expectEqual(Column.read(r, out, case.first, case.count, case.lo, case.n), 0)
			Check.expectEqual(r.bit, w.bit, "bits read")
			for i = case.first, case.first + case.count - 1 do
				Check.expectEqual(out[i], case.codes[i], `row {i}`)
			end
		end, { runs = 1000 })
	end,

	["chooses the fewest bits, ties to the lower mode, then the lower k"] = function()
		Prop.check("column choice", caseOf, function(case: Case)
			if case.count == 0 then
				return
			end

			local chosen = { Column.choose(case.codes, case.first, case.count, case.lo, case.n) }
			Check.expectEqual(chosen, { slowChoice(case) })
		end, { runs = 1000 })
	end,

	["reproduces G8's columns (v5 §4.10)"] = function()
		local aim = { 1024, 1024, 1024, 1024 }
		Check.expectEqual({ Column.choose(aim, 1, 4, 0, 2048) }, { 2, 11, 22 })
		local target = { 4, 5, 6, 6 }
		Check.expectEqual({ Column.choose(target, 1, 4, 0, 2 ^ 40) }, { 1, 0, 20 })

		local w = Bits.writer()
		Column.write(w, aim, 1, 4, 0, 2048)
		Column.write(w, aim, 1, 4, 0, 2048)
		Column.write(w, target, 1, 4, 0, 2 ^ 40)
		Check.expectEqual(w.bit, 64)
	end,

	["writes and reads nothing for no rows"] = function()
		local w = Bits.writer()
		Column.write(w, {}, 1, 0, 0, 2)
		Check.expectEqual(w.bit, 0)
		Check.expectEqual({ Column.choose({}, 1, 0, 0, 2) }, { 0, 0, 0 })
		Check.expectEqual(readRule(buffer.create(0), 0, 0, 2), 0)
	end,

	["codes a bool's residual as its XOR with the previous row"] = function()
		local w = Bits.writer()
		Column.write(w, { 1, 1, 0, 0, 1 }, 1, 5, 0, 2)
		local r = Bits.reader(Bits.finish(w))
		Check.expectEqual(Bits.read(r, 2), 3, "frame of reference")
		Check.expectEqual({ Ints.readEg(r, 0) }, { 0, 0 }, "base")
		Check.expectEqual(Bits.read(r, 6), 1, "width")
		local residuals = {}
		for i = 1, 5 do
			residuals[i] = Bits.read(r, 1)
		end
		Check.expectEqual(residuals, { 1, 0, 1, 0, 1 })
	end,

	["refuses a residual past the interval"] = function()
		-- Mode 1, k 0, one row: EG-0 of 2 in a bool column.
		Check.expectEqual(readRule(bitsOf("10" .. "0000" .. "011"), 1, 0, 2), 2)
		-- Mode 3, base 0, width 2, one row of 2.
		Check.expectEqual(readRule(bitsOf("11" .. "1" .. "010000" .. "01"), 1, 0, 2), 2)
		-- Mode 2, k 0, one non-zero row of zigzag 2.
		Check.expectEqual(readRule(bitsOf("01" .. "0000" .. "010" .. "1" .. "010"), 1, 0, 2), 2)
		-- Mode 1 in a one-code interval.
		Check.expectEqual(readRule(bitsOf("10" .. "0000" .. "010"), 1, 0, 1), 2)
	end,

	["refuses sparse counts and gaps past the rows"] = function()
		-- m = 2 non-zero rows in a one-row column.
		Check.expectEqual(readRule(bitsOf("01" .. "0000" .. "011"), 1, 0, 4), 2)
		-- One non-zero row after a gap of 1 in a one-row column.
		Check.expectEqual(readRule(bitsOf("01" .. "0000" .. "010" .. "010" .. "1"), 1, 0, 4), 2)
	end,

	["refuses a frame-of-reference width above 53"] = function()
		Check.expectEqual(readRule(bitsOf("11" .. "1" .. "011011"), 1, -(2 ^ 52), 2 ^ 53), 2)
	end,

	["refuses columns cut short"] = function()
		local columns = {
			{ 3, 900, 2, 70_000, 5, 5, 5, 1 },
			{ 7, 7, 7, 7, 9000, 9000, 9000, 9000 },
			{ 0, 2 ^ 19, 0, 2 ^ 19, 0, 2 ^ 19, 0, 2 ^ 19 },
		}
		for _, codes in columns do
			local case = { codes = codes, first = 1, count = #codes, lo = 0, n = 2 ^ 20 }
			local mode = Column.choose(codes, 1, #codes, 0, 2 ^ 20)
			local whole = Bits.finish(encodedOf(case))
			for stopByte = 0, buffer.len(whole) - 1 do
				local r = Bits.reader(whole, 0, stopByte)
				local rule = Column.read(r, {}, 1, #codes, 0, 2 ^ 20)
				Check.expectEqual(rule, 4, `mode {mode} cut at byte {stopByte}`)
			end
		end
	end,

	["sets MIN_ROWS"] = function()
		Check.expectEqual(Column.MIN_ROWS, 3)
	end,
}
