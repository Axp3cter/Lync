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
local function halfsiphash(key: string, msg: string, c: number, d: number, outlen: number): string
	local function u32(s, i)
		return string.unpack("<I4", s, i)
	end
	local k0, k1 = u32(key, 1), u32(key, 5)
	local v0, v1, v2, v3 = k0, k1, bit32.bxor(0x6c796765, k0), bit32.bxor(0x74656462, k1)
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
local function tag(key, count, lane, frame, instances)
	local input = string.pack("<I4BI4I2", count % 2 ^ 32, lane, #frame, instances) .. frame:sub(1, 1024)
	return halfsiphash(key, input, 1, 3, 4):sub(1, 2)
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
-- G4: up reliable chat:fire("gg"), ack '0', key 00..07, cover 1024, count 0
do
	local w = writer()
	w:bit(0)
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:u(upW, UP.chat); w:eg0(0)
	w:u(8, 2)
	local body = bytesOf(w, "gg")
	print("G4 ", hex(body .. tag(key07, 0, 0, body, 0)))
end
-- G5: up unreliable ack-only: seq 0, ack seq 5 with 4 and 3 (received bit i = seq - 1 - i), key 00..07
do
	local w = writer()
	w:u(12, 0)
	w:bit(1); w:u(12, 5); w:u(16, 0b11)
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
		.. string.rep("\0", 8)
	print("G6 serialization", hex(s))
	print("G6 hash         ", hex(halfsiphash(string.rep("\0", 8), s, 2, 4, 8)))
end
-- G7: HELLO frame for arena: untagged up reliable, ack '0', toc: one segment of ns 0 with one chunk;
-- control chunk type 0, count-1 0; row: version 1 (u8), seed 0 (u32), hash low u32, hash high u32, name length u7, tail.
do
	local s = string.pack("B", 1) .. str("arena") .. string.pack("<I2", 1)
		.. str("chat") .. string.pack("BBB", 1, 1, 1)
		.. string.pack("B", 1) .. string.pack("B", 8) .. num(200) .. string.rep("\0", 8)
	local h = halfsiphash(string.rep("\0", 8), s, 2, 4, 8)
	local lo, hi = string.unpack("<I4I4", h)
	local w = writer()
	w:bit(0)
	w:eg0(1); w:eg0(0); w:eg0(0)
	w:u(3, 0); w:eg0(0)
	w:u(8, 1); w:u(32, 0); w:u(32, lo); w:u(32, hi); w:u(7, 5)
	print("G7 ", hex(bytesOf(w, "arena")), "(hash of the G6 schema)")
end
-- G8: up unreliable, seq 0, ack '0', one run of 4 strike {aim = (0,0,1), target = 5, 6, 7, 7}; key 00..07.
-- Fields by name: aim (two octahedral codes, n = 2048), target (t.int(1, 2^40): code v - 1, n = 2^40).
do
	local w = writer()
	w:u(12, 0); w:bit(0)
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
