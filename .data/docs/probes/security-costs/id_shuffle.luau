--!strict
-- Claim 4: "Per-session upstream id shuffle: a decode table of ~20,000 slots for 200 definitions x 100 players"
-- (client-security.md §3.4, v5-changes.md:104, :557; R3). Measures memory and per-message lookup for:
--   shared   : the per-server permutation the design already has (one table, baseline)
--   perTable : one Luau array of 200 numbers per player
--   perBuf   : one 200-byte buffer per player (u8 entries; u16 when a space has > 256 ids)
--   pool     : 16 build-generated permutation tables, each player holding a pool index (per-player variant)
--   xorMask  : wire id = canonical id XOR a per-session w-bit mask; decode = one bxor and a range check
--              (ids >= count are already rule 7), no table at all
--   affine   : wire id = (a*id + c) mod count, a odd and coprime with count; decode = ((wire - c) * ainv) mod count
-- and per-player build cost at join.
-- Run: luau -O2 id_shuffle.luau ; luau -O2 --codegen id_shuffle.luau
local H = require("./harness")

local DEFS, PLAYERS = 200, 100
local W = 8 -- u(ceil(log2 200)) = 8 bits

local function xorshift(x: number): number
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	return bit32.bxor(x, bit32.lshift(x, 5))
end
local function permTable(seed: number): { number }
	local p = table.create(DEFS, 0)
	for i = 1, DEFS do p[i] = i - 1 end
	local x = if seed == 0 then 0x9E3779B9 else seed
	for i = DEFS, 2, -1 do
		x = xorshift(x)
		local j = x % i + 1
		p[i], p[j] = p[j], p[i]
	end
	-- decode table: wire id -> canonical id
	local inv = table.create(DEFS, 0)
	for c = 1, DEFS do inv[p[c] + 1] = c - 1 end
	return inv
end
local function permBuf(seed: number): buffer
	local t = permTable(seed)
	local b = buffer.create(DEFS)
	for i = 1, DEFS do buffer.writeu8(b, i - 1, t[i]) end
	return b
end
local function gcd(a: number, b: number): number
	while b ~= 0 do a, b = b, a % b end
	return a
end
local function affine(seed: number): (number, number, number)
	local x = xorshift(seed)
	local a = (x % DEFS) * 2 + 1
	while gcd(a % DEFS, DEFS) ~= 1 do a += 2 end
	a %= DEFS
	local inv = 1
	while (a * inv) % DEFS ~= 1 do inv += 1 end
	return a, (xorshift(x) % DEFS), inv
end

-- memory
local function kb(): number
	collectgarbage("collect")
	return collectgarbage("count")
end
local k0 = kb()
local tabs = table.create(PLAYERS)
for p = 1, PLAYERS do tabs[p] = permTable(p * 7919) end
local k1 = kb()
local bufs = table.create(PLAYERS)
for p = 1, PLAYERS do bufs[p] = permBuf(p * 7919) end
local k2 = kb()
local pool = table.create(16)
for i = 1, 16 do pool[i] = permTable(i * 104729) end
local k3 = kb()
print(string.format("memory, %d players x %d ids: per-player tables %.1f KB (%.1f B/slot); per-player buffers %.1f KB (%.2f B/slot); pool of 16 tables %.1f KB; xor mask or affine: 2-3 numbers per player in the session record",
	PLAYERS, DEFS, k1 - k0, (k1 - k0) * 1024 / (PLAYERS * DEFS), k2 - k1, (k2 - k1) * 1024 / (PLAYERS * DEFS), k3 - k2))

-- per-player session records
type Sess = { perm: { number }, buf: buffer, poolIx: number, mask: number, a: number, c: number, ainv: number }
local sess: { Sess } = table.create(PLAYERS)
for p = 1, PLAYERS do
	local a, c, ainv = affine(p * 31337)
	sess[p] = { perm = tabs[p], buf = bufs[p], poolIx = p % 16 + 1, mask = xorshift(p * 31337) % 2 ^ W, a = a, c = c, ainv = ainv }
end
-- check affine and xor are bijections onto the decoded space
do
	local s = sess[3]
	local seen = {}
	for id = 0, DEFS - 1 do
		local wire = (s.a * id + s.c) % DEFS
		assert(((wire - s.c) * s.ainv) % DEFS == id)
		assert(not seen[wire]); seen[wire] = true
		local wx = bit32.bxor(id, s.mask)
		assert(wx < 2 ^ W and bit32.bxor(wx, s.mask) == id)
	end
	print("check: affine and xor maps invert on all 200 ids")
end
local shared = permTable(42)

-- wire ids of a frame's messages (one frame = 8 messages from one player, then the next player)
local ids = table.create(4096, 0)
for i = 1, 4096 do ids[i] = (i * 37) % DEFS end
local N = 2000000
H.compare("decode one message id (8 messages per frame, frame's player looked up once per frame)", N, {
	{ name = "shared per-server table", fn = function(n)
		local s = 0
		for i = 1, n do
			local id = ids[i % 4096 + 1]
			s += shared[id + 1]
		end
		return s
	end },
	{ name = "per-player table", fn = function(n)
		local s, t = 0, sess[1].perm
		for i = 1, n do
			if i % 8 == 0 then t = sess[(i // 8) % PLAYERS + 1].perm end
			local id = ids[i % 4096 + 1]
			s += t[id + 1]
		end
		return s
	end },
	{ name = "per-player buffer (u8)", fn = function(n)
		local s, b = 0, sess[1].buf
		for i = 1, n do
			if i % 8 == 0 then b = sess[(i // 8) % PLAYERS + 1].buf end
			local id = ids[i % 4096 + 1]
			s += buffer.readu8(b, id)
		end
		return s
	end },
	{ name = "pool of 16 generated tables", fn = function(n)
		local s, t = 0, pool[1]
		for i = 1, n do
			if i % 8 == 0 then t = pool[sess[(i // 8) % PLAYERS + 1].poolIx] end
			local id = ids[i % 4096 + 1]
			s += t[id + 1]
		end
		return s
	end },
	{ name = "xor mask + range check", fn = function(n)
		local s, m = 0, sess[1].mask
		for i = 1, n do
			if i % 8 == 0 then m = sess[(i // 8) % PLAYERS + 1].mask end
			local c = bit32.bxor(ids[i % 4096 + 1], m)
			if c < DEFS then s += c end
		end
		return s
	end },
	{ name = "affine mod count", fn = function(n)
		local s = 0
		local ss = sess[1]
		local c0, ai = ss.c, ss.ainv
		for i = 1, n do
			if i % 8 == 0 then ss = sess[(i // 8) % PLAYERS + 1]; c0, ai = ss.c, ss.ainv end
			s += ((ids[i % 4096 + 1] - c0) * ai) % DEFS
		end
		return s
	end },
})

H.compare("per-player setup at join (200 ids)", 2000, {
	{ name = "Fisher-Yates table + inverse", fn = function(n)
		local s = 0
		for i = 1, n do s += permTable(i)[1] end
		return s
	end },
	{ name = "Fisher-Yates into a buffer", fn = function(n)
		local s = 0
		for i = 1, n do s += buffer.readu8(permBuf(i), 0) end
		return s
	end },
	{ name = "affine parameters", fn = function(n)
		local s = 0
		for i = 1, n do local a = affine(i); s += a end
		return s
	end },
	{ name = "xor mask draw", fn = function(n)
		local s = 0
		for i = 1, n do s += xorshift(i) % 256 end
		return s
	end },
})
print("sink", H.sink)
