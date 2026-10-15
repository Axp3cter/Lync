--!strict

--[=[
	Ints

	Integer codes (v5.md §4.1): bit lengths, field widths, zigzag, and Exp-Golomb of order k.

	Every coded value is an integer in [0, Ints.MAX], so all arithmetic here is exact in doubles.
	EG-0 of x is z zero bits, a one bit, then u(z) of (x + 1) - 2^z, where z is the bit length of
	x + 1 less one; EG-k of u is EG-0 of floor(u / 2^k) followed by u(k) of u mod 2^k.

	Decoding uses a 12-bit lookup table for EG-0 codes of up to 12 bits (z up to 5) and counts
	zero bits otherwise.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("./bits")

-- Module ------------------------------------------------------------------------------------------

local Ints = {}

-- Constants ---------------------------------------------------------------------------------------

const MAX = 2 ^ 53 - 1
const MAX_ZEROS = 53

--- The widest field `Bits.write` takes.
const MAX_FIELD_BITS = 53

const LOOKUP_BITS = 12
const LOOKUP_SIZE = 4096

--- The longest EG-0 code the lookup table decodes (z = 5).
const MAX_LOOKUP_CODE_BITS = 11

--- How many zero bits the slow path tests per read.
const SCAN_BITS = 24

--- The value of the EG-0 code at the start of each 12-bit window, for codes that fit in it.
const LOOKUP_VALUE: { number } = table.create(LOOKUP_SIZE, 0)

--- The length of the EG-0 code at the start of each 12-bit window, or 0 when it does not fit.
const LOOKUP_LENGTH: { number } = table.create(LOOKUP_SIZE, 0)

--- 2^i at index i + 1, for i from 0 to 54.
const POWER_OF_TWO: { number } = table.create(55, 0)

for i = 0, 54 do
	POWER_OF_TWO[i + 1] = 2 ^ i
end

for window = 0, LOOKUP_SIZE - 1 do
	local zeroCount = bit32.countrz(window)
	local length = 2 * zeroCount + 1
	if length > LOOKUP_BITS then
		continue
	end

	local rest = if zeroCount > 0 then bit32.extract(window, zeroCount + 1, zeroCount) else 0
	LOOKUP_VALUE[window + 1] = 2 ^ zeroCount - 1 + rest
	LOOKUP_LENGTH[window + 1] = length
end

-- Private -----------------------------------------------------------------------------------------

local function bitLength(x: number): number
	if x < 0x1_0000_0000 then
		return 32 - bit32.countlz(x)
	end

	return 64 - bit32.countlz(x // 0x1_0000_0000)
end

local function readEgSlowly(r: Bits.Reader): (number?, number)
	local zeroCount = 0
	while true do
		local start = r.bit
		local scanBits = math.min(SCAN_BITS, r.stop * 8 - start)
		if scanBits == 0 then
			return nil, 4
		end

		-- Cast: scanBits never passes the tail cursor, so the read cannot fail.
		local scanned = Bits.read(r, scanBits) :: number
		if scanned ~= 0 then
			local leadingZeros = bit32.countrz(scanned)
			zeroCount += leadingZeros
			r.bit = start + leadingZeros + 1
			break
		end

		zeroCount += scanBits
		if zeroCount > MAX_ZEROS then
			return nil, 2
		end
	end

	if zeroCount > MAX_ZEROS then
		return nil, 2
	end

	local rest = Bits.read(r, zeroCount)
	if rest == nil then
		return nil, 4
	end

	local value = 2 ^ zeroCount - 1 + rest
	if value > MAX then
		return nil, 2
	end

	return value, 0
end

-- Public ------------------------------------------------------------------------------------------

--- The largest coded value, 2^53 - 1.
Ints.MAX = MAX

--[=[
	Returns the number of bits in a value's binary form.

	@param  x an integer in [0, 2^53]
	@return the position of the highest set bit plus one, 0 for 0
]=]
function Ints.bitLength(x: number): number
	return bitLength(x)
end

--[=[
	Returns the length of an EG-k code.

	@param  value the coded value, in [0, Ints.MAX]
	@param  k     the order, 0 to 15
	@return the code's length in bits
]=]
function Ints.egBits(value: number, k: number): number
	return 2 * bitLength(value // POWER_OF_TWO[k + 1] + 1) - 1 + k
end

--[=[
	Reads an EG-k code.

	@param  r the reader, advanced past the code
	@param  k the order, 0 to 15
	@return the value, or nil on refusal
	@return 0, or the refusal's rule: 4 when bits run out, 2 when z > 53 or the value passes
	        Ints.MAX (v5.md §4.8)
]=]
function Ints.readEg(r: Bits.Reader, k: number): (number?, number)
	local bit = r.bit
	local byte = bit // 8
	local buf = r.buf
	local window = 0
	local length = 0
	if r.stop * 8 - bit >= LOOKUP_BITS and byte + 4 <= buffer.len(buf) then
		window = bit32.extract(buffer.readu32(buf, byte), bit % 8, LOOKUP_BITS)
		length = LOOKUP_LENGTH[window + 1]
	end

	local quotient: number
	if length > 0 then
		r.bit = bit + length
		quotient = LOOKUP_VALUE[window + 1]
	else
		local scanned, rule = readEgSlowly(r)
		if scanned == nil then
			return nil, rule
		end
		quotient = scanned
	end

	if k == 0 then
		return quotient, 0
	end

	local remainder = Bits.read(r, k)
	if remainder == nil then
		return nil, 4
	end

	local value = quotient * POWER_OF_TWO[k + 1] + remainder
	if value > MAX then
		return nil, 2
	end

	return value, 0
end

--[=[
	Reads `count` EG-k codes into `out`, refusing any above `maxCode`.

	The cursor stays in a local and the lookup and the k-bit remainder are read in place while
	the reader's buffer holds a u32 at both and the code must end before the tail cursor; each
	other code goes through `Ints.readEg`.

	@param  r       the reader, advanced past the codes read
	@param  k       the order, 0 to 15
	@param  count   how many codes
	@param  out     where the values are stored
	@param  first   the index in `out` of the first value
	@param  maxCode the largest value accepted
	@return 0, or the refusal's rule: 4 when bits run out, 2 when a value passes `maxCode` or as
	        `Ints.readEg` refuses
]=]
function Ints.readEgMany(
	r: Bits.Reader,
	k: number,
	count: number,
	out: { number },
	first: number,
	maxCode: number
): number
	local buf = r.buf
	local scale = POWER_OF_TWO[k + 1]
	-- The remainder's u32 starts at most MAX_LOOKUP_CODE_BITS after the code's.
	local lastFastBit = math.min(
		r.stop * 8 - MAX_LOOKUP_CODE_BITS - k,
		(buffer.len(buf) - 4) * 8 - MAX_LOOKUP_CODE_BITS
	)
	local bit = r.bit
	for i = first, first + count - 1 do
		local length = 0
		local window = 0
		if bit <= lastFastBit then
			window = bit32.extract(buffer.readu32(buf, bit // 8), bit % 8, LOOKUP_BITS)
			length = LOOKUP_LENGTH[window + 1]
		end

		local value: number
		if length > 0 then
			bit += length
			value = LOOKUP_VALUE[window + 1]
			if k > 0 then
				value = value * scale + bit32.extract(buffer.readu32(buf, bit // 8), bit % 8, k)
				bit += k
			end
		else
			r.bit = bit
			local slowValue, rule = Ints.readEg(r, k)
			if slowValue == nil then
				return rule
			end
			value = slowValue
			bit = r.bit
		end

		if value > maxCode then
			r.bit = bit
			return 2
		end

		out[i] = value
	end

	r.bit = bit
	return 0
end

--[=[
	Returns the unsigned integer that zigzag maps to a value.

	@param  z an integer in [0, Ints.MAX]
	@return z / 2 for even z, -(z + 1) / 2 for odd z
]=]
function Ints.unzigzag(z: number): number
	if z % 2 == 0 then
		return z / 2
	end

	return -(z + 1) / 2
end

--[=[
	Returns the width of a field that holds one of `n` values.

	@param  n the number of values, at least 1
	@return ceil(log2 n), 0 when n is 1
]=]
function Ints.width(n: number): number
	return bitLength(n - 1)
end

--[=[
	Writes an EG-k code.

	@param w     the writer
	@param value the value, in [0, Ints.MAX]
	@param k     the order, 0 to 15
]=]
function Ints.writeEg(w: Bits.Writer, value: number, k: number)
	local scale = POWER_OF_TWO[k + 1]
	local quotient = value // scale
	local remainder = value - quotient * scale
	local x = quotient + 1
	local zeroCount = bitLength(x) - 1
	local leading = POWER_OF_TWO[zeroCount + 1]
	local codeBits = 2 * zeroCount + 1 + k
	if codeBits <= MAX_FIELD_BITS then
		local prefix = leading + (x - leading) * 2 * leading
		Bits.write(w, codeBits, prefix + remainder * POWER_OF_TWO[2 * zeroCount + 2])
		return
	end

	Bits.write(w, zeroCount, 0)
	Bits.write(w, 1, 1)
	Bits.write(w, zeroCount, x - leading)
	Bits.write(w, k, remainder)
end

--[=[
	Returns the zigzag code of a signed value.

	@param  v an integer in [-2^52, 2^52 - 1]
	@return 2v for v >= 0, -2v - 1 for v < 0
]=]
function Ints.zigzag(v: number): number
	if v >= 0 then
		return 2 * v
	end

	return -2 * v - 1
end

return table.freeze(Ints)
