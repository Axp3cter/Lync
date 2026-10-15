-- Draft 3.6 (after review): v5.md draft 3.6's wire. Upstream headers: reliable caller:u1 ack rcv:u8; unreliable
-- seq:u12 caller:u1 ack receipt ('0' | '1' rcv:u8); caller is also the high bit of the tag input's lane byte. Schema
-- serialization: perceived (client-sent events and requests) and sealed (server-sent reliable events) option slots,
-- string tables (kind 4) and codec type 27. HELLO: idTableHash u32, path u1. WELCOME: layout u1; first WELCOME delay
-- u8 (D0). Id permutation: Fisher-Yates with HalfSipHash-1-3 draws under a 64-bit space key. Adds G4c, PERM, DERIVE,
-- ROT (per-build draws of v5-integrity.md section 2.2 at a nonzero rotationSeed), W1, W2, S0-S3 and SIZES.
-- Consistency pass (wire, 2026-10-15): the option slot acked after sealed (collections take it; absent 00 for every
-- event and request), so G6, G7 and S0 change; the first WELCOME's two report bits (report.checkListenerCaller,
-- report.checkOwnTables) between callerProbe.maxProbesPerSecond and clock.beaconSeconds, so G10 changes; SIZES gains the
-- REPORT with a self-check failure at item 202, case 3. Option names follow the naming review (timeoutSeconds,
-- reliablePerSecond, ackEveryFrame, sealed.maxOutstanding); names are not hashed, so they change no byte.
-- Design draft 3.1: milestone 1 and 2 golden frames, built from draft 3.1's rules (v5.md §3.3, §4).
-- Adapts review-3's p2_golden.luau: EG-k as EG-0 of floor(u/2^k) then u(k) of u mod 2^k; integer columns with
-- codes on an interval of n, residual wrapped into [-floor(n/2), ceil(n/2) - 1], zigzag; encoder ties: lowest
-- cost, then lowest mode, then lowest k; FOR base = minimum, width = minimal. Untagged HELLO frames don't count.
local W = {}
W.__index = W
local function writer()
	return setmetatable({ b = buffer.create(4096), pos = 0 }, W)
end
function W.u(self, width: number, v: number)
	while width > 32 do
		buffer.writebits(self.b, self.pos, 32, v % 2 ^ 32)
		self.pos += 32
		v = math.floor(v / 2 ^ 32)
		width -= 32
	end
	if width > 0 then
		buffer.writebits(self.b, self.pos, width, v)
		self.pos += width
	end
end
function W.bit(self, v: number)
	self:u(1, v)
end
local function bitlen(v: number): number
	local n = 0
	while v >= 1 do
		v = math.floor(v / 2)
		n += 1
	end
	return n
end
local function eg0bits(x: number): number
	return 2 * bitlen(x + 1) - 1
end
function W.eg0(self, x: number)
	local z = bitlen(x + 1) - 1
	for _ = 1, z do
		self:bit(0)
	end
	self:bit(1)
	self:u(z, (x + 1) - 2 ^ z)
end
function W.eg(self, u: number, k: number)
	self:eg0(math.floor(u / 2 ^ k))
	self:u(k, u % 2 ^ k)
end
local function egbits(u: number, k: number): number
	return eg0bits(math.floor(u / 2 ^ k)) + k
end
function W.align(self)
	self.pos = math.ceil(self.pos / 8) * 8
end
local function ceilLog2(n: number): number
	local w = 0
	while 2 ^ w < n do
		w += 1
	end
	return w
