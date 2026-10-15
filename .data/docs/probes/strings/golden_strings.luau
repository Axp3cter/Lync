--!nocheck
-- strings golden vectors (research/strings.md §8): frames under the proposed strings grammar.
-- Helpers (writer, EG-0, HalfSipHash, tag) copied unchanged from probes/design-3.6/golden_wire.luau lines 10-127.
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
local function tag(key, count, lane, frame, instances, caller)
	local input = string.pack("<I4BI4I2", count % 2 ^ 32, lane + 128 * (caller or 0), #frame, instances) .. frame:sub(1, 1024)
	return halfsiphash(key, input, 1, 3, 4) -- draft 3.5: the full 32-bit output
end

-- Column encoder (v5.md §4.3). codes: array of integers in [lo, lo + n - 1]. Returns the cheapest encoding.

local function str(s) return string.pack("<I2", #s) .. s end
local function num(x) return string.pack("<d", x) end

-- Fixture namespace "feed", index 1, identity build (S = 0, no offsets, layout 0), identity permutation:
--   names = Lync.strings({ maxEntries = 64 })            -- w = 6; m = 20, so maxBytes defaults to 64 x 20 = 1280
--   kill  = Lync.event({ from = "server", data = { killer = t.string(20):intern(names), victim = t.string(20):intern(names) } })
--   taunt = Lync.event({ from = "client", data = { to = t.string(20):intern(names) } })
-- Down space: kill 0 (0 bits); up space: taunt 0 (0 bits). Entry ids, pinned by the test seam's Random:
--   "Builderman" -> 5, "Zippy" -> 17.
local IDW, LENW = 6, 5

-- S0: schema serialization and hash. Definitions in name order: kill (event), names (strings table, kind 4:
-- name, kind, maxEntries num, maxBytes num; no from, lane or option list), taunt (event).
do
	local function internStr(maxB) return string.pack("B", 27) .. str("names") .. string.pack("B", 8) .. num(maxB) end
	local function rec(fields) -- record: type 23, count u16, per field name, codec, newest u8, visibility u8
		local s = string.pack("B", 23) .. string.pack("<I2", #fields)
		for _, f in fields do s ..= str(f[1]) .. f[2] .. string.pack("BB", 0, 0) end
		return s
	end
	local tailOpts = string.rep("\0", 8) .. string.pack("BBB", 1, 0, 0) -- 8 absent options, perceived false, sealed absent
	local s = string.pack("B", 1) .. str("feed") .. string.pack("<I2", 3)
		.. str("kill") .. string.pack("BBB", 1, 2, 1) .. string.pack("B", 1)
		.. rec({ { "killer", internStr(20) }, { "victim", internStr(20) } }) .. tailOpts
		.. str("names") .. string.pack("B", 4) .. num(64) .. num(1280)
		.. str("taunt") .. string.pack("BBB", 1, 1, 1) .. string.pack("B", 1)
		.. rec({ { "to", internStr(20) } }) .. tailOpts
	print("S0 serialization", hex(s))
	print("S0 hash         ", hex(halfsiphash(string.rep("\0", 8), s, 2, 4, 8)))
end

-- S1: down reliable, tick unchanged ('0'): kill:fire(Lync.all, { killer = "Builderman", victim = "Zippy" }) to a
-- client holding neither entry. toc: segs(state) n 1 { ns 0, count-1 0 } (namespace 0's state segment holds
-- strings chunks), segs(run) n 1 { ns 1, count-1 0 }, segs(remove) n 0. Chunks: the strings chunk (ns EG0 1; table
-- names: count EG0 2, then id u6, len u5 per definition, ascending ids), then the run (id u0, count-1 0, killer
-- entry 1 id 5, victim entry 1 id 17).
-- Tail: chunk segments in reverse chunk order, values in reverse decode order: "Zippy" then "Builderman".
do
	local w = writer()
	w:bit(0)
	w:eg0(1); w:eg0(0); w:eg0(0)
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:eg0(0)
	w:align()
	w:eg0(1); w:eg0(2); w:u(IDW, 5); w:u(LENW, 10); w:u(IDW, 17); w:u(LENW, 5)
	w:align()
	w:eg0(0)
	w:bit(1); w:u(IDW, 5); w:bit(1); w:u(IDW, 17)
	print("S1 ", hex(bytesOf(w, "Zippy" .. "Builderman")))
end
-- S1b: the same fire to a client holding both entries: no state segment, refs only.
do
	local w = writer()
	w:bit(0)
	w:eg0(0)
	w:eg0(1); w:eg0(1); w:eg0(0)
	w:eg0(0)
	w:align()
	w:eg0(0)
	w:bit(1); w:u(IDW, 5); w:bit(1); w:u(IDW, 17)
	print("S1b", hex(bytesOf(w)))
end
-- S2: up reliable, count 0, caller 0, ack '0', rcv 1: taunt:fire({ to = "Zippy" }) from a client holding id 17.
-- S3: the same with to = "Nobody", which the client holds no entry for: entry 0, len u5 6, bytes in the tail.
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
