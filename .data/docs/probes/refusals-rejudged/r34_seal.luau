--!strict
--!optimize 2
-- R34: cost of a sealed (pre-sent, revealed later) payload: a keystream from HalfSipHash-2-4 with
-- 64-bit output in counter mode, block j = HSH24_K(sealId u32le || j u32le), XORed over the
-- payload. Encryption and decryption are the same operation. Checked against the reference port in
-- ../security-costs/hsip.luau (itself checked against the official empty-input vector).
local H = require("../security-costs/harness")
local Ref = require("../security-costs/hsip")
local bxor, lrot = bit32.bxor, bit32.lrotate
local readu32, writeu32 = buffer.readu32, buffer.writeu32

-- one 8-byte message (m0, m1), HalfSipHash-2-4, 64-bit output (v1 ^= 0xee at start, 0xee, then 0xdd)
local function block(k0: number, k1: number, m0: number, m1: number): (number, number)
	local v0, v1, v2, v3 = k0, bxor(k1, 0xee), bxor(0x6c796765, k0), bxor(0x74656462, k1)
	v3 = bxor(v3, m0)
	for _ = 1, 2 do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	v0 = bxor(v0, m0)
	v3 = bxor(v3, m1)
	for _ = 1, 2 do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	v0 = bxor(v0, m1)
	local b = 0x08000000 -- length 8 in the top byte, no tail bytes
	v3 = bxor(v3, b)
	for _ = 1, 2 do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	v0 = bxor(v0, b)
	v2 = bxor(v2, 0xee)
	for _ = 1, 4 do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	local lo = bxor(v1, v3)
	v1 = bxor(v1, 0xdd)
	for _ = 1, 4 do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	return lo, bxor(v1, v3)
end

-- XOR the keystream over b[0, n), n a multiple of 8 (a sealed payload is padded to 8 B)
local function seal(k0: number, k1: number, sealId: number, b: buffer, n: number)
	local j = 0
	for at = 0, n - 8, 8 do
		local lo, hi = block(k0, k1, sealId, j)
		writeu32(b, at, bxor(readu32(b, at), lo))
		writeu32(b, at + 4, bxor(readu32(b, at + 4), hi))
		j += 1
	end
end

-- correctness against the reference
do
	local key = "\0\1\2\3\4\5\6\7"
	local k0, k1 = string.unpack("<I4I4", key)
	for _, m in { { 0, 0 }, { 7, 1 }, { 0xdeadbeef, 0x01234567 } } do
		local want = Ref.ref(key, string.pack("<I4I4", m[1], m[2]), 2, 4, 8)
		local lo, hi = block(k0, k1, m[1], m[2])
		assert(string.pack("<I4I4", lo, hi) == want, "block mismatch")
	end
	local b = buffer.create(64)
	for i = 0, 63 do buffer.writeu8(b, i, i) end
	seal(k0, k1, 9, b, 64); seal(k0, k1, 9, b, 64)
	for i = 0, 63 do assert(buffer.readu8(b, i) == i, "not an involution") end
	print("check: block = reference HalfSipHash-2-4/64 on 3 messages; seal is an involution")
end

for _, n in { 1024, 16384, 65536 } do
	local b = buffer.create(n)
	local res = H.compare(string.format("seal %d B", n), math.max(1, 262144 // n), {
		{ name = "HSH-2-4/64 counter keystream", fn = function(m)
			for i = 1, m do seal(0x03020100, 0x07060504, i, b, n) end
			return buffer.readu8(b, 0)
		end },
	})
	print(string.format("  per byte: %.1f ns", res["HSH-2-4/64 counter keystream"] / n))
end
