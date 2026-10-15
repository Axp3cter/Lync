--!strict

--[=[
	HalfSipHash

	HalfSipHash with c compression and d finalization rounds and a 4- or 8-byte output, as in the
	reference `halfsiphash.c` (github.com/veorq/SipHash).

	The schema hash is `hash(zeroKey, bytes, 0, len, 2, 4, 8)` (v5.md §4.6); the upstream tag is
	`hash(key, scratch, 0, len, 1, 3, 4)` (§4.5). The two initialisation constants default to the
	reference's and are parameters so that a build seed can replace them (v5-integrity.md §2).
]=]

-- Module ------------------------------------------------------------------------------------------

local HalfSipHash = {}

-- Constants ---------------------------------------------------------------------------------------

const IV0 = 0x6c796765
const IV1 = 0x74656462

-- Private -----------------------------------------------------------------------------------------

-- Sums are left unwrapped: every bit32 call reduces its arguments modulo 2^32, and no sum
-- reaches 2^34.
local function sipRound(
	v0: number,
	v1: number,
	v2: number,
	v3: number
): (number, number, number, number)
	v0 += v1
	v1 = bit32.bxor(bit32.lrotate(v1, 5), v0)
	v0 = bit32.lrotate(v0, 16)
	v2 += v3
	v3 = bit32.bxor(bit32.lrotate(v3, 8), v2)
	v0 += v3
	v3 = bit32.bxor(bit32.lrotate(v3, 7), v0)
	v2 += v1
	v1 = bit32.bxor(bit32.lrotate(v1, 13), v2)
	v2 = bit32.lrotate(v2, 16)

	return v0, v1, v2, v3
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Hashes `length` bytes of `message` from `offset`.

	@param  key      8 bytes, read as two little-endian u32
	@param  message  the buffer holding the bytes to hash
	@param  offset   the first byte hashed
	@param  length   how many bytes are hashed
	@param  c        compression rounds per 4-byte word
	@param  d        finalization rounds
	@param  outBytes 4 or 8
	@param  iv0      the constant mixed into v2, 0x6c796765 when nil
	@param  iv1      the constant mixed into v3, 0x74656462 when nil
	@return the low u32 of the output
	@return the high u32 of the output when `outBytes` is 8, otherwise 0
]=]
function HalfSipHash.hash(
	key: buffer,
	message: buffer,
	offset: number,
	length: number,
	c: number,
	d: number,
	outBytes: number,
	iv0: number?,
	iv1: number?
): (number, number)
	local k0 = buffer.readu32(key, 0)
	local k1 = buffer.readu32(key, 4)
	local v0 = k0
	local v1 = k1
	local v2 = bit32.bxor(iv0 or IV0, k0)
	local v3 = bit32.bxor(iv1 or IV1, k1)
	if outBytes == 8 then
		v1 = bit32.bxor(v1, 0xee)
	end

	local left = length % 4
	local stop = offset + length - left
	for at = offset, stop - 1, 4 do
		local word = buffer.readu32(message, at)
		v3 = bit32.bxor(v3, word)
		for _ = 1, c do
			v0, v1, v2, v3 = sipRound(v0, v1, v2, v3)
		end
		v0 = bit32.bxor(v0, word)
	end

	local last = bit32.lshift(length % 256, 24)
	for i = 0, left - 1 do
		last = bit32.bor(last, bit32.lshift(buffer.readu8(message, stop + i), 8 * i))
	end
	v3 = bit32.bxor(v3, last)
	for _ = 1, c do
		v0, v1, v2, v3 = sipRound(v0, v1, v2, v3)
	end
	v0 = bit32.bxor(v0, last)

	v2 = bit32.bxor(v2, if outBytes == 8 then 0xee else 0xff)
	for _ = 1, d do
		v0, v1, v2, v3 = sipRound(v0, v1, v2, v3)
	end
	local low = bit32.bxor(v1, v3)
	if outBytes == 4 then
		return low, 0
	end

	v1 = bit32.bxor(v1, 0xdd)
	for _ = 1, d do
		v0, v1, v2, v3 = sipRound(v0, v1, v2, v3)
	end

	return low, bit32.bxor(v1, v3)
end

return table.freeze(HalfSipHash)
