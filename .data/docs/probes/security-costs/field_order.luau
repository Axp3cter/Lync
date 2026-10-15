--!strict
-- Claim 1: "Runtime field shuffling costs 2-3x per record write" (v5-changes.md:105, :558; R4).
-- Measures, on one 6-field bit-packed record (78 bits, v5 single-row encoding):
--   encode: generated straight-line seed 0 (baseline); generated with another fixed order (per-build rotation);
--           a per-session/per-player order from a pool of 16 generated encoders, chosen per message or bound
--           once per session; the table-driven runtime path in name order and in a per-session order;
--           a generated read-modify-write encoder with constant offsets, and the same with per-session offsets
--           held as upvalues (any of 720 orders, no pool).
--   decode: the same choices on the server side.
--   bytes:  the original 3-field byte-aligned writeHit (probes/client-security-build/rotation) as straight
--           line, as the original closure-table "runtime" writer, and as straight line with per-session
--           byte offsets.
-- Run: luau -O2 field_order.luau ; luau -O2 --codegen field_order.luau
local H = require("./harness")
local G = require("./field_order_gen")

type Rec = G.Rec
local recs: { Rec } = {}
for i = 1, 64 do
	recs[i] = {
		crit = i % 3 == 0,
		damage = i % 101,
		target = 1 + (i * 977) % 65536,
		x = -2048 + (i * 61.25) % 4096,
		y = (i * 3.5) % 100,
		z = 2047 - (i * 13.75) % 4096,
	}
end

local SIZE = 1048576
local W: G.W = { b = buffer.create(SIZE + 8), pos = 0, acc = 0, n = 0 }
local LIMIT = SIZE - 64

-- check: every generated order decodes what it encodes
do
	for k = 1, #G.encVariants do
		local w2: G.W = { b = buffer.create(256), pos = 0, acc = 0, n = 0 }
		G.encVariants[k](w2, recs[7])
		buffer.writeu32(w2.b, w2.pos, w2.acc)
		local r: any = {}
		assert(G.decVariants[k](w2.b, 0, r) == 78)
		assert(r.crit == recs[7].crit and r.damage == recs[7].damage and r.target == recs[7].target, "order " .. k)
		assert(math.abs(r.x - recs[7].x) <= 1 / 64 and math.abs(r.z - recs[7].z) <= 1 / 64, "order " .. k)
	end
	local b = buffer.create(64)
	local o = G.orders[5]
	local offs, acc = table.create(6, 0), 0
	for _, fi in o do
		offs[fi] = acc
		acc += G.widths[fi]
	end
	local enc = G.makeRmw(offs[1], offs[2], offs[3], offs[4], offs[5], offs[6])
	local dec = G.makeDec(offs[1], offs[2], offs[3], offs[4], offs[5], offs[6])
	enc(b, 3, recs[9])
	local r: any = {}
	assert(dec(b, 3, r) == 81 and r.target == recs[9].target and r.damage == recs[9].damage)
	print("check: 16 pooled orders and the per-session RMW order round-trip")
end

-- table-driven runtime path (what Lync.client(schema) interprets)
type F = { name: string, kind: number, width: number, min: number }
local FL: { F } = {
	{ name = "crit", kind = 1, width = 1, min = 0 },
	{ name = "damage", kind = 2, width = 7, min = 0 },
	{ name = "target", kind = 2, width = 16, min = 1 },
	{ name = "x", kind = 3, width = 18, min = -2048 },
	{ name = "y", kind = 3, width = 18, min = -2048 },
	{ name = "z", kind = 3, width = 18, min = -2048 },
}
local FLperm: { F } = {}
for i, fi in G.orders[5] do
	FLperm[i] = FL[fi]
end
local bor, lshift, rshift = bit32.bor, bit32.lshift, bit32.rshift
local function put(w: G.W, q: number, width: number)
	local n = w.n
	w.acc = bor(w.acc, lshift(q, n))
	n += width
	if n >= 32 then
		buffer.writeu32(w.b, w.pos, w.acc)
		w.pos += 4
		n -= 32
		w.acc = if n > 0 then rshift(q, width - n) else 0
	end
	w.n = n
