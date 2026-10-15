-- review-3 p2: golden frames and hashes built only from draft 3's text (v5.md §3.3, §4.1-§4.7).
-- Every place where the text did not decide a bit is marked GUESS and listed in the review.
local W = {}
W.__index = W
local function writer()
	return setmetatable({ b = buffer.create(4096), pos = 0 }, W)
end
function W.u(self, width: number, v: number) -- u(w), LSB first (§4.1); wider than 32: low 32 bits, then the rest
	if width == 0 then
		return
	end
	if width > 32 then
		buffer.writebits(self.b, self.pos, 32, v % 2 ^ 32)
		self.pos += 32
		self:u(width - 32, math.floor(v / 2 ^ 32))
		return
	end
	buffer.writebits(self.b, self.pos, width, v)
	self.pos += width
end
function W.bit(self, v: number)
	self:u(1, v)
end
function W.eg(self, u: number, k: number) -- EG-k (§4.1)
	local v = u + 2 ^ k
	local n = 0
	local t = v
	while t >= 1 do
		t = math.floor(t / 2)
		n += 1
	end
	for _ = 1, n - 1 - k do
		self:bit(0)
	end
	self:bit(1)
	self:u(n - 1, v % 2 ^ (n - 1))
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
	local s = buffer.readstring(w.b, 0, w.pos // 8)
	return s .. (tail or "")
end
local function hex(s: string): string
	return (s:gsub(".", function(c)
		return string.format("%02x ", string.byte(c))
	end))
end

-- HalfSipHash (reference halfsiphash.c), c compression and d finalization rounds, outlen 4 or 8
local function rotl(x, b)
	return bit32.lrotate(x, b)
end
local function halfsiphash(key: string, msg: string, c: number, d: number, outlen: number, iv2: number?, iv3: number?): string
	local function u32(s, i)
		return string.unpack("<I4", s, i)
	end
	local k0, k1 = u32(key, 1), u32(key, 5)
	local v0, v1, v2, v3 = 0, 0, iv2 or 0x6c796765, iv3 or 0x74656462
	v3 = bit32.bxor(v3, k1)
	v2 = bit32.bxor(v2, k0)
	v1 = bit32.bxor(v1, k1)
	v0 = bit32.bxor(v0, k0)
	if outlen == 8 then
		v1 = bit32.bxor(v1, 0xee)
	end
	local function round()
		v0 = (v0 + v1) % 2 ^ 32
		v1 = rotl(v1, 5)
		v1 = bit32.bxor(v1, v0)
		v0 = rotl(v0, 16)
		v2 = (v2 + v3) % 2 ^ 32
		v3 = rotl(v3, 8)
		v3 = bit32.bxor(v3, v2)
		v0 = (v0 + v3) % 2 ^ 32
		v3 = rotl(v3, 7)
		v3 = bit32.bxor(v3, v0)
		v2 = (v2 + v1) % 2 ^ 32
		v1 = rotl(v1, 13)
		v1 = bit32.bxor(v1, v2)
		v2 = rotl(v2, 16)
	end
	local len = #msg
	local full = len - len % 4
	for i = 1, full, 4 do
		local m = u32(msg, i)
		v3 = bit32.bxor(v3, m)
		for _ = 1, c do
			round()
		end
		v0 = bit32.bxor(v0, m)
	end
	local b = bit32.lshift(len % 256, 24)
	for j = 0, len % 4 - 1 do
		b = bit32.bor(b, bit32.lshift(string.byte(msg, full + 1 + j), 8 * j))
	end
	v3 = bit32.bxor(v3, b)
	for _ = 1, c do
		round()
	end
	v0 = bit32.bxor(v0, b)
	v2 = bit32.bxor(v2, if outlen == 8 then 0xee else 0xff)
	for _ = 1, d do
		round()
	end
	local out = string.pack("<I4", bit32.bxor(v1, v3))
	if outlen == 4 then
		return out
	end
	v1 = bit32.bxor(v1, 0xdd)
	for _ = 1, d do
		round()
	end
	return out .. string.pack("<I4", bit32.bxor(v1, v3))
end
local key07 = "\0\1\2\3\4\5\6\7"
print("check: HalfSipHash-2-4/32, key 00..07, empty message:", hex(halfsiphash(key07, "", 2, 4, 4)),
	"(reference vectors_hsip32[0] is a9 35 9f 5b)")

-- The §3.4 example namespace "arena", seed 0, identity permutation.
-- Id spaces (§4.6), name order: up = buy(ask), chat, strike; down = announce, buy(answer).
local UP = { buy = 0, chat = 1, strike = 2 }
local DOWN = { announce = 0, buy = 1 }
local upW, downW = ceilLog2(3), ceilLog2(2)

print("\nG1 EG-0 codes: 0 -> '1', 1 -> '010', 3 -> '00100' (stream order); u(7) of 2 -> 0100000")

-- G2: downstream reliable, first frame after WELCOME, tick T = 0 (GUESS: a client's first reliable frame uses '11'),
-- announce:fire(all, { kind = "round", number = 3 }), namespace index 1.
do
	local w = writer()
	w:bit(1); w:bit(1); w:u(16, 0) -- tick '11' u16
	w:eg(0, 0) -- segs(state): n = 0
	w:eg(1, 0); w:eg(1, 0); w:eg(0, 0) -- segs(run): n = 1; ns = 1, count-1 = 0
	w:eg(0, 0) -- segs(remove): n = 0
	w:align() -- downstream chunks start byte-aligned
	w:u(downW, DOWN.announce); w:eg(0, 0) -- run chunk: id, count-1
	w:u(1, 0) -- union variant index: round (name order: round < winner)
	w:u(ceilLog2(99), 3 - 1) -- t.int(1, 99): u(7) of v - min
	print("G2 down reliable announce round 3:", hex(bytesOf(w)))
end

-- G2b: same frame shape, a run of two announces ({round 3}, {winner "blue"}), tick '10' (+1). Determined by the text.
do
	local w = writer()
	w:bit(1); w:bit(0) -- tick '10'
	w:eg(0, 0); w:eg(1, 0); w:eg(1, 0); w:eg(0, 0); w:eg(0, 0)
	w:align()
	w:u(downW, DOWN.announce); w:eg(1, 0) -- count-1 = 1, under columnMinRows (4): single rows
	w:u(1, 0); w:u(7, 2) -- round 3
	w:u(1, 1); w:u(1, 1) -- winner, team "blue" (list index 1, u1)
	print("G2b down reliable announce x2:    ", hex(bytesOf(w)))
end

-- G3: downstream answer to buy, value 250, slot 0, epoch 0 (GUESS: initial epoch 0), outcome 0, tick '0' unchanged.
do
	local w = writer()
	w:bit(0) -- tick unchanged
	w:eg(0, 0); w:eg(1, 0); w:eg(1, 0); w:eg(0, 0); w:eg(0, 0)
	w:align()
	w:u(downW, DOWN.buy); w:eg(0, 0)
	w:u(4, 0); w:u(1, 0); w:u(2, 0); w:u(17, 250) -- slot, epoch, outcome, reply t.int(0, 100000): u(17)
	print("G3 down reliable answer buy=250:  ", hex(bytesOf(w)))
end

-- G4: upstream reliable chat:fire("gg"), ack '0', key 00..07, tag.cover 1024.
local function tag(key, count, lane, frame, instances)
	local input = string.pack("<I4BI4I2", count % 2 ^ 32, lane, #frame, instances) .. frame:sub(1, 1024)
	return halfsiphash(key, input, 1, 3, 4):sub(1, 2) -- low 16 bits of the 32-bit output, little-endian
end
do
	local w = writer()
	w:bit(0) -- ack '0'
	w:eg(1, 0); w:eg(1, 0); w:eg(0, 0) -- segs(run): n = 1; ns 1, count-1 0
	w:u(upW, UP.chat); w:eg(0, 0) -- upstream chunks are packed: no align
	w:u(ceilLog2(201), 2) -- length of "gg" in u(8)
	local body = bytesOf(w, "gg")
	print("G4 up reliable chat 'gg', count 0:", hex(body .. tag(key07, 0, 0, body, 0)))
	print("   same frame if untagged HELLO frames advance the count (count 1):", hex(body .. tag(key07, 1, 0, body, 0)))
end

-- G5: upstream unreliable ack-only frame: seq 0 (GUESS: first upstream unreliable seq is 0), ack of downstream seq 5
-- with seqs 4 and 3 also received (received bit i = seq 5 - 1 - i: GUESS, the bit order of `received` is not stated).
do
	local w = writer()
	w:u(12, 0) -- seq
	w:bit(1); w:u(12, 5); w:u(16, 0b11) -- ack
	w:eg(0, 0) -- segs(run): n = 0
	local body = bytesOf(w)
	print("G5 up unreliable ack-only:         ", hex(body .. tag(key07, 0, 1, body, 0)))
end

-- G6: schema hash of Lync.schema("arena", { chat = Lync.event({ from = "client", data = t.string(200) }) }).
-- GUESS: codec parameters that §4.7 does not type (string max) are written as `num` (f64).
do
	local function str(s)
		return string.pack("<I2", #s) .. s
	end
	local function num(x)
		return string.pack("<d", x)
	end
	local s = string.pack("B", 1) .. str("arena") .. string.pack("<I2", 1)
		.. str("chat") .. string.pack("BBB", 1, 1, 1)
		.. string.pack("B", 1) .. string.pack("B", 8) .. num(200) -- data: string(200)
		.. string.rep(string.pack("B", 0), 8) -- reply, key, limit.perSecond, limit.burst, timeout, maxRecords, priority, reliableRate
	print("G6 serialization:", hex(s))
	print("G6 hash (HalfSipHash-2-4, zero key, 64-bit, LE):", hex(halfsiphash(string.rep("\0", 8), s, 2, 4, 8)))
end
