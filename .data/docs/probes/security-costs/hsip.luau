--!strict
--!optimize 2
-- HalfSipHash for the security-cost probes, written as a build would generate it: SipRounds inlined, the two
-- initialisation constants folded in as K operands (a nonzero build seed replaces them, v5-integrity.md §2).
-- tag13: v5.md §4.5's upstream tag input layout: count u32le, lane u8, frame length u32le, instance count u16le,
-- then the first min(cover, length) bytes of the frame from byte 0; HalfSipHash-1-3, 32-bit output.
-- The message is hashed straight from the frame buffer: words 0-2 come from the header fields and frame byte 0,
-- word j >= 3 is readu32(frame, 4j - 11). ref() is the reference halfsiphash.c port from
-- probes/design-3.5/golden_tag32.luau; check() compares them.
local bxor, bor, band, lshift, rshift, lrot = bit32.bxor, bit32.bor, bit32.band, bit32.lshift, bit32.rshift, bit32.lrotate
local readu32, readu8 = buffer.readu32, buffer.readu8
local M = {}

-- reference (slow, byte strings)
function M.ref(key: string, msg: string, c: number, d: number, outlen: number): string
	local function u32(s, i)
		return string.unpack("<I4", s, i)
	end
	local k0, k1 = u32(key, 1), u32(key, 5)
	local v0, v1, v2, v3 = k0, k1, bxor(0x6c796765, k0), bxor(0x74656462, k1)
	if outlen == 8 then
		v1 = bxor(v1, 0xee)
	end
	local function round()
		v0 = (v0 + v1) % 2 ^ 32; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 = (v2 + v3) % 2 ^ 32; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 = (v0 + v3) % 2 ^ 32; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 = (v2 + v1) % 2 ^ 32; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	local len = #msg
	local full = len - len % 4
	for i = 1, full, 4 do
		local m = u32(msg, i)
		v3 = bxor(v3, m)
		for _ = 1, c do round() end
		v0 = bxor(v0, m)
	end
	local b = lshift(len % 256, 24)
	for j = 0, len % 4 - 1 do
		b = bor(b, lshift(string.byte(msg, full + 1 + j), 8 * j))
	end
	v3 = bxor(v3, b)
	for _ = 1, c do round() end
	v0 = bxor(v0, b)
	v2 = bxor(v2, if outlen == 8 then 0xee else 0xff)
	for _ = 1, d do round() end
	local out = string.pack("<I4", bxor(v1, v3))
	if outlen == 4 then
		return out
	end
	v1 = bxor(v1, 0xdd)
	for _ = 1, d do round() end
	return out .. string.pack("<I4", bxor(v1, v3))
end

-- byte i of the tag message (tail only, at most 3 calls)
local function msgbyte(b: buffer, i: number, count: number, lane: number, len: number, inst: number): number
	if i >= 11 then return readu8(b, i - 11) end
	if i < 4 then return band(rshift(count, 8 * i), 0xff) end
	if i == 4 then return lane end
	if i < 9 then return band(rshift(len, 8 * (i - 5)), 0xff) end
	return band(rshift(inst, 8 * (i - 9)), 0xff)
end

-- HalfSipHash-1-3, 32-bit output: header words straight-line, then one frame word per loop iteration
function M.tag13(k0: number, k1: number, b: buffer, len: number, cover: number, count: number, lane: number, inst: number): number
	local n = if len < cover then len else cover
	if n == 0 then
		return (M.tagcd(k0, k1, b, len, cover, count, lane, inst, 1, 3, false))
	end
	local mlen = 11 + n
	local nw = mlen // 4
	local v0, v1, v2, v3 = k0, k1, bxor(0x6c796765, k0), bxor(0x74656462, k1)
	local m = count
	v3 = bxor(v3, m)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m)
	m = bor(lane, lshift(band(len, 0xffffff), 8))
	v3 = bxor(v3, m)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m)
	m = bor(rshift(len, 24), lshift(inst, 8), lshift(readu8(b, 0), 24))
	v3 = bxor(v3, m)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m)
	for o = 1, 4 * nw - 15, 4 do
		m = readu32(b, o)
		v3 = bxor(v3, m)
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
	end
	m = lshift(band(mlen, 0xff), 24)
	for i = nw * 4, mlen - 1 do
		m = bor(m, lshift(readu8(b, i - 11), 8 * (i % 4)))
	end
	v3 = bxor(v3, m)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m)
	v2 = bxor(v2, 0xff)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	return bxor(v1, v3)
