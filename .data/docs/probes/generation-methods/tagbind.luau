--!strict
--!optimize 2
-- M13: server verification cost of a per-variant tag binding. Uses Lync's own HalfSipHash (git f1fbfd7:
-- src/wire/halfsiphash.luau, exported by run3.sh into WORK_DIR next to this file), 32-bit output, over the
-- v5.md §4.5 input: count u32, lane u8, length u32, instance count u16, then the covered frame bytes.
-- Forms per reliable frame (expected count e, lookahead e .. e + 4):
--   today      tag == H_K(count)                          (accepted: 1 hash; failing: 5 hashes)
--   mask       tag == H_K(count) xor mask_v, and on a miss MASKS[tag xor H_K(count)] names the variant
--   rehash     per-variant initialisation constants: a failing frame is re-hashed under each other variant
-- Run (from WORK_DIR): luau -O2 tagbind.luau   and   luau -O2 --codegen tagbind.luau

local HalfSipHash = require("./src/wire/halfsiphash")
local hash = HalfSipHash.hash
local bxor = bit32.bxor

local PREFIX = 11
local SCRATCH = buffer.create(PREFIX + 16384)
local key = buffer.create(8)
buffer.writeu32(key, 0, 0x01234567); buffer.writeu32(key, 4, 0x89abcdef)

local function tagOf(count: number, frame: buffer, length: number, iv0: number?, iv1: number?): number
	buffer.writeu32(SCRATCH, 0, count)
	buffer.writeu8(SCRATCH, 4, 0)
	buffer.writeu32(SCRATCH, 5, length)
	buffer.writeu16(SCRATCH, 9, 0)
	buffer.copy(SCRATCH, PREFIX, frame, 0, length)
	return (hash(key, SCRATCH, 0, PREFIX + length, 1, 3, 4, iv0, iv1))
end

local function verifyToday(tag: number, e: number, frame: buffer, length: number): number
	for j = 0, 4 do
		if tagOf(e + j, frame, length) == tag then return j end
	end
	return -1
end

local function verifyMask(tag: number, e: number, frame: buffer, length: number, mask: number, MASKS: { [number]: number }): (number, number)
	local crossed = 0
	for j = 0, 4 do
		local d = bxor(tagOf(e + j, frame, length), tag)
		if d == mask then return j, 0 end
		if crossed == 0 then
			local u = MASKS[d]
			if u ~= nil then crossed = u end
		end
	end
	return -1, crossed
end

local IVS: { { number } } = {}
local function verifyRehash(tag: number, e: number, frame: buffer, length: number, own: number, n: number): (number, number)
	for j = 0, 4 do
		if tagOf(e + j, frame, length, IVS[own][1], IVS[own][2]) == tag then return j, 0 end
	end
	for u = 1, n do
		if u == own then continue end
		local iv = IVS[u]
		for j = 0, 4 do
			if tagOf(e + j, frame, length, iv[1], iv[2]) == tag then return -1, u end
		end
	end
	return -1, 0
end

-- 256 variants: masks distinct and nonzero, constants drawn the same way
local x = 0x2545F491
local function nextU32(): number
	x = bxor(x, bit32.lshift(x, 13)); x = bxor(x, bit32.rshift(x, 17)); x = bxor(x, bit32.lshift(x, 5))
	return x
end
local NV = 256
local MASK: { number } = {}
local MASKS: { [number]: number } = {}
collectgarbage("collect")
local k0 = collectgarbage("count")
for v = 1, NV do
	local m = nextU32()
	while MASKS[m] ~= nil do m = nextU32() end
	MASK[v] = m; MASKS[m] = v
end
local mapBytes = (collectgarbage("count") - k0) * 1024
for v = 1, NV do IVS[v] = { nextU32(), nextU32() } end

local ROUNDS = 7
local function best(m: number, f: () -> ()): number
	local b = math.huge
	for _ = 1, ROUNDS do
		local t0 = os.clock()
		for _ = 1, m do f() end
		b = math.min(b, os.clock() - t0)
	end
	return b / m * 1e6
end

for _, length in { 64, 1024 } do
	local frame = buffer.create(length)
	for i = 0, length - 1 do buffer.writeu8(frame, i, (i * 37 + 11) % 256) end
	local m = if length == 64 then 40_000 else 4_000
	local e = 1000
	local own = 7
	local good = tagOf(e, frame, length)
	local goodMasked = bxor(good, MASK[own])
	local crossTag = bxor(tagOf(e + 2, frame, length), MASK[200]) -- carried from variant 200, count e + 2
	local junk = bxor(good, 0x5a5a5a5a)
	-- correctness
	assert(verifyToday(good, e, frame, length) == 0)
	local j, u = verifyMask(goodMasked, e, frame, length, MASK[own], MASKS); assert(j == 0 and u == 0)
	j, u = verifyMask(crossTag, e, frame, length, MASK[own], MASKS); assert(j == -1 and u == 200)
	j, u = verifyMask(junk, e, frame, length, MASK[own], MASKS); assert(j == -1)
	local rehashCross = tagOf(e + 2, frame, length, IVS[16][1], IVS[16][2])
	j, u = verifyRehash(rehashCross, e, frame, length, own, 16); assert(j == -1 and u == 16)

	print(string.format("frame %d B (cover all)", length))
	print(string.format("  accepted at e:   today %7.2f us   mask %7.2f us",
		best(m, function() verifyToday(good, e, frame, length) end),
		best(m, function() verifyMask(goodMasked, e, frame, length, MASK[own], MASKS) end)))
	print(string.format("  failing (5 counts): today %7.2f us   mask+lookup %7.2f us",
		best(m // 5, function() verifyToday(junk, e, frame, length) end),
		best(m // 5, function() verifyMask(junk, e, frame, length, MASK[own], MASKS) end)))
	print(string.format("  failing, rehash under 15 other variants (N = 16): %8.1f us",
		best(math.max(m // 80, 10), function() verifyRehash(junk, e, frame, length, own, 16) end)))
end

print(string.format("mask map, %d variants: %.0f B", NV, mapBytes))

-- chance of a cross-variant match for a sender without the key, at the default frame budgets (v5.md §7.5)
print("chance cross matches at full default budget (120 reliable x 5 counts + 240 unreliable x 3 extensions per s):")
for _, n in { 2, 16, 64, 256 } do
	local perSecond = (120 * 5 + 240 * 3) * (n - 1)
	local seconds = 2 ^ 32 / perSecond
	print(string.format("  N = %3d: %8d candidates/s, one chance match per %10.0f s (%.1f h)", n, perSecond, seconds, seconds / 3600))
end
