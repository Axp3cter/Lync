--!strict

--[=[
	Column

	The column coder for integer columns (v5.md §4.3): each code's residual against the previous
	row (the first row against 0), wrapped into the column's interval and zigzagged, then coded in
	the cheapest of four modes.

	A column's codes are the integers [lo, lo + n - 1]. A residual is wrapped modulo n into
	[-floor(n / 2), ceil(n / 2) - 1], so every zigzagged residual is in [0, n - 1]; a decoded one
	past n - 1 is refused (rule 2), which keeps each column's encoding unique for its mode and k.
	Residuals are exact for every n up to 2^53. The first row's residual against 0 is wrapped in one
	step, which needs lo between -n - floor(n / 2) and ceil(n / 2): this holds for lo = 0, and for
	lo = -2^52 with n = 2^53.

	The modes, after `mode:u2`: 0, every residual is 0; 1, `k:u4` then each residual as EG-k;
	2, `k:u4 m:EG0` then m pairs `gap:EG0 value:EG-k` (rows skipped since the previous non-zero
	row, then the residual less one); 3, `base:EG0 width:u6` then each residual less base as
	u(width). The encoder picks the fewest bits, ties to the lower mode, then the lower k; it
	costs all sixteen k of modes 1 and 2 exactly, from counts of the values' bit lengths.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("./bits")
local Ints = require("./ints")

-- Module ------------------------------------------------------------------------------------------

local Column = {}

-- Constants ---------------------------------------------------------------------------------------

const MODE_ZERO = 0
const MODE_EXP_GOLOMB = 1
const MODE_SPARSE = 2
const MODE_REFERENCE = 3

const MODE_BITS = 2
const K_BITS = 4
const WIDTH_BITS = 6

const K_COUNT = 16
const MAX_WIDTH = 53

-- State -------------------------------------------------------------------------------------------

--- The zigzagged residuals of the column being coded.
local residuals: { number } = {}

--- How many residuals have each bit length, at index length + 1.
local lengthCounts: { number } = table.create(MAX_WIDTH + 1, 0)

--- How many non-zero residuals less one have each bit length, at index length + 1.
local sparseLengthCounts: { number } = table.create(MAX_WIDTH + 1, 0)

--[=[
	At index k + 1, the change at k in how many residuals have an all-ones quotient floor(u / 2^k),
	whose EG-k code is two bits longer than its bit length alone gives.
]=]
local onesChanges: { number } = table.create(K_COUNT, 0)

--- The same changes for the non-zero residuals less one.
local sparseOnesChanges: { number } = table.create(K_COUNT, 0)

--- The EG-k cost of every residual, at index k + 1.
local egCosts: { number } = table.create(K_COUNT, 0)

--- The EG-k cost of every non-zero residual less one, at index k + 1.
local sparseEgCosts: { number } = table.create(K_COUNT, 0)

-- Private -----------------------------------------------------------------------------------------

-- Every difference and every wrap below stays within 2^53 in magnitude, so all of it is exact for
-- every n up to 2^53.
local function fillResiduals(codes: { number }, first: number, count: number, n: number)
	local half = n // 2
	local low = -half
	local high = n - half - 1

	local previous = 0
	for i = 1, count do
		local code = codes[first + i - 1]
		local residual = code - previous
		if residual > high then
			residual -= n
		elseif residual < low then
			residual += n
		end

		residuals[i] = if residual >= 0 then 2 * residual else -2 * residual - 1
		previous = code
	end
end

-- Ints.bitLength, repeated so that it inlines into the per-value costing loop.
local function bitLength(x: number): number
	if x < 0x1_0000_0000 then
		return 32 - bit32.countlz(x)
	end

	return 64 - bit32.countlz(x // 0x1_0000_0000)
end

-- EG-k of u costs 1 + k bits when k >= L (L the bit length of u), else 2L - k - 1 bits, plus 2 when
-- floor(u / 2^k) is all ones, which holds for k >= G, G the bit length of 2^L - 1 - u.
local function tally(value: number, counts: { number }, changes: { number }): number
	local length = bitLength(value)
	counts[length + 1] += 1

	local complement = if length <= 32
		then bit32.bxor(value, bit32.rshift(0xFFFF_FFFF, 32 - length))
		else 2 ^ length - 1 - value
	local complementLength = bitLength(complement)
	if complementLength < length and complementLength < K_COUNT then
		changes[complementLength + 1] += 1
		if length < K_COUNT then
			changes[length + 1] -= 1
		end
	end

	return length
end

-- Sets costs[k + 1] to the EG-k bits of the tallied values and clears the tallies.
local function sumEgCosts(
	counts: { number },
	changes: { number },
	maxLength: number,
	valueCount: number,
	costs: { number }
)
	local onesCount = 0
	for k = 0, K_COUNT - 1 do
		onesCount += changes[k + 1]
		changes[k + 1] = 0
		costs[k + 1] = valueCount * (k + 1) + 2 * onesCount
	end

	local longerCount = 0
	local longerLengthSum = 0
	for length = maxLength, 1, -1 do
		local lengthCount = counts[length + 1]
		counts[length + 1] = 0
		longerCount += lengthCount
		longerLengthSum += lengthCount * length

		local k = length - 2
		if k >= 0 and k < K_COUNT then
			costs[k + 1] += 2 * (longerLengthSum - (k + 1) * longerCount)
		end
	end
	counts[1] = 0
end

local function chooseMode(count: number): (number, number, number, number, number, number)
	local minimum = math.huge
	local maximum = 0
	local maxLength = 0
	local sparseMaxLength = 0
	local nonzeroCount = 0
	local gapBits = 0
	local lastRow = 0
	for i = 1, count do
		local z = residuals[i]
		minimum = math.min(minimum, z)
		maximum = math.max(maximum, z)
		maxLength = math.max(maxLength, tally(z, lengthCounts, onesChanges))
		if z == 0 then
			continue
		end

		nonzeroCount += 1
		gapBits += 2 * bitLength(i - lastRow) - 1
		lastRow = i
		local sparseLength = tally(z - 1, sparseLengthCounts, sparseOnesChanges)
		sparseMaxLength = math.max(sparseMaxLength, sparseLength)
	end

	if maximum == 0 then
		lengthCounts[1] = 0
		return MODE_ZERO, 0, MODE_BITS, 0, 0, 0
	end

	sumEgCosts(lengthCounts, onesChanges, maxLength, count, egCosts)
	sumEgCosts(sparseLengthCounts, sparseOnesChanges, sparseMaxLength, nonzeroCount, sparseEgCosts)

	local bestMode = MODE_EXP_GOLOMB
	local bestK = 0
	local bestBits = math.huge
	for k = 0, K_COUNT - 1 do
		local candidateBits = MODE_BITS + K_BITS + egCosts[k + 1]
		if candidateBits < bestBits then
			bestK = k
			bestBits = candidateBits
		end
	end

	local sparseHeaderBits = MODE_BITS + K_BITS + Ints.egBits(nonzeroCount, 0) + gapBits
	for k = 0, K_COUNT - 1 do
		local candidateBits = sparseHeaderBits + sparseEgCosts[k + 1]
		if candidateBits < bestBits then
			bestMode = MODE_SPARSE
			bestK = k
			bestBits = candidateBits
		end
	end

	local width = Ints.bitLength(maximum - minimum)
	local referenceBits = MODE_BITS + Ints.egBits(minimum, 0) + WIDTH_BITS + count * width
	if referenceBits < bestBits then
		return MODE_REFERENCE, 0, referenceBits, minimum, width, nonzeroCount
	end

	return bestMode, bestK, bestBits, minimum, width, nonzeroCount
end

local function readExpGolomb(r: Bits.Reader, count: number, maxCode: number): number
	local k = Bits.read(r, K_BITS)
	if k == nil then
		return 4
	end

	for i = 1, count do
		local z, rule = Ints.readEg(r, k)
		if z == nil then
			return rule
		end

		if z > maxCode then
			return 2
		end

		residuals[i] = z
	end

	return 0
end

local function readSparse(r: Bits.Reader, count: number, maxCode: number): number
	local k = Bits.read(r, K_BITS)
	if k == nil then
		return 4
	end

	local nonzeroCount, countRule = Ints.readEg(r, 0)
	if nonzeroCount == nil then
		return countRule
	end

	if nonzeroCount > count then
		return 2
	end

	for i = 1, count do
		residuals[i] = 0
	end

	local row = 0
	for _ = 1, nonzeroCount do
		local gap, gapRule = Ints.readEg(r, 0)
		if gap == nil then
			return gapRule
		end

		row += gap + 1
		if row > count then
			return 2
		end

		local value, valueRule = Ints.readEg(r, k)
		if value == nil then
			return valueRule
		end

		if value + 1 > maxCode then
			return 2
		end

		residuals[row] = value + 1
	end

	return 0
end

local function readReference(r: Bits.Reader, count: number, maxCode: number): number
	local base, baseRule = Ints.readEg(r, 0)
	if base == nil then
		return baseRule
	end

	local width = Bits.read(r, WIDTH_BITS)
	if width == nil then
		return 4
	end

	if width > MAX_WIDTH then
		return 2
	end

	for i = 1, count do
		local offset = Bits.read(r, width)
		if offset == nil then
			return 4
		end

		if base + offset > maxCode then
			return 2
		end

		residuals[i] = base + offset
	end

	return 0
end

local function readResiduals(r: Bits.Reader, count: number, maxCode: number): number
	local mode = Bits.read(r, MODE_BITS)
	if mode == nil then
		return 4
	end

	if mode == MODE_EXP_GOLOMB then
		return readExpGolomb(r, count, maxCode)
	elseif mode == MODE_SPARSE then
		return readSparse(r, count, maxCode)
	elseif mode == MODE_REFERENCE then
		return readReference(r, count, maxCode)
	end

	for i = 1, count do
		residuals[i] = 0
	end

	return 0
end

-- Public ------------------------------------------------------------------------------------------

--- The fewest rows coded as a column block (v5.md §4.9); set by milestone 1's benchmark.
Column.MIN_ROWS = 3

--[=[
	Returns the reference encoder's choice for a column.

	@param  codes the column's codes
	@param  first the index in `codes` of the first row
	@param  count how many rows, at least 0
	@param  _lo   the lowest code of the interval; residuals do not depend on it
	@param  n     the number of codes in the interval, 1 to 2^53
	@return the mode, 0 to 3; 0 for no rows
	@return k, 0 to 15; 0 for modes 0 and 3
	@return the column's length in bits, mode included; 0 for no rows
]=]
function Column.choose(
	codes: { number },
	first: number,
	count: number,
	_lo: number,
	n: number
): (number, number, number)
	if count == 0 then
		return MODE_ZERO, 0, 0
	end

	fillResiduals(codes, first, count, n)
	local mode, k, bits = chooseMode(count)

	return mode, k, bits
end

--[=[
	Reads a column into `out`.

	@param  r     the reader
	@param  out   where the codes are stored
	@param  first the index in `out` of the first row
	@param  count how many rows, at least 0
	@param  lo    the lowest code of the interval
	@param  n     the number of codes in the interval, 1 to 2^53
	@return 0, or the rule that refuses the column: 4 when bits run out, 2 when a count, gap,
	        width or residual passes its maximum (v5.md §4.8)
]=]
function Column.read(
	r: Bits.Reader,
	out: { number },
	first: number,
	count: number,
	lo: number,
	n: number
): number
	if count == 0 then
		return 0
	end

	local rule = readResiduals(r, count, n - 1)
	if rule ~= 0 then
		return rule
	end

	-- Wrapping before adding keeps every sum within the interval, so it is exact up to n = 2^53.
	local top = lo + n - 1
	local previous = 0
	for i = 1, count do
		local z = residuals[i]
		local residual = if z % 2 == 0 then z / 2 else -(z + 1) / 2
		local code
		if residual > top - previous then
			code = previous + (residual - n)
		elseif residual < lo - previous then
			code = previous + (residual + n)
		else
			code = previous + residual
		end

		out[first + i - 1] = code
		previous = code
	end

	return 0
end

--[=[
	Writes a column in the reference encoder's choice, exactly the bits `Column.choose` costs.

	@param w     the writer
	@param codes the column's codes, each in [lo, lo + n - 1]
	@param first the index in `codes` of the first row
	@param count how many rows; 0 writes nothing
	@param _lo   the lowest code of the interval; residuals do not depend on it
	@param n     the number of codes in the interval, 1 to 2^53
]=]
function Column.write(
	w: Bits.Writer,
	codes: { number },
	first: number,
	count: number,
	_lo: number,
	n: number
)
	if count == 0 then
		return
	end

	fillResiduals(codes, first, count, n)
	local mode, k, _, minimum, width, nonzeroCount = chooseMode(count)
	Bits.write(w, MODE_BITS, mode)

	if mode == MODE_EXP_GOLOMB then
		Bits.write(w, K_BITS, k)
		for i = 1, count do
			Ints.writeEg(w, residuals[i], k)
		end
	elseif mode == MODE_SPARSE then
		Bits.write(w, K_BITS, k)
		Ints.writeEg(w, nonzeroCount, 0)
		local lastRow = 0
		for i = 1, count do
			local z = residuals[i]
			if z == 0 then
				continue
			end

			Ints.writeEg(w, i - 1 - lastRow, 0)
			Ints.writeEg(w, z - 1, k)
			lastRow = i
		end
	elseif mode == MODE_REFERENCE then
		Ints.writeEg(w, minimum, 0)
		Bits.write(w, WIDTH_BITS, width)
		for i = 1, count do
			Bits.write(w, width, residuals[i] - minimum)
		end
	end
end

return table.freeze(Column)
