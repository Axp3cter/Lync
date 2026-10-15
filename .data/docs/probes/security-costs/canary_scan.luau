--!strict
-- Claim 10: "Canary scan up to 256 B: up to scanBytes - 11 lookups per longer inbound value, per-offset cost
-- measured in milestone 5" (v5-integrity.md §9, v5-changes.md:553). 1024 live canaries (12 chars of
-- [A-Za-z0-9]) in one server-wide map. Per inbound string of L bytes, every offset 0 .. L - 12 is searched:
--   sub + map        : string.sub of 12 bytes per offset, then the map lookup (what "a lookup per offset" means)
--   rolling u32 key  : a 4-byte window key rolled one string.byte per offset; a number-keyed map of canary
--                      prefixes; a full 12-byte compare only on a prefix hit
--   fromstring + u32 : buffer.fromstring once per value, then readu32 per offset and the prefix map
--   + bitset filter  : as above, with a 64 Kbit bitset of prefix low 16 bits tested before the prefix map
--   buffer input     : a t.buffer value: readu32 per offset, bitset, prefix map (no conversion)
-- Every case must find the one planted canary in the "hit" input and nothing in the "miss" input.
-- Run: luau -O2 canary_scan.luau ; luau -O2 --codegen canary_scan.luau
local H = require("./harness")
local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local seed = 99
local function rnd(n: number): number
	seed = (seed * 48271) % 2147483647
	return seed % n
end
local function canary(): string
	local t = table.create(12, "")
	for i = 1, 12 do
		local k = rnd(62) + 1
		t[i] = string.sub(ALPHA, k, k)
	end
	return table.concat(t)
end
local NC = 1024
local map: { [string]: number } = {}
local prefix: { [number]: { string } } = {}
local bits = buffer.create(8192)
local list = table.create(NC, "")
for slot = 1, NC do
	local c = canary()
	list[slot] = c
	map[c] = slot
	local p = string.byte(c, 1) + string.byte(c, 2) * 256 + string.byte(c, 3) * 65536 + string.byte(c, 4) * 16777216
	local l = prefix[p]
	if l then table.insert(l, c) else prefix[p] = { c } end
	local lo = band(p, 0xffff)
	buffer.writeu8(bits, lo // 8, bor(buffer.readu8(bits, lo // 8), lshift(1, lo % 8)))
end

local function scanSub(s: string): number
	for i = 1, #s - 11 do
		local slot = map[string.sub(s, i, i + 11)]
		if slot then return slot end
	end
	return 0
end
local function scanRoll(s: string): number
	local n = #s
	local b1, b2, b3 = string.byte(s, 1, 3)
	local key = b1 * 256 + b2 * 65536 + b3 * 16777216
	for i = 1, n - 11 do
		key = rshift(key, 8) + string.byte(s, i + 3) * 16777216
		local l = prefix[key]
		if l then
			local sub = string.sub(s, i, i + 11)
			local slot = map[sub]
			if slot then return slot end
		end
	end
	return 0
end
local function scanBuf(b: buffer, n: number): number
	for o = 0, n - 12 do
		local key = buffer.readu32(b, o)
		if prefix[key] then
			local slot = map[buffer.readstring(b, o, 12)]
			if slot then return slot end
		end
	end
	return 0
end
local function scanBufBits(b: buffer, n: number): number
	for o = 0, n - 12 do
		local key = buffer.readu32(b, o)
		local lo = band(key, 0xffff)
		if band(buffer.readu8(bits, rshift(lo, 3)), lshift(1, band(lo, 7))) ~= 0 and prefix[key] then
			local slot = map[buffer.readstring(b, o, 12)]
			if slot then return slot end
		end
	end
	return 0
end

local words = { "gg", "trade", "sword", "anyone", "want", "to", "team", "up", "lol", "nice", "shot", "brb" }
local function chat(L: number): string
	local t = {}
	local len = 0
	while len < L do
		local w = words[rnd(#words) + 1]
		table.insert(t, w)
		len += #w + 1
	end
	return string.sub(table.concat(t, " "), 1, L)
end

for _, L in { 32, 128, 256 } do
	local miss = chat(L)
	local hit = string.sub(miss, 1, L - 12 - 3) .. list[500] .. string.sub(miss, L - 2, L)
	assert(#hit == L)
	local mb, hb = buffer.fromstring(miss), buffer.fromstring(hit)
	for _, f in { scanSub, scanRoll } do
		assert(f(miss) == 0 and f(hit) == 500)
	end
	assert(scanBuf(mb, L) == 0 and scanBuf(hb, L) == 500 and scanBufBits(mb, L) == 0 and scanBufBits(hb, L) == 500)
	local iters = math.max(2000, 2000000 // L)
	local r = H.compare(string.format("scan one inbound %d B string, no canary in it (%d offsets)", L, L - 11), iters, {
		{ name = "sub + map per offset", fn = function(n)
			local s = 0
			for _ = 1, n do s += scanSub(miss) end
			return s
		end },
		{ name = "rolling u32 key + prefix map", fn = function(n)
			local s = 0
			for _ = 1, n do s += scanRoll(miss) end
			return s
		end },
		{ name = "fromstring + readu32 + prefix", fn = function(n)
			local s = 0
			for _ = 1, n do s += scanBuf(buffer.fromstring(miss), L) end
			return s
		end },
		{ name = "fromstring + bitset + prefix", fn = function(n)
			local s = 0
			for _ = 1, n do s += scanBufBits(buffer.fromstring(miss), L) end
			return s
		end },
		{ name = "t.buffer input: bitset + prefix", fn = function(n)
			local s = 0
			for _ = 1, n do s += scanBufBits(mb, L) end
			return s
		end },
	})
	local row = {}
	for name, ns in r do table.insert(row, string.format("%s %.1f ns", name, ns / (L - 11))) end
	table.sort(row)
	print(string.format("per offset at %d B: %s", L, table.concat(row, "; ")))
end
print("sink", H.sink)
