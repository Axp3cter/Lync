--!strict
-- P1: encode+decode throughput of a 6-field record, three implementation styles.
-- Record: a 0..1023 (10 bits), b 0..63 (6 bits), c -32768..32767 (16 bits) -> one u32 word,
-- f f32, ok bool (u8), name short string (u8 length + bytes). No validation in any variant.
type Rec = { a: number, b: number, c: number, f: number, ok: boolean, name: string }

local ITER = 200000
local RUNS = 15

------------------------------------------------------------------------------------------
-- (a) closure-composed per-field writers/readers driven by arrays (v4 style)
------------------------------------------------------------------------------------------
type Writer = (b: buffer, off: number, v: any) -> number
type Reader = (b: buffer, off: number) -> (any, number)

-- bit accumulator shared by the bits closures (state lives in upvalues)
local acc, accBits, accOff = 0, 0, 0
local function bitsWriter(width: number, bias: number): Writer
	return function(b, off, v)
		if accBits == 0 then
			accOff = off
			off += 4 -- reserve the word
		end
		acc = bit32.bor(acc, bit32.lshift(v + bias, accBits))
		accBits += width
		if accBits >= 32 then
			buffer.writeu32(b, accOff, acc)
			acc, accBits = 0, 0
		end
		return off
	end
end
local rword, rBits = 0, 0
local function bitsReader(width: number, bias: number): Reader
	return function(b, off)
		if rBits == 0 then
			rword = buffer.readu32(b, off)
			off += 4
		end
		local v = bit32.extract(rword, rBits, width) - bias
		rBits += width
		if rBits >= 32 then
			rBits = 0
		end
		return v, off
	end
end
local function f32W(b: buffer, off: number, v: number): number
	buffer.writef32(b, off, v)
	return off + 4
end
local function f32R(b: buffer, off: number): (number, number)
	return buffer.readf32(b, off), off + 4
end
local function boolW(b: buffer, off: number, v: boolean): number
	buffer.writeu8(b, off, if v then 1 else 0)
	return off + 1
end
local function boolR(b: buffer, off: number): (boolean, number)
	return buffer.readu8(b, off) ~= 0, off + 1
end
local function strW(b: buffer, off: number, v: string): number
	local n = #v
	buffer.writeu8(b, off, n)
	buffer.writestring(b, off + 1, v)
	return off + 1 + n
end
local function strR(b: buffer, off: number): (string, number)
	local n = buffer.readu8(b, off)
	return buffer.readstring(b, off + 1, n), off + 1 + n
end

local names = { "a", "b", "c", "f", "ok", "name" }
local writers: { Writer } = { bitsWriter(10, 0), bitsWriter(6, 0), bitsWriter(16, 32768), f32W, boolW, strW }
local readers: { Reader } = { bitsReader(10, 0), bitsReader(6, 0), bitsReader(16, 32768), f32R, boolR, strR }
local count = #names

local function encodeA(b: buffer, off: number, v: Rec): number
	local t = v :: any
	for i = 1, count do
		off = writers[i](b, off, t[names[i]])
	end
	return off
end
local function decodeA(b: buffer, off: number): (Rec, number)
	local out = {}
	for i = 1, count do
		local value
		value, off = readers[i](b, off)
		out[names[i]] = value
	end
	return out :: any, off
end

------------------------------------------------------------------------------------------
-- (b) straight-line specialized code, bit32 word packing (what a generator would emit)
------------------------------------------------------------------------------------------
local function encodeB(b: buffer, off: number, v: Rec): number
	buffer.writeu32(b, off, bit32.bor(v.a, bit32.lshift(v.b, 10), bit32.lshift(v.c + 32768, 16)))
	buffer.writef32(b, off + 4, v.f)
	buffer.writeu8(b, off + 8, if v.ok then 1 else 0)
	local name = v.name
	local n = #name
	buffer.writeu8(b, off + 9, n)
	buffer.writestring(b, off + 10, name)
	return off + 10 + n
