-- Design draft 3.2, milestone 2 plan: golden frames G10 (first WELCOME) and G11 (MISMATCH), built from v5.md §4.1
-- and §4.6 with the same writer as golden.luau. Conditions as v5.md §4.10.
local W = {}
W.__index = W
local function writer()
	return setmetatable({ b = buffer.create(256), pos = 0 }, W)
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
local function bitlen(v: number): number
	local n = 0
	while v >= 1 do
		v = math.floor(v / 2)
		n += 1
	end
	return n
end
function W.eg0(self, x: number)
	local z = bitlen(x + 1) - 1
	self:u(z, 0)
	self:u(1, 1)
	self:u(z, (x + 1) - 2 ^ z)
end
function W.align(self)
	self.pos = math.ceil(self.pos / 8) * 8
end
local function hex(w): string
	w:align()
	local s = buffer.readstring(w.b, 0, w.pos // 8)
	return (s:gsub(".", function(c) return string.format("%02x ", string.byte(c)) end))
end
-- G10: a client's first reliable frame ('11' tick 0) holding the connection's first WELCOME for arena (index 1):
-- epoch 1000.5, stateRate 20, key 00..07 (two u32le: 0x03020100, 0x07060504), tag.cover 1024, permutation seed 0,
-- callerProbe.oneIn 0, maxPerSecond 0, clock.beacon 0.
do
	local w = writer()
	w:u(1, 1); w:u(1, 1); w:u(16, 0)          -- tick '11' u16 0
	w:eg0(0)                                   -- segs(state): none
	w:eg0(1); w:eg0(0); w:eg0(0)               -- segs(run): one segment, namespace 0, one chunk
	w:eg0(0)                                   -- segs(remove): none
	w:align()
	w:u(3, 1); w:eg0(0)                        -- control chunk: WELCOME, count 1
	w:eg0(1)                                   -- namespace index 1
	local f = buffer.create(8); buffer.writef64(f, 0, 1000.5)
	w:u(32, buffer.readu32(f, 0)); w:u(32, buffer.readu32(f, 4))   -- epoch f64: low u32, high u32
	w:u(6, 20)                                 -- stateRate
	w:u(32, 0x03020100); w:u(32, 0x07060504)   -- key
	w:u(15, 1024)                              -- tag.cover
	w:u(32, 0)                                 -- permutation seed
	w:u(8, 0); w:u(6, 0); w:u(4, 0)            -- callerProbe.oneIn, maxPerSecond, clock.beacon
	print("G10", hex(w))
end
-- G11: a downstream reliable frame, tick unchanged ('0'), holding one MISMATCH.
do
	local w = writer()
	w:u(1, 0)
	w:eg0(0); w:eg0(1); w:eg0(0); w:eg0(0); w:eg0(0)
	w:align()
	w:u(3, 2); w:eg0(0)
	print("G11", hex(w))
end
