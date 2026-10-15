--!strict
--!optimize 2
-- strings: CPU and heap of downstream string tables and upstream references (research/strings.md).
-- Run by run.sh with Luau 0.742 built from .data/projects/luau, interpreted (-O2) and native (--codegen).
-- Bit fields are read and written through a readu32/writeu32 window (the milestone column coder's addressing),
-- the same reader for every case, so differences between cases are the table work alone.
local H = require("../security-costs/harness")

local W = 12 -- id width: maxEntries 4096
local CAP = 4096
local LEN_W = 5 -- t.string(20): u(5) length
local L = 20

local function make(i: number, len: number): string
	local d = tostring(i)
	return string.rep("n", len - #d) .. d
end

-- vocabulary of 256 distinct 20-byte values, alive in game state (as player names are)
local vocab: { string } = table.create(256)
for i = 1, 256 do vocab[i] = make(i, L) end

------------------------------------------------------------------------------------------------------------------
-- server table: id -> string (array of CAP), string -> id (map), free ids (u16 buffer), random draw
------------------------------------------------------------------------------------------------------------------
-- the CLI has no Roblox `Random`; xorshift32 stands for the server's `Random:NextInteger` (cost not comparable)
local function xorshift(seed: number): (lo: number, hi: number) -> number
	local x = seed
	return function(lo: number, hi: number): number
		x = bit32.bxor(x, bit32.lshift(x, 13)); x = bit32.bxor(x, bit32.rshift(x, 17)); x = bit32.bxor(x, bit32.lshift(x, 5))
		return lo + x % (hi - lo + 1)
	end
end
type Table = { list: { string? }, ids: { [string]: number }, free: buffer, nfree: number, rng: (number, number) -> number, bytes: number }

local function newTable(): Table
	local free = buffer.create(CAP * 2)
	for i = 0, CAP - 1 do buffer.writeu16(free, i * 2, i) end
	return { list = table.create(CAP), ids = {}, free = free, nfree = CAP, rng = xorshift(1), bytes = 0 }
end

local function create(t: Table, s: string): number
	local j = t.rng(0, t.nfree - 1)
	local id = buffer.readu16(t.free, j * 2)
	t.nfree -= 1
	buffer.writeu16(t.free, j * 2, buffer.readu16(t.free, t.nfree * 2))
	t.list[id + 1] = s
	t.ids[s] = id
	t.bytes += #s
	return id
end

local tbl = newTable()
for i = 1, 256 do create(tbl, vocab[i]) end

-- per-viewer held bitsets, CAP bits each
local VIEWERS = 100
local held: { buffer } = table.create(VIEWERS)
for v = 1, VIEWERS do
	local b = buffer.create(CAP // 8)
	for i = 1, 256 do
		local id = tbl.ids[vocab[i]]
		buffer.writeu8(b, id // 8, bit32.bor(buffer.readu8(b, id // 8), bit32.lshift(1, id % 8)))
	end
	held[v] = b
end

local out = buffer.create(2 ^ 20)
local tail = buffer.create(2 ^ 20)

local function wbits(p: number, v: number, w: number): number
	local i = p // 8
	local s = p % 8
	buffer.writeu32(out, i, bit32.bor(bit32.band(buffer.readu32(out, i), bit32.lshift(1, s) - 1), bit32.lshift(v, s)))
	return p + w
end

local function rbits(b: buffer, p: number, w: number): number
	return bit32.extract(buffer.readu32(b, p // 8), p % 8, w)
end

------------------------------------------------------------------------------------------------------------------
-- 1. server encode of one value
------------------------------------------------------------------------------------------------------------------
H.compare("server encode, one t.string(20) value", 200000, {
	{ name = "plain t.string: len + tail", fn = function(m)
		local p, q = 0, 0
		for i = 1, m do
			if p > 7_000_000 then p, q = 0, 0 end
			local s = vocab[i % 256 + 1]
			p = wbits(p, #s, LEN_W)
			buffer.writestring(tail, q, s); q += #s
			if q > 1_000_000 then q = 0 end
		end
		return p
	end },
	{ name = "interned ref, 1 recipient holds", fn = function(m)
		local p = 0
		local hb = held[1]
		for i = 1, m do
			if p > 7_000_000 then p = 0 end
			local s = vocab[i % 256 + 1]
			local id = tbl.ids[s]
			if bit32.btest(buffer.readu8(hb, id // 8), bit32.lshift(1, id % 8)) then
				p = wbits(p, 1 + id * 2, 1 + W)
			end
		end
		return p
	end },
	{ name = "interned ref, 100 recipients hold", fn = function(m)
		local p = 0
		for i = 1, m // 100 + 1 do
			if p > 7_000_000 then p = 0 end
			local s = vocab[i % 256 + 1]
			local id = tbl.ids[s]
			local byte, bit = id // 8, bit32.lshift(1, id % 8)
			local all = true
			for v = 1, VIEWERS do
				if not bit32.btest(buffer.readu8(held[v], byte), bit) then all = false end
			end
			if all then p = wbits(p, 1 + id * 2, 1 + W) end
		end
		return p
	end },
})
print("(the 100-recipient case runs m/100 values: its per-iteration figure is per (value, recipient))")

------------------------------------------------------------------------------------------------------------------
-- 2. entry creation (random free id, map insert, array store)
------------------------------------------------------------------------------------------------------------------
H.compare("server: create one entry (random free id)", 3000, {
	{ name = "map lookup only (miss)", fn = function(m)
		local n = 0
		for i = 1, m do if tbl.ids["zz" .. i] == nil then n += 1 end end
		return n
	end },
	{ name = "create entry", fn = function(m)
		local t = newTable()
		local n = 0
		for i = 1, m do n += create(t, "zz" .. i) end
		return n
	end },
})
print("(both cases build their key with a concatenation; their difference is the creation work)")

------------------------------------------------------------------------------------------------------------------
-- 3. server upstream decode of one value: literal against reference with the held-bit check
------------------------------------------------------------------------------------------------------------------
local up = buffer.create(2 ^ 16)
for i = 0, buffer.len(up) - 1 do buffer.writeu8(up, i, math.random(0, 255)) end
local uptail = buffer.create(L * 256)
for i = 0, buffer.len(uptail) - 1 do buffer.writeu8(uptail, i, 65 + i % 26) end
local idsOf: { number } = table.create(256)
for i = 1, 256 do idsOf[i] = tbl.ids[vocab[i]] end

H.compare("server decode, one upstream t.string(20) value", 200000, {
	{ name = "literal: len + readstring", fn = function(m)
		local s = 0
		for i = 1, m do
			local p = (i % 4096) * 8
			local len = rbits(up, p, LEN_W) % 21
			s += #buffer.readstring(uptail, (i % 236) * L, len)
		end
		return s
	end },
	{ name = "ref: id + held bit + list", fn = function(m)
		local s = 0
		local hb = held[7]
		local list = tbl.list
		for i = 1, m do
			local p = (i % 4096) * 8
			local _ = rbits(up, p, 1)
			local id = idsOf[i % 256 + 1] -- stands for rbits(up, p + 1, W): a valid id
			if not bit32.btest(buffer.readu8(hb, id // 8), bit32.lshift(1, id % 8)) then return -1 end
			s += #(list[id + 1] :: string)
		end
		return s
	end },
})

------------------------------------------------------------------------------------------------------------------
-- 4. client decode: literal, reference, definition
------------------------------------------------------------------------------------------------------------------
local cl: { [number]: string } = {}
local rev: { [string]: number } = {}
for i = 1, 256 do cl[idsOf[i]] = vocab[i]; rev[vocab[i]] = idsOf[i] end
local deftail = buffer.create(L * 4096)
for i = 0, 4095 do buffer.writestring(deftail, i * L, make(100000 + i, L)) end

H.compare("client decode, one t.string(20) value", 200000, {
	{ name = "literal: len + readstring", fn = function(m)
		local s = 0
		for i = 1, m do
			local p = (i % 4096) * 8
			local len = rbits(up, p, LEN_W) % 21
			s += #buffer.readstring(uptail, (i % 236) * L, len)
		end
		return s
	end },
	{ name = "ref: id + held lookup", fn = function(m)
		local s = 0
		for i = 1, m do
			local p = (i % 4096) * 8
			local _ = rbits(up, p, 1)
			local id = idsOf[i % 256 + 1]
			local v = cl[id]
			if v == nil then return -1 end
			s += #v
		end
		return s
	end },
})

H.compare("client: decode one definition (id, len, bytes; checks; store)", 2000, {
	{ name = "readstring only", fn = function(m)
		local s = 0
		for i = 0, m - 1 do s += #buffer.readstring(deftail, (i % 4096) * L, L) end
		return s
	end },
	{ name = "definition, 3 checks + 2 stores", fn = function(m)
		local c: { [number]: string } = {}
		local r: { [string]: number } = {}
		local bytes = 0
		for i = 0, m - 1 do
			local id = (i * 2654435761) % CAP
			if c[id] ~= nil then id = (id + 1) % CAP end -- probe keeps ids distinct in this run
			local v = buffer.readstring(deftail, (i % 4096) * L, L)
			if c[id] ~= nil or r[v] ~= nil or bytes + #v > 1e9 then return -1 end
			c[id] = v; r[v] = id; bytes += #v
		end
		return bytes
	end },
})

------------------------------------------------------------------------------------------------------------------
-- 5. heap
------------------------------------------------------------------------------------------------------------------
local function heap(build: () -> any): number
	collectgarbage("collect")
	local b = collectgarbage("count")
	local keep = build()
	collectgarbage("collect")
	local a = collectgarbage("count")
	assert(keep ~= nil)
	return (a - b) * 1024
end

local N = 1024
local alive: { string } = table.create(N)
for i = 1, N do alive[i] = make(500000 + i, L) end
local ridsSeq: { number } = table.create(N)
local rng = xorshift(3)
local perm = table.create(CAP)
for i = 1, CAP do perm[i] = i - 1 end
for i = CAP, 2, -1 do local j = rng(1, i); perm[i], perm[j] = perm[j], perm[i] end
for i = 1, N do ridsSeq[i] = perm[i] end

print(string.format("## heap, %d entries of 20-byte strings alive elsewhere, ids random in [0, %d)", N, CAP))
print(string.format("client id->string, hash table (random ids):  %7.1f B per entry",
	heap(function() local t = {}; for i = 1, N do t[ridsSeq[i]] = alive[i] end; return t end) / N))
print(string.format("client id->string, table.create(CAP) array:  %7.1f B per entry (%d B total, any fill)",
	heap(function() local t = table.create(CAP); for i = 1, N do t[ridsSeq[i] + 1] = alive[i] end; return t end) / N,
	heap(function() local t = table.create(CAP); for i = 1, N do t[ridsSeq[i] + 1] = alive[i] end; return t end)))
print(string.format("reverse string->id map:                      %7.1f B per entry",
	heap(function() local t = {}; for i = 1, N do t[alive[i]] = ridsSeq[i] end; return t end) / N))
print(string.format("server free-id list (u16 buffer of CAP):     %7.1f B total",
	heap(function() return buffer.create(CAP * 2) end)))
print(string.format("per-viewer held bitset (CAP bits):           %7.1f B per viewer",
	heap(function() return buffer.create(CAP // 8) end)))
print(string.format("strings owned by the table only (20 B):      %7.1f B per string",
	heap(function() local t = table.create(N); for i = 1, N do t[i] = make(900000 + i, L) end; return t end) / N - 16))
print("(the last line subtracts the 16 B array slot measured by R33 for a string alive elsewhere)")
