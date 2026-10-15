--!optimize 2
-- Shape of one generated shard. compare.py fills the placeholders (tag constants, definition ids and
-- field order) from a seed, compiles each variant and compares the instruction streams.
local C0, C1, C2, C3 = @C0, @C1, @C2, @C3

-- One HalfSipHash-style round over a 32-bit word, keyed by the per-connection key k0/k1 (runtime)
-- and the per-build constants C0..C3 (compile time).
local function tagWord(k0: number, k1: number, m: number): number
	local v0 = bit32.bxor(k0, C0)
	local v1 = bit32.bxor(k1, C1)
	local v2 = bit32.bxor(k0, C2)
	local v3 = bit32.bxor(bit32.bxor(k1, C3), m)
	v0 = bit32.band(v0 + v1, 0xFFFFFFFF)
	v1 = bit32.bxor(bit32.lrotate(v1, 5), v0)
	v0 = bit32.lrotate(v0, 16)
	v2 = bit32.band(v2 + v3, 0xFFFFFFFF)
	v3 = bit32.bxor(bit32.lrotate(v3, 8), v2)
	return bit32.bxor(bit32.bxor(v0, v1), bit32.bxor(v2, v3))
end

local function writeHit(b: buffer, o: number, v: { target: number, damage: number, crit: boolean }): number
@FIELDS
	return o
end

local function dispatch(id: number, b: buffer, o: number): number
	if id == @ID_HIT then
		return buffer.readu16(b, o)
	elseif id == @ID_SHOOT then
		return buffer.readu8(b, o)
	elseif id == @ID_RELOAD then
		return 0
	end
	return -1
end

return { tagWord = tagWord, writeHit = writeHit, dispatch = dispatch }