end

-- the same, with c compression and d finalisation rounds and 4- or 8-byte output (claim 11: 2-4, 64-bit)
function M.tagcd(k0: number, k1: number, b: buffer, len: number, cover: number, count: number, lane: number, inst: number, c: number, d: number, out8: boolean): (number, number)
	local n = if len < cover then len else cover
	local mlen = 11 + n
	local nw = mlen // 4
	local v0, v1, v2, v3 = k0, k1, bxor(0x6c796765, k0), bxor(0x74656462, k1)
	if out8 then v1 = bxor(v1, 0xee) end
	local m = count
	for j = 0, nw - 1 do
		if j >= 3 then
			m = readu32(b, 4 * j - 11)
		elseif j == 1 then
			m = bor(lane, lshift(band(len, 0xffffff), 8))
		elseif j == 2 then
			m = bor(rshift(len, 24), lshift(inst, 8), lshift(readu8(b, 0), 24))
		end
		v3 = bxor(v3, m)
		for _ = 1, c do
			v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
			v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
			v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
			v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
		end
		v0 = bxor(v0, m)
	end
	m = lshift(band(mlen, 0xff), 24)
	for i = nw * 4, mlen - 1 do
		m = bor(m, lshift(msgbyte(b, i, count, lane, len, inst), 8 * (i % 4)))
	end
	v3 = bxor(v3, m)
	for _ = 1, c do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	v0 = bxor(v0, m)
	v2 = bxor(v2, if out8 then 0xee else 0xff)
	for _ = 1, d do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	local lo = bxor(v1, v3)
	if not out8 then return lo, 0 end
	v1 = bxor(v1, 0xdd)
	for _ = 1, d do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	return lo, bxor(v1, v3)
end

-- tag13 with the word loop unrolled by 4 and each rotate nested in its xor (a generated variant); same output
function M.tag13u4(k0: number, k1: number, b: buffer, len: number, cover: number, count: number, lane: number, inst: number): number
	local n = if len < cover then len else cover
	local mlen = 11 + n
	local nw = mlen // 4
	local v0, v1, v2, v3 = k0, k1, bxor(0x6c796765, k0), bxor(0x74656462, k1)
	local m
	local j = 0
	while j < nw and j < 3 do
		m = if j == 0 then count elseif j == 1 then bor(lane, lshift(band(len, 0xffffff), 8)) else bor(rshift(len, 24), lshift(inst, 8), lshift(readu8(b, 0), 24))
		v3 = bxor(v3, m)
		v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = bxor(lrot(v3, 8), v2)
		v0 += v3; v3 = bxor(lrot(v3, 7), v0)
		v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
		j += 1
	end
	local o = 4 * j - 11
	local stop4 = 4 * (nw - 4) - 11
	while o <= stop4 do
		m = readu32(b, o)
		v3 = bxor(v3, m)
		v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = bxor(lrot(v3, 8), v2)
		v0 += v3; v3 = bxor(lrot(v3, 7), v0)
		v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
		m = readu32(b, o + 4)
		v3 = bxor(v3, m)
		v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = bxor(lrot(v3, 8), v2)
		v0 += v3; v3 = bxor(lrot(v3, 7), v0)
		v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
		m = readu32(b, o + 8)
		v3 = bxor(v3, m)
		v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = bxor(lrot(v3, 8), v2)
		v0 += v3; v3 = bxor(lrot(v3, 7), v0)
		v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
		m = readu32(b, o + 12)
		v3 = bxor(v3, m)
		v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = bxor(lrot(v3, 8), v2)
		v0 += v3; v3 = bxor(lrot(v3, 7), v0)
		v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
		o += 16
	end
	local last = 4 * (nw - 1) - 11
	while o <= last do
		m = readu32(b, o)
		v3 = bxor(v3, m)
		v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = bxor(lrot(v3, 8), v2)
		v0 += v3; v3 = bxor(lrot(v3, 7), v0)
		v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
		o += 4
	end
	m = lshift(band(mlen, 0xff), 24)
	for i = nw * 4, mlen - 1 do
		m = bor(m, lshift(msgbyte(b, i, count, lane, len, inst), 8 * (i % 4)))
	end
	v3 = bxor(v3, m)
	v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = bxor(lrot(v3, 8), v2)
	v0 += v3; v3 = bxor(lrot(v3, 7), v0)
	v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m)
	v2 = bxor(v2, 0xff)
	for _ = 1, 3 do
		v0 += v1; v1 = bxor(lrot(v1, 5), v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = bxor(lrot(v3, 8), v2)
		v0 += v3; v3 = bxor(lrot(v3, 7), v0)
		v2 += v1; v1 = bxor(lrot(v1, 13), v2); v2 = lrot(v2, 16)
	end
	return bxor(v1, v3)
end

-- HalfSipHash-1-3 over an 8-byte message (two words), 32-bit output: a per-recipient finaliser
function M.prf2(k0: number, k1: number, m0: number, m1: number): number
	local v0, v1, v2, v3 = k0, k1, bxor(0x6c796765, k0), bxor(0x74656462, k1)
	v3 = bxor(v3, m0)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m0)
	v3 = bxor(v3, m1)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m1)
	local m = 0x08000000
	v3 = bxor(v3, m)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
	v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
	v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, m)
	v2 = bxor(v2, 0xff)
	for _ = 1, 3 do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 += v3; v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	return bxor(v1, v3)
