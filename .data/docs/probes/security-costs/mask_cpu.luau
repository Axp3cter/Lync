--!strict
-- Claim 2 (CPU): masking costs "CPU per byte at the tag's rate on both ends" (v5-changes.md:103, :556; R2).
-- Per frame, masking n bytes in place (the bit section; the tail stays plain, mask_bytes.out):
--   tag rate      : the generated HalfSipHash-1-3 tag over n bytes (hsip.tag13u4), the reference rate
--   PRF CTR       : one 2-word HalfSipHash-1-3 per 4 keystream bytes (key, count, word index)
--   xorshift      : one PRF call per frame seeds a xorshift32 + Weyl keystream (per-build constants folded in)
--   session pad   : a 16 KB keystream computed once per session; each frame XORs a slice chosen by its count
-- Each mask is an involution (masking twice restores the frame), checked first.
-- Run: luau -O2 mask_cpu.luau ; luau -O2 --codegen mask_cpu.luau
local H = require("./harness")
local S = require("./hsip")
local bxor, lshift, rshift = bit32.bxor, bit32.lshift, bit32.rshift
local readu32, writeu32 = buffer.readu32, buffer.writeu32
local K0, K1 = 0x9abcdef0, 0x12345678

local function maskCtr(b: buffer, n: number, count: number)
	for o = 0, n - 4, 4 do
		writeu32(b, o, bxor(readu32(b, o), S.prf2(K0, K1, count, o)))
	end
end
local function maskXs(b: buffer, n: number, count: number)
	local x = S.prf2(K0, K1, count, 0xffffffff)
	if x == 0 then x = 0x6d2b79f5 end
	local wy = 0
	for o = 0, n - 4, 4 do
		x = bxor(x, lshift(x, 13)); x = bxor(x, rshift(x, 17)); x = bxor(x, lshift(x, 5))
		wy += 0x9e3779b9 -- per-build constant
		writeu32(b, o, bxor(readu32(b, o), x + wy))
	end
end
local PAD = 16384
local pad = buffer.create(PAD + 8)
for o = 0, PAD - 4, 4 do
	writeu32(pad, o, S.prf2(K0, K1, 0x7fffffff, o))
end
local function maskPad(b: buffer, n: number, count: number)
	local base = ((count * 4093) % ((PAD - n) // 4 + 1)) * 4
	for o = 0, n - 4, 4 do
		writeu32(b, o, bxor(readu32(b, o), readu32(pad, base + o)))
	end
end

for _, n in { 64, 256, 1024 } do
	local b = buffer.create(n + 4)
	for i = 0, n - 1 do buffer.writeu8(b, i, (i * 29 + 3) % 256) end
	local orig = buffer.tostring(b)
	for _, f in { maskCtr, maskXs, maskPad } do
		f(b, n, 77); assert(buffer.tostring(b) ~= orig); f(b, n, 77); assert(buffer.tostring(b) == orig)
	end
	local iters = math.max(400, 2000000 // (n + 64))
	local r = H.compare(string.format("mask a %d B bit section (time per frame)", n), iters, {
		{ name = "tag rate (tag13u4 over n B)", fn = function(m)
			local s = 0
			for i = 1, m do s = bxor(s, S.tag13u4(K0, K1, b, n, 16384, i, 0, 0)) end
			return s
		end },
		{ name = "PRF CTR keystream", fn = function(m)
			for i = 1, m do maskCtr(b, n, i) end
			return readu32(b, 0)
		end },
		{ name = "xorshift keystream (1 PRF/frame)", fn = function(m)
			for i = 1, m do maskXs(b, n, i) end
			return readu32(b, 0)
		end },
		{ name = "session pad slice", fn = function(m)
			for i = 1, m do maskPad(b, n, i) end
			return readu32(b, 0)
		end },
	})
	local row = {}
	for name, ns in r do table.insert(row, string.format("%s %.2f ns/B", name, ns / n)) end
	table.sort(row)
	print(string.format("per byte at %d B: %s", n, table.concat(row, "; ")))
end
print("sink", H.sink)