end
local function encTable(w: G.W, v: any, fl: { F })
	for i = 1, #fl do
		local f = fl[i]
		local k = f.kind
		local q
		if k == 1 then
			q = if v[f.name] then 1 else 0
		elseif k == 2 then
			q = v[f.name] - f.min
		else
			q = (v[f.name] - f.min) * 32 + 0.5
			q -= q % 1
			if q > 131072 then
				q = 131072
			end
		end
		put(w, q, f.width)
	end
end
local function decTable(b: buffer, p: number, r: any, fl: { F }): number
	for i = 1, #fl do
		local f = fl[i]
		local q = bit32.band(rshift(buffer.readu32(b, p // 8), p % 8), 2 ^ f.width - 1)
		p += f.width
		local k = f.kind
		if k == 1 then
			r[f.name] = q == 1
		elseif k == 2 then
			r[f.name] = q + f.min
		else
			if q > 131072 then
				return -1
			end
			r[f.name] = q / 32 + f.min
		end
	end
	return p
end

local session = { variant = 5 } -- per-session index into the pool (from WELCOME)
local enc0, enc1 = G.encAcc_0, G.encAcc_1
local offs, a = table.create(6, 0), 0
for _, fi in G.orders[5] do
	offs[fi] = a
	a += G.widths[fi]
end
local rmwS = G.makeRmw(offs[1], offs[2], offs[3], offs[4], offs[5], offs[6])
local decS = G.makeDec(offs[1], offs[2], offs[3], offs[4], offs[5], offs[6])
local rmw0 = G.encRmw_0

local function reset()
	W.pos, W.acc, W.n = 0, 0, 0
end

local N = 400000
H.compare("encode one 78-bit record", N, {
	{ name = "gen seed0 (straight line)", fn = function(n)
		reset()
		for i = 1, n do
			enc0(W, recs[i % 64 + 1])
			if W.pos > LIMIT then reset() end
		end
		return W.pos
	end },
	{ name = "gen rotated (per-build order)", fn = function(n)
		reset()
		for i = 1, n do
			enc1(W, recs[i % 64 + 1])
			if W.pos > LIMIT then reset() end
		end
		return W.pos
	end },
	{ name = "gen pool, lookup per message", fn = function(n)
		reset()
		local vs = G.encVariants
		for i = 1, n do
			vs[session.variant](W, recs[i % 64 + 1])
			if W.pos > LIMIT then reset() end
		end
		return W.pos
	end },
	{ name = "gen pool, bound per session", fn = function(n)
		reset()
		local e = G.encVariants[session.variant]
		for i = 1, n do
			e(W, recs[i % 64 + 1])
			if W.pos > LIMIT then reset() end
		end
		return W.pos
	end },
	{ name = "table-driven, name order", fn = function(n)
		reset()
		for i = 1, n do
			encTable(W, recs[i % 64 + 1], FL)
			if W.pos > LIMIT then reset() end
		end
		return W.pos
	end },
	{ name = "table-driven, per-session order", fn = function(n)
		reset()
		for i = 1, n do
			encTable(W, recs[i % 64 + 1], FLperm)
			if W.pos > LIMIT then reset() end
		end
		return W.pos
	end },
	{ name = "gen RMW, constant offsets", fn = function(n)
		local b, p = W.b, 0
		for i = 1, n do
			p = rmw0(b, p, recs[i % 64 + 1])
			if p > LIMIT * 8 then p = 0; buffer.fill(b, 0, 0) end
		end
		return p
	end },
	{ name = "gen RMW, per-session offsets", fn = function(n)
		local b, p = W.b, 0
		for i = 1, n do
			p = rmwS(b, p, recs[i % 64 + 1])
			if p > LIMIT * 8 then p = 0; buffer.fill(b, 0, 0) end
		end
		return p
	end },
})

-- decode: fill a buffer with rows in order 0 and in order 5 (accumulator layout), then read them back
local ROWS = 4096
local function fill(enc: (G.W, Rec) -> ()): buffer
	local w: G.W = { b = buffer.create(ROWS * 10 + 16), pos = 0, acc = 0, n = 0 }
	for i = 1, ROWS do
		enc(w, recs[i % 64 + 1])
	end
	buffer.writeu32(w.b, w.pos, w.acc)
	return w.b
end
local b0 = fill(G.encAcc_0)
local b5 = fill(G.encVariants[session.variant])
local dec0 = G.decPos_0
local r: any = { crit = false, damage = 0, target = 0, x = 0, y = 0, z = 0 }
local function rowsLoop(n: number, b: buffer, d: (buffer, number, any) -> number): number
	local p, s = 0, 0
	for i = 1, n do
		if i % ROWS == 1 then p = 0 end
		p = d(b, p, r)
		s += p
	end
	return s
end
H.compare("decode one 78-bit record (server, per player)", N, {
	{ name = "gen seed0", fn = function(n) return rowsLoop(n, b0, dec0) end },
	{ name = "gen pool, lookup per message", fn = function(n)
		local ds = G.decVariants
		local p, s = 0, 0
		for i = 1, n do
			if i % ROWS == 1 then p = 0 end
			p = ds[session.variant](b5, p, r)
			s += p
		end
		return s
	end },
	{ name = "gen per-session offsets (closure)", fn = function(n) return rowsLoop(n, b5, decS) end },
	{ name = "table-driven, per-session order", fn = function(n)
		local p, s = 0, 0
		for i = 1, n do
			if i % ROWS == 1 then p = 0 end
			p = decTable(b5, p, r, FLperm)
			s += p
		end
		return s
	end },
})

-- the original probe's record: 3 byte-aligned fields (target u16, damage u16, crit u8)
type Hit = { target: number, damage: number, crit: boolean }
local hits: { Hit } = {}
for i = 1, 64 do
	hits[i] = { target = i * 7, damage = i % 100, crit = i % 2 == 0 }
end
local function writeHit(b: buffer, o: number, v: Hit): number
	buffer.writeu16(b, o, v.target)
	buffer.writeu16(b, o + 2, v.damage)
	buffer.writeu8(b, o + 4, if v.crit then 1 else 0)
	return o + 5
end
local writers: { [string]: (buffer, number, any) -> number } = {
	target = function(b, o, v) buffer.writeu16(b, o, v.target); return o + 2 end,
	damage = function(b, o, v) buffer.writeu16(b, o, v.damage); return o + 2 end,
	crit = function(b, o, v) buffer.writeu8(b, o, if v.crit then 1 else 0); return o + 1 end,
}
local order = { "damage", "crit", "target" }
local function writeHitRuntime(b: buffer, o: number, v: any): number
	for _, field in order do
		o = writers[field](b, o, v)
	end
	return o
end
local function makeHit(ot: number, od: number, oc: number): (buffer, number, Hit) -> number
	return function(b, o, v)
		buffer.writeu16(b, o + ot, v.target)
		buffer.writeu16(b, o + od, v.damage)
		buffer.writeu8(b, o + oc, if v.crit then 1 else 0)
		return o + 5
	end
end
local hitS = makeHit(3, 0, 2)
local hb = buffer.create(SIZE + 8)
local function hloop(n: number, f: (buffer, number, Hit) -> number): number
	local o = 0
	for i = 1, n do
		o = f(hb, o, hits[i % 64 + 1])
		if o > LIMIT then o = 0 end
	end
	return o
end
H.compare("encode 3-field byte record (original writeHit)", N, {
	{ name = "straight line (seed 0)", fn = function(n) return hloop(n, writeHit) end },
	{ name = "closure table (original runtime)", fn = function(n) return hloop(n, writeHitRuntime) end },
	{ name = "straight line, per-session offsets", fn = function(n) return hloop(n, hitS) end },
})
print("sink", H.sink)