end
local function bytesOf(w, tail: string?): string
	w:align()
	return buffer.readstring(w.b, 0, w.pos // 8) .. (tail or "")
end
local function hex(s: string): string
	return (s:gsub(".", function(c)
		return string.format("%02x ", string.byte(c))
	end))
end
local function zigzag(v: number): number
	return if v >= 0 then 2 * v else -2 * v - 1
end

-- HalfSipHash, reference halfsiphash.c (c compression, d finalization rounds, 4- or 8-byte output)
local function halfsiphash(key: string, msg: string, c: number, d: number, outlen: number, c0: number?, c1: number?): string
	local function u32(s, i)
		return string.unpack("<I4", s, i)
	end
	local k0, k1 = u32(key, 1), u32(key, 5)
	local v0, v1, v2, v3 = k0, k1, bit32.bxor(c0 or 0x6c796765, k0), bit32.bxor(c1 or 0x74656462, k1)
	if outlen == 8 then
		v1 = bit32.bxor(v1, 0xee)
	end
	local function round()
		v0 = (v0 + v1) % 2 ^ 32; v1 = bit32.lrotate(v1, 5); v1 = bit32.bxor(v1, v0); v0 = bit32.lrotate(v0, 16)
		v2 = (v2 + v3) % 2 ^ 32; v3 = bit32.lrotate(v3, 8); v3 = bit32.bxor(v3, v2)
		v0 = (v0 + v3) % 2 ^ 32; v3 = bit32.lrotate(v3, 7); v3 = bit32.bxor(v3, v0)
		v2 = (v2 + v1) % 2 ^ 32; v1 = bit32.lrotate(v1, 13); v1 = bit32.bxor(v1, v2); v2 = bit32.lrotate(v2, 16)
	end
	local len = #msg
	local full = len - len % 4
	for i = 1, full, 4 do
		local m = u32(msg, i)
		v3 = bit32.bxor(v3, m)
		for _ = 1, c do round() end
		v0 = bit32.bxor(v0, m)
	end
	local b = bit32.lshift(len % 256, 24)
	for j = 0, len % 4 - 1 do
		b = bit32.bor(b, bit32.lshift(string.byte(msg, full + 1 + j), 8 * j))
	end
	v3 = bit32.bxor(v3, b)
	for _ = 1, c do round() end
	v0 = bit32.bxor(v0, b)
	v2 = bit32.bxor(v2, if outlen == 8 then 0xee else 0xff)
	for _ = 1, d do round() end
	local out = string.pack("<I4", bit32.bxor(v1, v3))
	if outlen == 4 then
		return out
	end
	v1 = bit32.bxor(v1, 0xdd)
	for _ = 1, d do round() end
	return out .. string.pack("<I4", bit32.bxor(v1, v3))
end
local key07 = "\0\1\2\3\4\5\6\7"
print("check HalfSipHash-2-4/32, key 00..07, empty:", hex(halfsiphash(key07, "", 2, 4, 4)), "(reference a9 35 9f 5b)")
local function tag(key, count, lane, frame, instances, caller, c0, c1)
	local input = string.pack("<I4BI4I2", count % 2 ^ 32, lane + 128 * (caller or 0), #frame, instances) .. frame:sub(1, 1024)
	return halfsiphash(key, input, 1, 3, 4, c0, c1)
end

-- Column encoder (v5.md §4.3). codes: array of integers in [lo, lo + n - 1]. Returns the cheapest encoding.
local function column(w, codes: { number }, lo: number, n: number)
	if #codes == 0 then
		return -- a column over zero rows writes nothing
	end
	local res, prev = {}, lo -- the first row against the interval's lowest code (0 for unsigned, -2^52 for t.int())
	prev = if lo < 0 then 0 else lo
	local wlo, whi = -math.floor(n / 2), math.ceil(n / 2) - 1
	for i, c in codes do
		local d = c - prev
		if d > whi then d -= n elseif d < wlo then d += n end
		res[i] = zigzag(d)
		prev = c
	end
	local best -- { cost, mode, k }
	local function consider(cost, mode, k)
		if not best or cost < best[1] then
			best = { cost, mode, k }
		end
	end
	local allZero = true
	for _, z in res do
		if z ~= 0 then allZero = false end
	end
	if allZero then consider(2, 0, 0) end
	for k = 0, 15 do
		local c = 2 + 4
		for _, z in res do c += egbits(z, k) end
		consider(c, 1, k)
	end
	for k = 0, 15 do
		local m, c, last = 0, 2 + 4, 0
		for i, z in res do
			if z ~= 0 then
				m += 1
				c += eg0bits(i - 1 - last) + egbits(z - 1, k)
				last = i
			end
		end
		consider(c + eg0bits(m), 2, k)
	end
	local mn, mx = math.huge, 0
	for _, z in res do mn = math.min(mn, z); mx = math.max(mx, z) end
	local width = bitlen(mx - mn)
	consider(2 + eg0bits(mn) + 6 + #res * width, 3, 0)
	local mode, k = best[2], best[3]
	w:u(2, mode)
	if mode == 1 then
		w:u(4, k)
		for _, z in res do w:eg(z, k) end
	elseif mode == 2 then
		w:u(4, k)
		local nz = {}
		for i, z in res do if z ~= 0 then table.insert(nz, i) end end
		w:eg0(#nz)
		local last = 0
		for _, i in nz do
			w:eg0(i - 1 - last); w:eg(res[i] - 1, k); last = i
		end
	elseif mode == 3 then
		w:eg0(mn); w:u(6, width)
		for _, z in res do w:u(width, z - mn) end
	end
	return best
end

-- arena (§3.4), seed 0, identity permutation, namespace index 1. Id spaces by name (§4.6):
-- up: buy(ask) 0, chat 1, strike 2 -> 2 bits; down: announce 0, buy(answer) 1 -> 1 bit.
local UP, DOWN, upW, downW = { buy = 0, chat = 1, strike = 2 }, { announce = 0, buy = 1 }, 2, 1

-- G1: EG-0 of 0, 1, 2, 3, 7 and EG-2 of 5
do
	for _, x in { 0, 1, 2, 3, 7 } do
		local w = writer(); w:eg0(x)
		local bits = {}
		for i = 0, w.pos - 1 do table.insert(bits, tostring(buffer.readbits(w.b, i, 1))) end
		print(string.format("G1 EG-0(%d) stream bits: %s", x, table.concat(bits)))
	end
	local w = writer(); w:eg(5, 2)
	local bits = {}
	for i = 0, w.pos - 1 do table.insert(bits, tostring(buffer.readbits(w.b, i, 1))) end
	print("G1 EG-2(5) stream bits: " .. table.concat(bits))
end
-- G2: down reliable, first reliable frame ('11'), T = 0, announce:fire(all, {kind="round", number=3})
do
	local w = writer()
	w:bit(1); w:bit(1); w:u(16, 0)
	w:eg0(0); w:eg0(1); w:eg0(1); w:eg0(0); w:eg0(0)
	w:align()
	w:u(downW, DOWN.announce); w:eg0(0)
	w:u(1, 0); w:u(7, 2)
	print("G2 ", hex(bytesOf(w)))
end
-- G2b: tick '10', one run: {round 3}, {winner "blue"}
do
	local w = writer()
	w:bit(1); w:bit(0)
	w:eg0(0); w:eg0(1); w:eg0(1); w:eg0(0); w:eg0(0)
	w:align()
	w:u(downW, DOWN.announce); w:eg0(1)
	w:u(1, 0); w:u(7, 2)
	w:u(1, 1); w:u(1, 1)
	print("G2b", hex(bytesOf(w)))
end
-- G3: tick '0', answer to buy: slot 0, epoch 0, outcome 0, value 250 (t.int(0, 100000): u17)
do
	local w = writer()
	w:bit(0)
	w:eg0(0); w:eg0(1); w:eg0(1); w:eg0(0); w:eg0(0)
	w:align()
	w:u(downW, DOWN.buy); w:eg0(0)
	w:u(4, 0); w:u(1, 0); w:u(2, 0); w:u(17, 250)
	print("G3 ", hex(bytesOf(w)))
end
-- G4: up reliable chat:fire("gg"), caller 0, ack '0', rcv 0, key 00..07, cover 1024, count 0; G4c: caller 1
for _, caller in { 0, 1 } do
	local w = writer()
	w:u(1, caller); w:bit(0); w:u(8, 0)
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:u(upW, UP.chat); w:eg0(0)
	w:u(8, 2)
	local body = bytesOf(w, "gg")
	print(if caller == 0 then "G4 " else "G4c", hex(body .. tag(key07, 0, 0, body, 0, caller)))
end
-- G5: up unreliable ack-only: seq 0, ack seq 5 with 4 and 3 (received bit i = seq - 1 - i), key 00..07
do
	local w = writer()
	w:u(12, 0); w:u(1, 0)
	w:bit(1); w:u(12, 5); w:u(16, 0b11)
	w:bit(0) -- receipt '0'
	w:eg0(0)
	local body = bytesOf(w)
	print("G5 ", hex(body .. tag(key07, 0, 1, body, 0)))
end
-- G6: schema hash of arena with only chat = event{from="client", data=t.string(200)}
local function str(s) return string.pack("<I2", #s) .. s end
local function num(x) return string.pack("<d", x) end
do
	local s = string.pack("B", 1) .. str("arena") .. string.pack("<I2", 1)
		.. str("chat") .. string.pack("BBB", 1, 1, 1)
		.. string.pack("B", 1) .. string.pack("B", 8) .. num(200)
		.. string.rep("\0", 8) .. string.pack("BBBB", 1, 0, 0, 0) -- ackEveryFrame present, false; sealed, acked absent
	print("G6 serialization", hex(s))
	print("G6 hash         ", hex(halfsiphash(string.rep("\0", 8), s, 2, 4, 8)))
end
-- G7: HELLO frame for arena: untagged up reliable, ack '0', toc: one segment of ns 0 with one chunk;
-- control chunk type 0, count-1 0; row: version 1 (u8), seed 0 (u32), hash low u32, hash high u32, name length u7, tail.
do
	local s = string.pack("B", 1) .. str("arena") .. string.pack("<I2", 1)
		.. str("chat") .. string.pack("BBB", 1, 1, 1)
		.. string.pack("B", 1) .. string.pack("B", 8) .. num(200) .. string.rep("\0", 8) .. string.pack("BBBB", 1, 0, 0, 0)
	local h = halfsiphash(string.rep("\0", 8), s, 2, 4, 8)
	local lo, hi = string.unpack("<I4I4", h)
	local w = writer()
	w:u(1, 0); w:bit(0); w:u(8, 0)
	w:eg0(1); w:eg0(0); w:eg0(0)
	w:u(3, 0); w:eg0(0)
	w:u(8, 1); w:u(32, 0); w:u(32, lo); w:u(32, hi); w:u(32, 0); w:u(1, 1); w:u(7, 5) -- idTableHash 0, path 1
	print("G7 ", hex(bytesOf(w, "arena")), "(hash of the G6 schema)")
end
-- G8: up unreliable, seq 0, ack '0', one run of 4 strike {aim = (0,0,1), target = 5, 6, 7, 7}; key 00..07.
-- Fields by name: aim (two octahedral codes, n = 2048), target (t.int(1, 2^40): code v - 1, n = 2^40).
do
	local w = writer()
	w:u(12, 0); w:u(1, 0); w:bit(0); w:bit(0) -- seq, caller, ack '0', receipt '0'
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:u(upW, UP.strike); w:eg0(3)
	local q = math.floor((0 + 1) / 2 * 2047 + 0.5) -- octahedral of (0, 0, 1): p = (0, 0)
	local m1 = column(w, { q, q, q, q }, 0, 2048)
	local m2 = column(w, { q, q, q, q }, 0, 2048)
	local m3 = column(w, { 4, 5, 6, 6 }, 0, 2 ^ 40)
	local body = bytesOf(w)
	print("G8 ", hex(body .. tag(key07, 0, 1, body, 0)))
	print(string.format("   aim code %d; modes (mode,k,cost): (%d,%d,%d) (%d,%d,%d) (%d,%d,%d)", q,
		m1[2], m1[3], m1[1], m2[2], m2[3], m2[1], m3[2], m3[3], m3[1]))
end
-- G9: t.int() single rows of -2^52 and 2^52 - 1 (the extremes), bit section alone
do
	for _, v in { -(2 ^ 52), 2 ^ 52 - 1 } do
		local w = writer(); w:eg0(zigzag(v))
		print(string.format("G9 t.int() %.0f: zigzag %.0f, %d bits:", v, zigzag(v), w.pos), hex(bytesOf(w)))
	end
end

-- G10: a client's first reliable frame ('11' tick 0) holding the connection's first WELCOME for arena (index 1):
-- layout 0, epoch 1000.5, stateRate 20, delay 25 (D0), key nonce 00..07 (S = 0, so the key itself), tag.cover 1024,
-- permutation nonce 0, callerProbe.callsPerProbe 0, maxProbesPerSecond 0, the two report bits 0, clock.beaconSeconds 0.
do
	local w = writer()
	w:u(1, 1); w:u(1, 1); w:u(16, 0)
	w:eg0(0)
	w:eg0(1); w:eg0(0); w:eg0(0)
	w:eg0(0)
	w:align()
	w:u(3, 1); w:eg0(0)
	w:eg0(1)                                   -- namespace index 1
	w:u(1, 0)                                  -- layout
	local f = buffer.create(8); buffer.writef64(f, 0, 1000.5)
	w:u(32, buffer.readu32(f, 0)); w:u(32, buffer.readu32(f, 4))
	w:u(6, 20)                                 -- stateRate
	w:u(8, math.max(math.ceil(500 / 20), 25))  -- delay D0 = max(ceil(500 / stateRate), 25) units of 4 ms
	w:u(32, 0x03020100); w:u(32, 0x07060504)   -- key nonce
	w:u(15, 1024)                              -- tag.cover
	w:u(32, 0)                                 -- permutation nonce
	w:u(8, 0); w:u(6, 0)                       -- callsPerProbe, maxProbesPerSecond
	w:u(1, 0); w:u(1, 0)                       -- report.checkListenerCaller, report.checkOwnTables
	w:u(4, 0)                                  -- clock.beaconSeconds (tenths)
	print("G10", hex(bytesOf(w)))
end
-- G11: a downstream reliable frame, tick unchanged ('0'), holding one MISMATCH (unchanged from draft 3.5).
do
	local w = writer()
	w:u(1, 0)
	w:eg0(0); w:eg0(1); w:eg0(0); w:eg0(0); w:eg0(0)
	w:align()
	w:u(3, 2); w:eg0(0)
	print("G11", hex(bytesOf(w)))
end
-- Woven fixture (weave.ids = "site"): up space buy 0, chat 1, strike 2, then sites in canonical order:
-- StarterPlayer.StarterPlayerScripts.Chat line 5 (chat, variable) -> 3; StarterPlayer.StarterPlayerScripts.Shop
-- line 12 (buy { item = "sword" }, fully literal) -> 4. Width 3 bits. Count 0, key 00..07, cover 1024.
do
	local w = writer()
	w:u(1, 0); w:bit(0); w:u(8, 0)
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:u(3, 3); w:eg0(0)
	w:u(8, 2)
	local body = bytesOf(w, "gg")
	print("W1 ", hex(body .. tag(key07, 0, 0, body, 0)), "(chat site, \"gg\")")
	w = writer()
	w:u(1, 0); w:bit(0); w:u(8, 0)
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:u(3, 4); w:eg0(0)
	w:u(4, 0); w:u(1, 0)                       -- ask row: slot 0, epoch 0; no payload bits
	body = bytesOf(w)
	print("W2 ", hex(body .. tag(key07, 0, 0, body, 0)), "(literal buy site, slot 0)")
end
-- Shared helpers for the blocks below.
local function u32le(x) return string.pack("<I4", x % 2 ^ 32) end
local function h24x64(key8, msg) return halfsiphash(key8, msg, 2, 4, 8) end
local function xorshift(state)
	local x = state
	return function()
		x = bit32.bxor(x, bit32.lshift(x, 13)); x = bit32.bxor(x, bit32.rshift(x, 17)); x = bit32.bxor(x, bit32.lshift(x, 5))
		return x
	end
end
-- v5.md section 4.5's permutation: space key K = H24/64 under S over (nonce || 02 || hashLow u32le || space u8);
-- Fisher-Yates from the last index down, j = H13/32(K, i u32le) mod (i + 1). Nonce 0 is the identity.
local function permutation(S8, nonce4, hashLow, space, count)
	local p = {}
	for i = 0, count - 1 do p[i] = i end
	if nonce4 == "\0\0\0\0" then return p end
	local K = h24x64(S8, nonce4 .. "\2" .. u32le(hashLow) .. string.char(space))
	for i = count - 1, 1, -1 do
		local j = string.unpack("<I4", halfsiphash(K, u32le(i), 1, 3, 4)) % (i + 1)
		p[i], p[j] = p[j], p[i]
	end
	return p, K
end
-- PERM: zero S (the runtime path), permutation nonce 0x12345678 (bytes 78 56 34 12), hash low 0x158b86ab, up space,
-- 5 ids: wire id of canonical id 0..4.
do
	local p = permutation(string.rep("\0", 8), u32le(0x12345678), 0x158b86ab, 1, 5)
	local out = {}
	for i = 0, 4 do table.insert(out, string.format("%02x", p[i])) end
	print("PERM", table.concat(out, " "))
end
-- DERIVE: S = 00..07; key nonce 08..0f -> key = H24/64(S, nonce || 01); permutation nonce 10 11 12 13, hash low 0,
-- up space -> space key K; layout seed = H24/64(zero key, permutation nonce || "layout").
do
	local key = h24x64(key07, "\8\9\10\11\12\13\14\15" .. "\1")
	local _, K = permutation(key07, "\16\17\18\19", 0, 1, 2)
	local L = h24x64(string.rep("\0", 8), "\16\17\18\19" .. "layout")
	print("DERIVE key", hex(key), "K_up", hex(K), "layout seed", hex(L))
end
-- ROT: G8's message (one unreliable run of four strike, aim = (0, 0, 1), target 5, 6, 7, 7) at rotationSeed
-- 0x0123456789abcdef, with v5-integrity.md section 2.2's draws: streams seeded with the low 32 bits of
-- H24/64(rotationSeed as two u32le, label), 0 -> 0x9E3779B9; field order (Fisher-Yates over name order, j = x mod
-- (i + 1)); offsets c = x mod n, consecutive outputs in write order; tag constants the first two outputs of "tag";
-- S = v64("session"); key = H24/64(S, key nonce 00..07 || 01). Seq 0, caller 0, ack '0', receipt '0', cover 1024.
do
	local R = string.pack("<I4I4", 0x89abcdef, 0x01234567)
	local function stream(label)
		local seed = string.unpack("<I4", h24x64(R, label))
		if seed == 0 then seed = 0x9E3779B9 end
		return xorshift(seed)
	end
	local fields = { "aim", "target" }
	local ord = stream("order:arena.strike.data")
	for i = #fields - 1, 1, -1 do
		local j = ord() % (i + 1)
		fields[i + 1], fields[j + 1] = fields[j + 1], fields[i + 1]
	end
	local aimS = stream("offset:arena.strike.data.aim")
	local cA1, cA2 = aimS() % 2048, aimS() % 2048
	local cT = stream("offset:arena.strike.data.target")() % 2 ^ 40
	local tg = stream("tag")
	local c0, c1 = tg(), tg()
	local S = h24x64(R, "session")
	if S == string.rep("\0", 8) then S = "\1\0\0\0\0\0\0\0" end
	local key = h24x64(S, key07 .. "\1")
	local q = math.floor((0 + 1) / 2 * 2047 + 0.5)
	local w = writer()
	w:u(12, 0); w:u(1, 0); w:bit(0); w:bit(0)
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:u(upW, UP.strike); w:eg0(3)
	for _, f in fields do
		if f == "aim" then
			local a1, a2 = (q + cA1) % 2048, (q + cA2) % 2048
			column(w, { a1, a1, a1, a1 }, 0, 2048)
			column(w, { a2, a2, a2, a2 }, 0, 2048)
		else
			local t = {}
			for _, v in { 5, 6, 7, 7 } do table.insert(t, (v - 1 + cT) % 2 ^ 40) end
			column(w, t, 0, 2 ^ 40)
		end
	end
	local body = bytesOf(w)
	print("ROT", hex(body .. tag(key, 0, 1, body, 0, 0, c0, c1)))
	print(string.format("    order %s, %s; offsets aim %d %d, target %.0f; constants %08x %08x; S %s; key %s",
		fields[1], fields[2], cA1, cA2, cT, c0, c1, hex(S), hex(key)))
end
-- Strings fixture (v5.md section 4.11): namespace "feed", index 1, identity build and permutation:
--   names = Lync.strings({ maxEntries = 64 })  -- w 6, m 20, maxBytes 64 x 20 = 1280, L 5
--   kill  = Lync.event({ from = "server", data = { killer = t.string(20):intern(names), victim = t.string(20):intern(names) } })
--   taunt = Lync.event({ from = "client", data = { to = t.string(20):intern(names) } })
-- Down space: kill 0 (0 bits); up space: taunt 0 (0 bits). Entry ids pinned: "Builderman" 5, "Zippy" 17.
do
	local IDW, LENW = 6, 5
	local function internStr(maxB) return string.pack("B", 27) .. str("names") .. string.pack("B", 8) .. num(maxB) end
	local function rec(fs)
		local r = string.pack("B", 23) .. string.pack("<I2", #fs)
		for _, f in fs do r ..= str(f[1]) .. f[2] .. string.pack("BB", 0, 0) end
		return r
	end
	-- options after data: reply, key, limit.perSecond, limit.burst, timeout, maxRecords, priority, reliableRate absent;
	-- ackEveryFrame: absent for a server-sent event, present false for a client-sent one; sealed absent (omitted);
	-- acked absent (events don't take it).
	local s0 = string.pack("B", 1) .. str("feed") .. string.pack("<I2", 3)
		.. str("kill") .. string.pack("BBB", 1, 2, 1) .. string.pack("B", 1)
		.. rec({ { "killer", internStr(20) }, { "victim", internStr(20) } }) .. string.rep("\0", 8) .. "\0" .. "\0" .. "\0"
		.. str("names") .. string.pack("B", 4) .. num(64) .. num(1280)
		.. str("taunt") .. string.pack("BBB", 1, 1, 1) .. string.pack("B", 1)
		.. rec({ { "to", internStr(20) } }) .. string.rep("\0", 8) .. "\1\0" .. "\0" .. "\0"
	print("S0 serialization", hex(s0))
	print("S0 hash         ", hex(halfsiphash(string.rep("\0", 8), s0, 2, 4, 8)))
	-- S1: down reliable, tick unchanged, kill:fire(all, { killer = "Builderman", victim = "Zippy" }) to a client
	-- holding neither: namespace 0's state segment with one strings chunk (ns 1, table names: count 2, ids 5, 17
	-- ascending), then the run of two references. S1b: the same to a client holding both.
	for _, holding in { false, true } do
		local w = writer()
		w:bit(0)
		if holding then w:eg0(0) else w:eg0(1); w:eg0(0); w:eg0(0) end
		w:eg0(1); w:eg0(1); w:eg0(0)
		w:eg0(0)
		w:align()
		local tl = ""
		if not holding then
			w:eg0(1); w:eg0(2); w:u(IDW, 5); w:u(LENW, 10); w:u(IDW, 17); w:u(LENW, 5)
			w:align()
			tl = "Zippy" .. "Builderman"
		end
		w:eg0(0)
		w:bit(1); w:u(IDW, 5); w:bit(1); w:u(IDW, 17)
		print(if holding then "S1b" else "S1 ", hex(bytesOf(w, tl)))
	end
	-- S2: up reliable, count 0, rcv 1: taunt:fire({ to = "Zippy" }), a reference to 17; S3: to = "Nobody", a literal.
	for _, case in { { "S2", "Zippy" }, { "S3", "Nobody" } } do
		local w = writer()
		w:u(1, 0); w:bit(0); w:u(8, 1)
		w:eg0(1); w:eg0(1); w:eg0(0)
		w:eg0(0)
		local tl = ""
		if case[2] == "Zippy" then w:bit(1); w:u(IDW, 17) else w:bit(0); w:u(LENW, #case[2]); tl = case[2] end
		local body = bytesOf(w, tl)
		print(case[1], hex(body .. tag(key07, 0, 0, body, 0, 0)))
	end
end
-- SIZES: forced control-only upstream reliable frames (caller, ack '0', rcv), tag included. REPORT has 8 fields:
-- probes, identityMismatches, outerFramesMissing, framesMalformed, listenerCallerMismatches, selfCheckMismatches,
-- selfCheckItem, selfCheckCase.
do
	local function frameBytes(rows: { number }): number
		local bits = 1 + 1 + 8 + eg0bits(1) + eg0bits(0) + eg0bits(#rows - 1)
		for _, r in rows do bits += 3 + eg0bits(0) + r end
		return math.ceil(bits / 8) + 4
	end
	local function rep(t)
		local b = 0
		for _, c in t do b += eg0bits(c) end
		return b
	end
	local one = rep({ 0, 1, 0, 0, 0, 0, 0, 0 })
	local four60 = rep({ 60, 60, 0, 60, 60, 0, 0, 0 })
	local five60 = rep({ 60, 60, 60, 60, 60, 0, 0, 0 })
	local five60self = rep({ 60, 60, 60, 60, 60, 60, 202, 3 })
	print("SIZES REPORT one count 1", frameBytes({ one }), "four counts 60", frameBytes({ four60 }),
		"five counts 60", frameBytes({ five60 }), "BEACON", frameBytes({ 16 }),
		"BEACON+REPORT one", frameBytes({ 16, one }), "BEACON+REPORT four 60", frameBytes({ 16, four60 }),
		"BEACON+REPORT five 60", frameBytes({ 16, five60 }))
	print("SIZES REPORT six counts 60, selfCheckItem 202, selfCheckCase 3", frameBytes({ five60self }),
		"with BEACON", frameBytes({ 16, five60self }))
end
