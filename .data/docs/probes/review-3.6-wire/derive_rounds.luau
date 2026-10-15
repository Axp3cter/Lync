--!strict
-- SipRounds per call for the §4.5 derivation inputs, and a timing ratio of HalfSipHash-2-4/64 against 1-3/32 on
-- the same 9-byte and 5-byte inputs (one straight-line implementation, rounds as a parameter).
local bxor, lrot = bit32.bxor, bit32.lrotate
local function hsip(k0: number, k1: number, m: { number }, c: number, d: number, out8: boolean): (number, number)
	local v0, v1, v2, v3 = k0, k1, bxor(0x6c796765, k0), bxor(0x74656462, k1)
	if out8 then v1 = bxor(v1, 0xee) end
	local function r()
		v0 = (v0 + v1) % 4294967296; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 = (v2 + v3) % 4294967296; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 = (v0 + v3) % 4294967296; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 = (v2 + v1) % 4294967296; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	local n = #m local full = n - n % 4
	for i = 1, full, 4 do local w = m[i] + m[i+1]*256 + m[i+2]*65536 + m[i+3]*16777216; v3 = bxor(v3, w); for _ = 1, c do r() end; v0 = bxor(v0, w) end
	local b = (n % 256) * 16777216
	for j = n % 4, 1, -1 do b += m[full + j] * 256 ^ (j - 1) end
	v3 = bxor(v3, b); for _ = 1, c do r() end; v0 = bxor(v0, b)
	v2 = bxor(v2, if out8 then 0xee else 0xff); for _ = 1, d do r() end
	local a = bxor(v1, v3)
	if out8 then v1 = bxor(v1, 0xdd); for _ = 1, d do r() end; return a, bxor(v1, v3) end
	return a, 0
end
local function rounds(len: number, c: number, d: number, out8: boolean) return (len // 4 + 1) * c + d + (if out8 then d else 0) end
print("rounds, 9 B key input: 1-3/32", rounds(9, 1, 3, false), " 2-4/64", rounds(9, 2, 4, true))
print("rounds, 5 B seed input: 1-3/32", rounds(5, 1, 3, false), " 2-4/64", rounds(5, 2, 4, true))
local m9 = { 8, 9, 10, 11, 12, 13, 14, 15, 1 }
local N = 200000
local function time(c, d, o)
	local t = os.clock() for _ = 1, N do hsip(0x03020100, 0x07060504, m9, c, d, o) end return (os.clock() - t) / N * 1e9
end
local a, b = time(1, 3, false), time(2, 4, true)
print(string.format("9 B: 1-3/32 %.0f ns, 2-4/64 %.0f ns, ratio %.2f", a, b, b / a))