end
local function decodeB(b: buffer, off: number): (Rec, number)
	local w = buffer.readu32(b, off)
	local n = buffer.readu8(b, off + 9)
	return {
		a = bit32.band(w, 1023),
		b = bit32.extract(w, 10, 6),
		c = bit32.rshift(w, 16) - 32768,
		f = buffer.readf32(b, off + 4),
		ok = buffer.readu8(b, off + 8) ~= 0,
		name = buffer.readstring(b, off + 10, n),
	}, off + 10 + n
end

------------------------------------------------------------------------------------------
-- (c) as (b) but with buffer.writebits / buffer.readbits for the packed ints
------------------------------------------------------------------------------------------
local function encodeC(b: buffer, off: number, v: Rec): number
	local bit = off * 8
	buffer.writebits(b, bit, 10, v.a)
	buffer.writebits(b, bit + 10, 6, v.b)
	buffer.writebits(b, bit + 16, 16, v.c + 32768)
	buffer.writef32(b, off + 4, v.f)
	buffer.writeu8(b, off + 8, if v.ok then 1 else 0)
	local name = v.name
	local n = #name
	buffer.writeu8(b, off + 9, n)
	buffer.writestring(b, off + 10, name)
	return off + 10 + n
end
local function decodeC(b: buffer, off: number): (Rec, number)
	local bit = off * 8
	local n = buffer.readu8(b, off + 9)
	return {
		a = buffer.readbits(b, bit, 10),
		b = buffer.readbits(b, bit + 10, 6),
		c = buffer.readbits(b, bit + 16, 16) - 32768,
		f = buffer.readf32(b, off + 4),
		ok = buffer.readu8(b, off + 8) ~= 0,
		name = buffer.readstring(b, off + 10, n),
	}, off + 10 + n
end

------------------------------------------------------------------------------------------
-- correctness: all three produce identical bytes and round-trip
------------------------------------------------------------------------------------------
local sample: Rec = { a = 777, b = 45, c = -1234, f = 1.5, ok = true, name = "player_01" }
local function same(x: Rec, y: Rec): boolean
	return x.a == y.a and x.b == y.b and x.c == y.c and x.f == y.f and x.ok == y.ok and x.name == y.name
end
do
	local ba, bb, bc = buffer.create(64), buffer.create(64), buffer.create(64)
	local na, nb, nc = encodeA(ba, 0, sample), encodeB(bb, 0, sample), encodeC(bc, 0, sample)
	assert(na == nb and nb == nc, "lengths differ")
	assert(buffer.tostring(ba) == buffer.tostring(bb) and buffer.tostring(bb) == buffer.tostring(bc), "bytes differ")
	assert(same(decodeA(ba, 0), sample) and same(decodeB(bb, 0), sample) and same(decodeC(bc, 0), sample), "round trip")
end

------------------------------------------------------------------------------------------
-- harness
------------------------------------------------------------------------------------------
local buf = buffer.create(64)
local sink: any = nil
local function bench(encode: (buffer, number, Rec) -> number, decode: (buffer, number) -> (Rec, number)): number
	local start = os.clock()
	for _ = 1, ITER do
		encode(buf, 0, sample)
		sink = decode(buf, 0)
	end
	return (os.clock() - start) / ITER * 1e9
end

local variants = {
	{ "a closures", encodeA, decodeA },
	{ "b straight-line bit32", encodeB, decodeB },
	{ "c straight-line writebits", encodeC, decodeC },
}
local samples = {}
for i, v in variants do
	bench(v[2], v[3]) -- warm-up
	samples[i] = {}
end
for _ = 1, RUNS do -- interleave variants to spread drift evenly
	for i, v in variants do
		table.insert(samples[i], bench(v[2], v[3]))
	end
end
local medians = {}
for i, v in variants do
	table.sort(samples[i])
	medians[i] = samples[i][(RUNS + 1) // 2]
	print(string.format("%-28s median %7.1f ns/op  min %7.1f  max %7.1f", v[1], medians[i], samples[i][1], samples[i][RUNS]))
end
print(string.format("ratio a/b %.2f   c/b %.2f   a/c %.2f", medians[1] / medians[2], medians[3] / medians[2], medians[1] / medians[3]))
