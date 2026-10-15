--!strict
--!optimize 2
-- M14: the runtime (no-build) path against the generated path, and what per-session parameters cost on it.
-- Uses Lync's own milestone build (git f1fbfd7: src/codec/rows.luau, the runtime interpreter) as exported by
-- run3.sh into WORK_DIR next to this file; srco/ is the same tree with patch_rows.py's offset branches.
-- Forms, per shape, encode and decode of one row:
--   I   Rows.write / Rows.read on the planned IR (the runtime path as built)
--   Ip  the same on a per-session clone of the IR with permuted field order (expected: same cost as I)
--   Io  patched Rows on a per-session clone with permuted order and code offsets
--   C   a closure tree built from the IR at plan time (table-driven, no kind dispatch per value)
--   Co  the closure tree built per session with permuted order and offsets as upvalues
--   Cf  closures with bit positions fixed at plan time and one growth check per row (fixed-width rows only)
--   Cfo Cf built per session with permuted order and offsets
--   G1  straight-line generated encoder on the same Bits writer, seed 0 (what a shard would emit)
--   G1o G1 with order and offsets folded in as constants (the generated path's per-build form)
--   G2  straight-line generated encoder with inline buffer.writebits at constant offsets (fixed-width rows only)
--   nop the harness alone (writer reset and one call), included in every other figure
-- Run (from WORK_DIR): luau -O2 runtime_path.luau   and   luau -O2 --codegen runtime_path.luau

local Lync = require("./src")
local Rows = require("./src/codec/rows")
local RowsO = require("./srco/codec/rows")
local Bits = require("./src/wire/bits")
local HalfSipHash = require("./src/wire/halfsiphash")

local t = Lync.types
local schema = Lync.schema("arena", {
	s3 = Lync.event({ from = "client", data = { ammo = t.int(0, 255), health = t.int(0, 100), team = t.enum({ "red", "blue" }) } }),
	s8 = Lync.event({
		from = "client",
		data = {
			a = t.int(0, 255), b = t.int(0, 100), c = t.bool(), d = t.int(-50, 50),
			e = t.enum({ "n", "e", "s", "w" }), f = t.int(0, 1023), g = t.bool(), h = t.int(0, 7),
		},
	}),
	sm = Lync.event({
		from = "client",
		data = { item = t.enum({ "sword", "bow", "staff" }), name = t.string(32), qty = t.int(1, 99), slot = t.optional(t.int(0, 15)) },
	}),
})
local IR = schema.ir.byName

-- xorshift32 and Fisher-Yates, as v5.md §4.5
local function rng(seed: number)
	local x = if seed == 0 then 0x9E3779B9 else seed
	return function(): number
		x = bit32.bxor(x, bit32.lshift(x, 13)); x = bit32.bxor(x, bit32.rshift(x, 17)); x = bit32.bxor(x, bit32.lshift(x, 5))
		return x
	end
end

-- per-session clone of an IR codec: record fields permuted, bounded codes given an offset
local function variantIr(codec: any, next: () -> number): any
	local kind = codec.kind
	if kind == "record" then
		local fields = table.create(#codec.fields)
		for i, f in codec.fields do fields[i] = { name = f.name, codec = variantIr(f.codec, next), newest = f.newest } end
		for i = #fields, 2, -1 do local j = next() % i + 1; fields[i], fields[j] = fields[j], fields[i] end
		return { kind = "record", fields = fields }
	elseif kind == "int" then
		local n = codec.max - codec.min + 1
		return { kind = "int", min = codec.min, max = codec.max, width = codec.width, n = n, offset = next() % n }
	elseif kind == "enum" then
		local n = #codec.items
		return { kind = "enum", items = codec.items, index = codec.index, width = codec.width, n = n, offset = next() % n }
	elseif kind == "bool" then
		return { kind = "bool", offset = next() % 2 }
	elseif kind == "optional" then
		return { kind = "optional", inner = variantIr(codec.inner, next) }
	end
	return codec
end

local function permOnlyIr(codec: any, next: () -> number): any
	if codec.kind ~= "record" then return codec end
	local fields = table.clone(codec.fields)
	for i = #fields, 2, -1 do local j = next() % i + 1; fields[i], fields[j] = fields[j], fields[i] end
	return { kind = "record", fields = fields }
end

-- closure tree from an IR codec (offsets read from the codec when present)
local write, read = Bits.write, Bits.read
local floor = math.floor
type Enc = (Bits.Writer, any) -> boolean
type Dec = (Bits.Reader) -> (any, number)
local function compile(codec: any): (Enc, Dec)
	local kind = codec.kind
	if kind == "record" then
		local count = #codec.fields
		local names, encs, decs = table.create(count), table.create(count), table.create(count)
		local template = {}
		for i, f in codec.fields do names[i] = f.name; encs[i], decs[i] = compile(f.codec); template[f.name] = false end
		return function(w, v)
			if type(v) ~= "table" then return false end
			for i = 1, count do if not encs[i](w, v[names[i]]) then return false end end
			return true
		end, function(r)
			local rec = table.clone(template)
			for i = 1, count do
				local x, rule = decs[i](r)
				if rule ~= 0 then return nil, rule end
				rec[names[i]] = x
			end
			return rec, 0
		end
	elseif kind == "int" then
		local min, max, width = codec.min, codec.max, codec.width
		local off, n = codec.offset or 0, codec.n or (codec.max - codec.min + 1)
		if off == 0 then
			return function(w, v)
				if type(v) ~= "number" or not (v >= min and v <= max) or floor(v) ~= v then return false end
				write(w, width, v - min); return true
			end, function(r)
				local q = read(r, width)
				if q == nil then return nil, 4 end
				if q > max - min then return nil, 3 end
				return q + min, 0
			end
		end
		local k = n - off
		return function(w, v)
			if type(v) ~= "number" or not (v >= min and v <= max) or floor(v) ~= v then return false end
			local q = v - min
			write(w, width, if q >= k then q - k else q + off); return true
		end, function(r)
			local q = read(r, width)
			if q == nil then return nil, 4 end
			if q >= n then return nil, 3 end
			return (if q < off then q + k else q - off) + min, 0
		end
	elseif kind == "bool" then
		local flip = codec.offset or 0
		return function(w, v)
			if v == true then write(w, 1, bit32.bxor(1, flip)) elseif v == false then write(w, 1, flip) else return false end
			return true
		end, function(r)
			local q = read(r, 1)
			if q == nil then return nil, 4 end
			return q ~= flip, 0
		end
	elseif kind == "enum" then
		local index, items, width = codec.index, codec.items, codec.width
		local off, n = codec.offset or 0, #codec.items
		local k = n - off
		return function(w, v)
			local q = index[v]
			if q == nil then return false end
			write(w, width, if q >= k then q - k else q + off); return true
		end, function(r)
			local q = read(r, width)
			if q == nil then return nil, 4 end
			if q >= n then return nil, 2 end
			return items[(if q < off then q + k else q - off) + 1], 0
		end
	elseif kind == "optional" then
		local ie, id = compile(codec.inner)
		return function(w, v)
			if v == nil then write(w, 1, 0); return true end
			write(w, 1, 1); return ie(w, v)
		end, function(r)
			local p = read(r, 1)
			if p == nil then return nil, 4 end
			if p == 0 then return nil, 0 end
			return id(r)
		end
	elseif kind == "string" then
		local max, width = codec.max, codec.width
		return function(w, v)
			if type(v) ~= "string" or #v > max then return false end
			write(w, width, #v); Bits.writeTail(w, v); return true
		end, function(r)
			local len = read(r, width)
			if len == nil then return nil, 4 end
			if len > max then return nil, 2 end
			local s = Bits.readTail(r, len, false)
			if s == nil then return nil, 4 end
			return s, 0
		end
	end
	error("probe: unsupported kind " .. kind)
end

-- closure tree for fixed-width records of int, bool and enum fields: bit positions computed at plan time,
-- one growth check per row, each field a closure writing at its constant position (table-driven, no loadstring)
local wbits, rbits = buffer.writebits, buffer.readbits
local function compileFixed(codec: any): (Enc, Dec)
	local count = #codec.fields
	local names, fes, fds = table.create(count), table.create(count), table.create(count)
	local template = {}
	local at = 0
	for i, f in codec.fields do
		local c = f.codec
		names[i] = f.name; template[f.name] = false
		local pos = at
		if c.kind == "int" then
			local min, max, width = c.min, c.max, c.width
			local off, n = c.offset or 0, c.n or (c.max - c.min + 1)
			local k = n - off
			fes[i] = function(b: buffer, bit: number, v: any): boolean
				if type(v) ~= "number" or not (v >= min and v <= max) or floor(v) ~= v then return false end
				local q = v - min
				wbits(b, bit + pos, width, if q >= k then q - k else q + off); return true
			end
			fds[i] = function(b: buffer, bit: number): (any, number)
				local q = rbits(b, bit + pos, width)
				if q >= n then return nil, 3 end
				return (if q < off then q + k else q - off) + min, 0
			end
			at += width
		elseif c.kind == "bool" then
			local flip = c.offset or 0
			fes[i] = function(b: buffer, bit: number, v: any): boolean
				if v == true then wbits(b, bit + pos, 1, bit32.bxor(1, flip)) elseif v == false then wbits(b, bit + pos, 1, flip) else return false end
				return true
			end
			fds[i] = function(b: buffer, bit: number): (any, number) return rbits(b, bit + pos, 1) ~= flip, 0 end
			at += 1
		elseif c.kind == "enum" then
			local index, items, width = c.index, c.items, c.width
			local off, n = c.offset or 0, #c.items
			local k = n - off
			fes[i] = function(b: buffer, bit: number, v: any): boolean
				local q = index[v]
				if q == nil then return false end
				wbits(b, bit + pos, width, if q >= k then q - k else q + off); return true
			end
			fds[i] = function(b: buffer, bit: number): (any, number)
				local q = rbits(b, bit + pos, width)
				if q >= n then return nil, 2 end
				return items[(if q < off then q + k else q - off) + 1], 0
			end
			at += width
		else
			error("probe: not fixed width")
		end
	end
	local total = at
	return function(w: Bits.Writer, v: any): boolean
		if type(v) ~= "table" then return false end
		local bit = w.bit
		if (bit + total) // 8 + 4 > buffer.len(w.buf) then write(w, 0, 0) end
		local b = w.buf
		for i = 1, count do if not fes[i](b, bit, v[names[i]]) then return false end end
		w.bit = bit + total
		return true
	end, function(r: Bits.Reader): (any, number)
		local bit = r.bit
		if bit + total > r.stop * 8 then return nil, 4 end
		local b = r.buf
		local rec = table.clone(template)
		for i = 1, count do
			local x, rule = fds[i](b, bit)
			if rule ~= 0 then return nil, rule end
			rec[names[i]] = x
		end
		r.bit = bit + total
		return rec, 0
	end
end

-- generated forms (what lync build would emit), on the same Bits writer
local TEAM = { red = 0, blue = 1 }
local TEAM_ITEMS = { "red", "blue" }
local function g1enc3(w: Bits.Writer, v: any): boolean
	if type(v) ~= "table" then return false end
	local a, h, tm = v.ammo, v.health, TEAM[v.team]
	if type(a) ~= "number" or not (a >= 0 and a <= 255) or floor(a) ~= a then return false end
	if type(h) ~= "number" or not (h >= 0 and h <= 100) or floor(h) ~= h then return false end
	if tm == nil then return false end
	write(w, 8, a); write(w, 7, h); write(w, 1, tm)
	return true
end
local function g1dec3(r: Bits.Reader): (any, number)
	local a = read(r, 8); if a == nil then return nil, 4 end
	local h = read(r, 7); if h == nil then return nil, 4 end
	if h > 100 then return nil, 3 end
	local tm = read(r, 1); if tm == nil then return nil, 4 end
	return { ammo = a, health = h, team = TEAM_ITEMS[tm + 1] }, 0
end
-- order (team, ammo, health), offsets 1, 173, 58
local function g1oenc3(w: Bits.Writer, v: any): boolean
	if type(v) ~= "table" then return false end
	local a, h, tm = v.ammo, v.health, TEAM[v.team]
	if type(a) ~= "number" or not (a >= 0 and a <= 255) or floor(a) ~= a then return false end
	if type(h) ~= "number" or not (h >= 0 and h <= 100) or floor(h) ~= h then return false end
	if tm == nil then return false end
	write(w, 1, bit32.bxor(tm, 1)); write(w, 8, if a >= 83 then a - 83 else a + 173); write(w, 7, if h >= 43 then h - 43 else h + 58)
	return true
end
local function g1odec3(r: Bits.Reader): (any, number)
	local tm = read(r, 1); if tm == nil then return nil, 4 end
	local a = read(r, 8); if a == nil then return nil, 4 end
	local h = read(r, 7); if h == nil then return nil, 4 end
	if h >= 101 then return nil, 3 end
	return { team = TEAM_ITEMS[bit32.bxor(tm, 1) + 1], ammo = if a < 173 then a + 83 else a - 173, health = if h < 58 then h + 43 else h - 58 }, 0
end
local wb, rb = buffer.writebits, buffer.readbits
local function g2enc3(w: Bits.Writer, v: any): boolean
	if type(v) ~= "table" then return false end
	local a, h, tm = v.ammo, v.health, TEAM[v.team]
	if type(a) ~= "number" or not (a >= 0 and a <= 255) or floor(a) ~= a then return false end
	if type(h) ~= "number" or not (h >= 0 and h <= 100) or floor(h) ~= h then return false end
	if tm == nil then return false end
	local bit = w.bit
	if (bit + 16) // 8 + 4 > buffer.len(w.buf) then write(w, 0, 0) end -- growth path (never taken here)
	local b = w.buf
	wb(b, bit, 8, a); wb(b, bit + 8, 7, h); wb(b, bit + 15, 1, tm)
	w.bit = bit + 16
	return true
end
local function g2dec3(r: Bits.Reader): (any, number)
	local bit = r.bit
	if bit + 16 > r.stop * 8 then return nil, 4 end
	local b = r.buf
	local h = rb(b, bit + 8, 7)
	if h > 100 then return nil, 3 end
	r.bit = bit + 16
	return { ammo = rb(b, bit, 8), health = h, team = TEAM_ITEMS[rb(b, bit + 15, 1) + 1] }, 0
end

local DIRS = { n = 0, e = 1, s = 2, w = 3 }
local DIR_ITEMS = { "n", "e", "s", "w" }
local function isInt(x: any, lo: number, hi: number): boolean
	return type(x) == "number" and x >= lo and x <= hi and floor(x) == x
end
local function g1enc8(w: Bits.Writer, v: any): boolean
	if type(v) ~= "table" then return false end
	local a, b, c, d, e, f, g, h = v.a, v.b, v.c, v.d, DIRS[v.e], v.f, v.g, v.h
	if type(a) ~= "number" or not (a >= 0 and a <= 255) or floor(a) ~= a then return false end
	if type(b) ~= "number" or not (b >= 0 and b <= 100) or floor(b) ~= b then return false end
	if type(c) ~= "boolean" then return false end
	if type(d) ~= "number" or not (d >= -50 and d <= 50) or floor(d) ~= d then return false end
	if e == nil then return false end
	if type(f) ~= "number" or not (f >= 0 and f <= 1023) or floor(f) ~= f then return false end
	if type(g) ~= "boolean" then return false end
	if type(h) ~= "number" or not (h >= 0 and h <= 7) or floor(h) ~= h then return false end
	write(w, 8, a); write(w, 7, b); write(w, 1, if c then 1 else 0); write(w, 7, d + 50)
	write(w, 2, e); write(w, 10, f); write(w, 1, if g then 1 else 0); write(w, 3, h)
	return true
end
local function g1dec8(r: Bits.Reader): (any, number)
	local a = read(r, 8); if a == nil then return nil, 4 end
	local b = read(r, 7); if b == nil then return nil, 4 end; if b > 100 then return nil, 3 end
	local c = read(r, 1); if c == nil then return nil, 4 end
	local d = read(r, 7); if d == nil then return nil, 4 end; if d > 100 then return nil, 3 end
	local e = read(r, 2); if e == nil then return nil, 4 end
	local f = read(r, 10); if f == nil then return nil, 4 end
	local g = read(r, 1); if g == nil then return nil, 4 end
	local h = read(r, 3); if h == nil then return nil, 4 end
	return { a = a, b = b, c = c == 1, d = d - 50, e = DIR_ITEMS[e + 1], f = f, g = g == 1, h = h }, 0
end
-- order h, e, a, g, c, f, d, b; offsets a 173, b 58, c 1, d 33, e 3, f 700, g 0, h 5
local function g1oenc8(w: Bits.Writer, v: any): boolean
	if type(v) ~= "table" then return false end
	local a, b, c, d, e, f, g, h = v.a, v.b, v.c, v.d, DIRS[v.e], v.f, v.g, v.h
	if type(a) ~= "number" or not (a >= 0 and a <= 255) or floor(a) ~= a then return false end
	if type(b) ~= "number" or not (b >= 0 and b <= 100) or floor(b) ~= b then return false end
	if type(c) ~= "boolean" then return false end
	if type(d) ~= "number" or not (d >= -50 and d <= 50) or floor(d) ~= d then return false end
	if e == nil then return false end
	if type(f) ~= "number" or not (f >= 0 and f <= 1023) or floor(f) ~= f then return false end
	if type(g) ~= "boolean" then return false end
	if type(h) ~= "number" or not (h >= 0 and h <= 7) or floor(h) ~= h then return false end
	write(w, 3, if h >= 3 then h - 3 else h + 5); write(w, 2, if e >= 1 then e - 1 else e + 3)
	write(w, 8, if a >= 83 then a - 83 else a + 173); write(w, 1, if g then 1 else 0); write(w, 1, if c then 0 else 1)
	write(w, 10, if f >= 324 then f - 324 else f + 700); local dq = d + 50; write(w, 7, if dq >= 68 then dq - 68 else dq + 33)
	write(w, 7, if b >= 43 then b - 43 else b + 58)
	return true
end
local function g1odec8(r: Bits.Reader): (any, number)
	local h = read(r, 3); if h == nil then return nil, 4 end
	local e = read(r, 2); if e == nil then return nil, 4 end
	local a = read(r, 8); if a == nil then return nil, 4 end
	local g = read(r, 1); if g == nil then return nil, 4 end
	local c = read(r, 1); if c == nil then return nil, 4 end
	local f = read(r, 10); if f == nil then return nil, 4 end
	local d = read(r, 7); if d == nil then return nil, 4 end; if d >= 101 then return nil, 3 end
	local b = read(r, 7); if b == nil then return nil, 4 end; if b >= 101 then return nil, 3 end
	return {
		a = if a < 173 then a + 83 else a - 173, b = if b < 58 then b + 43 else b - 58, c = c == 0,
		d = (if d < 33 then d + 68 else d - 33) - 50, e = DIR_ITEMS[(if e < 3 then e + 1 else e - 3) + 1],
		f = if f < 700 then f + 324 else f - 700, g = g == 1, h = if h < 5 then h + 3 else h - 5,
	}, 0
end
local function g2enc8(w: Bits.Writer, v: any): boolean
	if type(v) ~= "table" then return false end
	local a, b, c, d, e, f, g, h = v.a, v.b, v.c, v.d, DIRS[v.e], v.f, v.g, v.h
	if type(a) ~= "number" or not (a >= 0 and a <= 255) or floor(a) ~= a then return false end
	if type(b) ~= "number" or not (b >= 0 and b <= 100) or floor(b) ~= b then return false end
	if type(c) ~= "boolean" then return false end
	if type(d) ~= "number" or not (d >= -50 and d <= 50) or floor(d) ~= d then return false end
	if e == nil then return false end
	if type(f) ~= "number" or not (f >= 0 and f <= 1023) or floor(f) ~= f then return false end
	if type(g) ~= "boolean" then return false end
	if type(h) ~= "number" or not (h >= 0 and h <= 7) or floor(h) ~= h then return false end
	local bit = w.bit
	if (bit + 39) // 8 + 4 > buffer.len(w.buf) then write(w, 0, 0) end
	local buf = w.buf
	wb(buf, bit, 8, a); wb(buf, bit + 8, 7, b); wb(buf, bit + 15, 1, if c then 1 else 0); wb(buf, bit + 16, 7, d + 50)
	wb(buf, bit + 23, 2, e); wb(buf, bit + 25, 10, f); wb(buf, bit + 35, 1, if g then 1 else 0); wb(buf, bit + 36, 3, h)
	w.bit = bit + 39
	return true
end

local ITEMS = { sword = 0, bow = 1, staff = 2 }
local ITEM_NAMES = { "sword", "bow", "staff" }
local function g1encm(w: Bits.Writer, v: any): boolean
	if type(v) ~= "table" then return false end
	local item, name, qty, slot = ITEMS[v.item], v.name, v.qty, v.slot
	if item == nil then return false end
	if type(name) ~= "string" or #name > 32 then return false end
	if type(qty) ~= "number" or not (qty >= 1 and qty <= 99) or floor(qty) ~= qty then return false end
	if slot ~= nil and (type(slot) ~= "number" or not (slot >= 0 and slot <= 15) or floor(slot) ~= slot) then return false end
	write(w, 2, item); write(w, 6, #name); Bits.writeTail(w, name); write(w, 7, qty - 1)
	if slot == nil then write(w, 1, 0) else write(w, 1, 1); write(w, 4, slot) end
	return true
end
local function g1decm(r: Bits.Reader): (any, number)
	local item = read(r, 2); if item == nil then return nil, 4 end; if item >= 3 then return nil, 2 end
	local len = read(r, 6); if len == nil then return nil, 4 end; if len > 32 then return nil, 2 end
	local name = Bits.readTail(r, len, false); if name == nil then return nil, 4 end
	local qty = read(r, 7); if qty == nil then return nil, 4 end; if qty > 98 then return nil, 3 end
	local p = read(r, 1); if p == nil then return nil, 4 end
	local slot = nil
	if p == 1 then slot = read(r, 4); if slot == nil then return nil, 4 end end
	return { item = ITEM_NAMES[item + 1], name = name, qty = qty + 1, slot = slot }, 0
end

-- harness -----------------------------------------------------------------------------------------
local N = 200_000
local ROUNDS = 7
local w = Bits.writer()
local inst = { list = {}, count = 0 } :: any
local function timeEnc(enc: (Bits.Writer, any) -> any, value: any): number
	local best = math.huge
	for _ = 1, ROUNDS do
		local t0 = os.clock()
		for _ = 1, N do
			w.bit = 0; table.clear(w.tail); w.tailBytes = 0
			enc(w, value)
		end
		best = math.min(best, os.clock() - t0)
	end
	return best / N * 1e9
end
local function frameOf(enc: (Bits.Writer, any) -> any, value: any): buffer
	w.bit = 0; table.clear(w.tail); w.tailBytes = 0
	enc(w, value)
	return Bits.finish(w)
end
local function timeDec(dec: (Bits.Reader) -> (any, number), frame: buffer, check: (any) -> boolean): number
	local r = Bits.reader(frame)
	local stop = r.stop
	local v, rule = dec(r)
	assert(rule == 0 and check(v), "probe: decode round trip failed")
	local best = math.huge
	for _ = 1, ROUNDS do
		local t0 = os.clock()
		for _ = 1, N do
			r.bit = 0; r.stop = stop
			dec(r)
		end
		best = math.min(best, os.clock() - t0)
	end
	return best / N * 1e9
end

local chunk = Rows.beginChunk({}, 0, 0)
local misses = {}
local function rowsEnc(codec: any) return function(wr: Bits.Writer, v: any) return Rows.write(wr, codec, v, inst) end end
local function rowsDec(codec: any) return function(r: Bits.Reader) return Rows.read(r, codec, chunk, 1, misses) end end
local function rowsOEnc(codec: any) return function(wr: Bits.Writer, v: any) return RowsO.write(wr, codec, v, inst) end end
local function rowsODec(codec: any) return function(r: Bits.Reader) return RowsO.read(r, codec, chunk, 1, misses) end end

local values = {
	s3 = { ammo = 200, health = 77, team = "blue" },
	s8 = { a = 200, b = 77, c = true, d = -13, e = "s", f = 999, g = false, h = 6 },
	sm = { item = "bow", name = "Aspect", qty = 12, slot = 3 },
}
local function same(x: any, y: any): boolean
	for k, v in y do if x[k] ~= v then return false end end
	for k in x do if y[k] == nil and x[k] ~= false then return false end end
	return true
end
local GEN = {
	s3 = { { "G1", g1enc3, g1dec3 }, { "G1o", g1oenc3, g1odec3 }, { "G2", g2enc3, g2dec3 } },
	s8 = { { "G1", g1enc8, g1dec8 }, { "G1o", g1oenc8, g1odec8 }, { "G2", g2enc8, nil } },
	sm = { { "G1", g1encm, g1decm } },
}

print(string.format("%-4s %-4s %9s %9s", "row", "form", "enc ns", "dec ns"))
for _, name in { "s3", "s8", "sm" } do
	local codec = IR[name].data
	local value = values[name]
	local check = function(v: any) return same(v, value) end
	local sessionIr = variantIr(codec, rng(0x2545F491))
	local permIr = permOnlyIr(codec, rng(0x2545F491))
	local ce, cd = compile(codec)
	local coe, cod = compile(sessionIr)
	local forms: { { any } } = {
		{ "nop", function(_wr: Bits.Writer, _v: any) return true end, nil },
		{ "I", rowsEnc(codec), rowsDec(codec) },
		{ "Ip", rowsEnc(permIr), rowsDec(permIr) },
		{ "Io", rowsOEnc(sessionIr), rowsODec(sessionIr) },
		{ "C", ce, cd },
		{ "Co", coe, cod },
	}
	if name ~= "sm" then
		local fe, fd = compileFixed(codec)
		local foe, fod = compileFixed(sessionIr)
		table.insert(forms, { "Cf", fe, fd })
		table.insert(forms, { "Cfo", foe, fod })
	end
	for _, g in GEN[name] do table.insert(forms, g) end
	for _, f in forms do
		local enc, dec = f[2], f[3]
		local e = timeEnc(enc, value)
		local d = if dec then timeDec(dec, frameOf(enc, value), check) else 0 / 0
		print(string.format("%-4s %-4s %9.1f %9.1f", name, f[1], e, d))
	end
end

-- per-session set-up: clone IR with order and offsets; build closures; memory per definition
local function setupCost(codec: any): (number, number, number)
	local M = 2000
	local t0 = os.clock()
	for i = 1, M do variantIr(codec, rng(i)) end
	local irNs = (os.clock() - t0) / M * 1e9
	t0 = os.clock()
	for i = 1, M do compile(variantIr(codec, rng(i))) end
	local cNs = (os.clock() - t0) / M * 1e9 - irNs
	collectgarbage("collect")
	local keep = table.create(M)
	local k0 = collectgarbage("count")
	for i = 1, M do keep[i] = variantIr(codec, rng(i)) end
	local irB = (collectgarbage("count") - k0) * 1024 / M
	local keep2 = table.create(M)
	k0 = collectgarbage("count")
	for i = 1, M do keep2[i] = { compile(keep[i]) } end
	local cB = (collectgarbage("count") - k0) * 1024 / M
	return irNs, cNs, irB, cB
end
print()
print(string.format("%-4s %14s %14s %12s %12s", "row", "IR clone ns", "closures ns", "IR clone B", "closures B"))
for _, name in { "s3", "s8", "sm" } do
	local a, b, c, d = setupCost(IR[name].data)
	print(string.format("%-4s %14.0f %14.0f %12.0f %12.0f", name, a, b, c, d))
end

-- tag constants as parameters (the runtime path's HalfSipHash already takes iv0, iv1)
print()
local key = buffer.create(8); buffer.writeu32(key, 0, 0x01234567); buffer.writeu32(key, 4, 0x89abcdef)
local msg = buffer.create(1024)
for i = 0, 1023 do buffer.writeu8(msg, i, (i * 37) % 256) end
local IV = { 0x9f3a21c4, 0x0b77e1d3 }
for _, len in { 64, 1024 } do
	local M = if len == 64 then 200_000 else 20_000
	local best0, best1 = math.huge, math.huge
	for _ = 1, ROUNDS do
		local t0 = os.clock()
		for _ = 1, M do HalfSipHash.hash(key, msg, 0, len, 1, 3, 4) end
		best0 = math.min(best0, os.clock() - t0)
		t0 = os.clock()
		for _ = 1, M do HalfSipHash.hash(key, msg, 0, len, 1, 3, 4, IV[1], IV[2]) end
		best1 = math.min(best1, os.clock() - t0)
	end
	print(string.format("HalfSipHash-1-3 %4d B: reference constants %7.2f us, session constants from a table %7.2f us", len, best0 / M * 1e6, best1 / M * 1e6))
end