end

-- compare the fast functions with the reference on random frames; returns the number of cases checked
function M.check(): number
	local key = "\0\1\2\3\4\5\6\7"
	assert(M.ref(key, "", 2, 4, 4) == "\xa9\x35\x9f\x5b", "reference vector HalfSipHash-2-4/32 of empty input")
	local k0, k1 = string.unpack("<I4I4", key)
	local seed = 12345
	local function rnd(n: number): number
		seed = (seed * 48271) % 2147483647
		return seed % n
	end
	local cases = 0
	for len = 0, 80 do
		for _, cover in { 0, 1, 5, 64, 1024 } do
			local b = buffer.create(len + 4)
			for i = 0, len - 1 do
				buffer.writeu8(b, i, rnd(256))
			end
			local count, lane, inst = rnd(2 ^ 31), rnd(2), rnd(300)
			local n = math.min(len, cover)
			local msg = string.pack("<I4BI4I2", count, lane, len, inst) .. buffer.readstring(b, 0, n)
			local want = string.unpack("<I4", M.ref(key, msg, 1, 3, 4))
			assert(M.tag13(k0, k1, b, len, cover, count, lane, inst) == want, "tag13 len " .. len .. " cover " .. cover)
			assert(M.tag13u4(k0, k1, b, len, cover, count, lane, inst) == want, "tag13u4 len " .. len .. " cover " .. cover)
			assert((M.tagcd(k0, k1, b, len, cover, count, lane, inst, 1, 3, false)) == want, "tagcd 1-3")
			local w24 = string.unpack("<I4", M.ref(key, msg, 2, 4, 4))
			assert((M.tagcd(k0, k1, b, len, cover, count, lane, inst, 2, 4, false)) == w24, "tagcd 2-4")
			local lo, hi = string.unpack("<I4I4", M.ref(key, msg, 1, 3, 8))
			local a1, a2 = M.tagcd(k0, k1, b, len, cover, count, lane, inst, 1, 3, true)
			assert(a1 == lo and a2 == hi, "tagcd 1-3/64")
			cases += 1
		end
	end
	local m8 = string.pack("<I4I4", 0xdeadbeef, 0x01234567)
	assert(M.prf2(k0, k1, 0xdeadbeef, 0x01234567) == string.unpack("<I4", M.ref(key, m8, 1, 3, 4)), "prf2")
	return cases
end

return M
