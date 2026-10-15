--!strict
-- Review of v5.md §4 at draft 3.6: an independent writer for the golden frames, from the §4 text alone.
-- Not derived from probes/design-3.6/golden_wire.luau. Run: luau wire.luau
local band, bor, bxor, lshift, rshift, lrot = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift, bit32.lrotate

-- bit list writer: bits[i] in stream order
local function W() return { bits = {} :: { number }, tail = {} :: { string } } end
local function put(w, v: number, n: number) -- u(n), LSB first, v may exceed 2^32
	for i = 0, n - 1 do
		local b = math.floor(v / 2 ^ i) % 2
		table.insert(w.bits, b)
	end
end
local function lit(w, s: string) for c in s:gmatch(".") do table.insert(w.bits, tonumber(c) :: number) end end
local function eg0(w, x: number)
	local z = 0
	while 2 ^ (z + 1) <= x + 1 do z += 1 end
	for _ = 1, z do table.insert(w.bits, 0) end
	table.insert(w.bits, 1)
	put(w, (x + 1) - 2 ^ z, z)
end
local function egk(w, u: number, k: number) eg0(w, math.floor(u / 2 ^ k)); put(w, u % 2 ^ k, k) end
local function align(w) while #w.bits % 8 ~= 0 do table.insert(w.bits, 0) end end
local function bytes(w): { number }
	local out = {}
	for i = 0, #w.bits - 1, 8 do
		local b = 0
		for j = 0, 7 do b += (w.bits[i + j + 1] or 0) * 2 ^ j end
		table.insert(out, b)
	end
	return out
end
local function hex(t: { number }) local s = {} for _, b in t do table.insert(s, string.format("%02x", b)) end return table.concat(s, " ") end
local function bitstr(w) local s = {} for _, b in w.bits do table.insert(s, tostring(b)) end return table.concat(s) end

-- frame = bits align tail [tag]; tail = chunk tail segments in reverse chunk order, each in reverse decode order
local function finish(w): { number }
	align(w)
	local out = bytes(w)
	for i = #w.tail, 1, -1 do for c in w.tail[i]:gmatch(".") do table.insert(out, string.byte(c)) end end
	return out
end

-- HalfSipHash-c-d, reference (Aumasson): key two LE u32, outlen 4 or 8
local function add(a, b) return (a + b) % 4294967296 end
local function hsip(k0: number, k1: number, msg: { number }, c: number, d: number, outlen: number, i0: number?, i1: number?): { number }
	local v0, v1 = k0, k1
	local v2, v3 = bxor(i0 or 0x6c796765, k0), bxor(i1 or 0x74656462, k1)
	if outlen == 8 then v1 = bxor(v1, 0xee) end
	local function round()
		v0 = add(v0, v1); v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 = add(v2, v3); v3 = lrot(v3, 8); v3 = bxor(v3, v2)
		v0 = add(v0, v3); v3 = lrot(v3, 7); v3 = bxor(v3, v0)
		v2 = add(v2, v1); v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	local n = #msg
	local full = n - n % 4
	for i = 1, full, 4 do
		local m = msg[i] + msg[i + 1] * 256 + msg[i + 2] * 65536 + msg[i + 3] * 16777216
		v3 = bxor(v3, m); for _ = 1, c do round() end; v0 = bxor(v0, m)
	end
	local b = lshift(n % 256, 24)
	local r = n % 4
	for j = r, 1, -1 do b = bor(b, lshift(msg[full + j], 8 * (j - 1))) end
	v3 = bxor(v3, b); for _ = 1, c do round() end; v0 = bxor(v0, b)
	v2 = bxor(v2, if outlen == 8 then 0xee else 0xff)
	for _ = 1, d do round() end
	local out = {}
	local function le(x) for j = 0, 3 do table.insert(out, band(rshift(x, 8 * j), 255)) end end
	le(bxor(v1, v3))
	if outlen == 8 then v1 = bxor(v1, 0xdd); for _ = 1, d do round() end; le(bxor(v1, v3)) end
	return out
end
local function u32le(x: number, t: { number }) for j = 0, 3 do table.insert(t, band(rshift(x, 8 * j), 255)) end end
local function u32of(t: { number }, i: number) return t[i] + t[i + 1] * 256 + t[i + 2] * 65536 + t[i + 3] * 16777216 end

do -- reference vectors (halfsiphash vectors.h, first entry, key 00..07, empty input)
	print("check hsip-2-4/32 empty:", hex(hsip(0x03020100, 0x07060504, {}, 2, 4, 4)), "(ref a9 35 9f 5b)")
	print("check hsip-2-4/64 empty:", hex(hsip(0x03020100, 0x07060504, {}, 2, 4, 8)), "(ref 21 8d 1f 59 b9 b8 3c c8)")
	local m = {} for i = 0, 14 do table.insert(m, i) end
	print("check hsip-2-4/32 00..0e:", hex(hsip(0x03020100, 0x07060504, m, 2, 4, 4)))
end

-- §4.5 tag: input = count/seq u32le, lane byte, length u32le, instance count u16le, first min(cover,len) bytes
local K0, K1 = 0x03020100, 0x07060504
local function tag(frame: { number }, count: number, lane: number, caller: number, inst: number, cover: number): { number }
	local input = {}
	u32le(count % 4294967296, input)
	table.insert(input, lane + 128 * caller)
	u32le(#frame, input)
	table.insert(input, inst % 256); table.insert(input, rshift(inst, 8))
	for i = 1, math.min(cover, #frame) do table.insert(input, frame[i]) end
	local h = hsip(K0, K1, input, 1, 3, 4)
	return h -- XOR m = 0
end
local function withTag(frame, count, lane, caller)
	local t = tag(frame, count, lane, caller, 0, 1024)
	local out = table.clone(frame) for _, b in t do table.insert(out, b) end
	return out
end

-- toc helpers
local function segs(w, list: { { number } }) eg0(w, #list); for _, s in list do eg0(w, s[1]); eg0(w, s[2] - 1) end end

-- G1
for _, x in { 0, 1, 2, 3, 7 } do local w = W(); eg0(w, x); print("G1 EG0", x, bitstr(w)) end
do local w = W(); egk(w, 5, 2); print("G1 EG2 5", bitstr(w)) end

-- G2: down reliable '11' u16 0; announce:fire round 3
do
	local w = W(); lit(w, "11"); put(w, 0, 16)
	segs(w, {}); segs(w, { { 1, 1 } }); segs(w, {})
	align(w)
	put(w, 0, 1); eg0(w, 0) -- id announce, count-1 0
	put(w, 0, 1); put(w, 3 - 1, 7) -- variant round, number
	print("G2 ", hex(finish(w)))
end
-- G2b
do
	local w = W(); lit(w, "10")
	segs(w, {}); segs(w, { { 1, 1 } }); segs(w, {})
	align(w)
	put(w, 0, 1); eg0(w, 1)
	put(w, 0, 1); put(w, 2, 7)
	put(w, 1, 1); put(w, 1, 1)
	print("G2b", hex(finish(w)))
end
-- G3 answer: slot u4 epoch u1 outcome u2 reply u17
do
	local w = W(); lit(w, "0")
	segs(w, {}); segs(w, { { 1, 1 } }); segs(w, {})
	align(w)
	put(w, 1, 1); eg0(w, 0)
	put(w, 0, 4); put(w, 0, 1); put(w, 0, 2); put(w, 250, 17)
	print("G3 ", hex(finish(w)))
end
-- G4 / G4c: up reliable caller ack rcv; chat id 1 (u2); string(200) length u8
local function g4(caller: number)
	local w = W(); put(w, caller, 1); lit(w, "0"); put(w, 0, 8)
	segs(w, { { 1, 1 } })
	put(w, 1, 2); eg0(w, 0)
	put(w, 2, 8); table.insert(w.tail, "gg")
	return withTag(finish(w), 0, 0, caller)
end
print("G4 ", hex(g4(0)))
print("G4c", hex(g4(1)))
-- G5: up unreliable seq u12 caller ack '1' seq12 received16; toc segs(run) empty
do
	local w = W(); put(w, 0, 12); put(w, 0, 1); lit(w, "1"); put(w, 5, 12); put(w, 3, 16)
	segs(w, {})
	print("G5 ", hex(withTag(finish(w), 0, 1, 0)))
end
-- G6 serialization
local function num(t, x: number)
	local b = buffer.create(8); buffer.writef64(b, 0, if x == 0 then 0 else x)
	for i = 0, 7 do table.insert(t, buffer.readu8(b, i)) end
end
local function str(t, s: string) table.insert(t, #s % 256); table.insert(t, #s // 256); for c in s:gmatch(".") do table.insert(t, string.byte(c)) end end
local g6 = {}
do
	table.insert(g6, 1); str(g6, "arena"); table.insert(g6, 1); table.insert(g6, 0)
	str(g6, "chat"); table.insert(g6, 1); table.insert(g6, 1); table.insert(g6, 1)
	table.insert(g6, 1); table.insert(g6, 8); num(g6, 200) -- data
	for _ = 1, 8 do table.insert(g6, 0) end -- reply key perSecond burst timeout maxRecords priority reliableRate
	table.insert(g6, 1); table.insert(g6, 0) -- perceived false
	table.insert(g6, 0) -- sealed
	print("G6 ser ", hex(g6))
end
local g6h = hsip(0, 0, g6, 2, 4, 8)
print("G6 hash", hex(g6h))
-- G7: untagged HELLO
do
	local w = W(); put(w, 0, 1); lit(w, "0"); put(w, 0, 8)
	segs(w, { { 0, 1 } })
	put(w, 0, 3); eg0(w, 0)
	put(w, 1, 8); put(w, 0, 32); put(w, u32of(g6h, 1), 32); put(w, u32of(g6h, 5), 32); put(w, 0, 32)
	put(w, 5, 7); table.insert(w.tail, "arena")
	print("G7 ", hex(finish(w)))
end
-- G8: up unreliable seq0 caller0 ack'0'; strike id 2, 4 rows column block; aim (x,y) then target
local function colcost(res: { number }) -- zigzagged residuals; returns best (mode,k,bits,writer fn)
	local best
	local function consider(mode, k, bits, fn)
		if not best or bits < best[3] then best = { mode, k, bits, fn } end
	end
	local allz = true for _, r in res do if r ~= 0 then allz = false end end
	if allz then consider(0, 0, 2, function(w) put(w, 0, 2) end) end
	local function egbits(u, k) local x = math.floor(u / 2 ^ k); local z = 0 while 2 ^ (z + 1) <= x + 1 do z += 1 end return 2 * z + 1 + k end
	for k = 0, 15 do
		local b = 2 + 4 for _, r in res do b += egbits(r, k) end
		consider(1, k, b, function(w) put(w, 1, 2); put(w, k, 4); for _, r in res do egk(w, r, k) end end)
	end
	for k = 0, 15 do
		local nz = {} local gap = 0 local pairs_ = {}
		for _, r in res do if r ~= 0 then table.insert(pairs_, { gap, r - 1 }); gap = 0 else gap += 1 end end
		local b = 2 + 4 + egbits(#pairs_, 0) for _, p in pairs_ do b += egbits(p[1], 0) + egbits(p[2], k) end
		consider(2, k, b, function(w) put(w, 2, 2); put(w, k, 4); eg0(w, #pairs_); for _, p in pairs_ do eg0(w, p[1]); egk(w, p[2], k) end end)
		local _ = nz
	end
	local mn, mx = math.huge, 0 for _, r in res do mn = math.min(mn, r); mx = math.max(mx, r) end
	local width = 0 while 2 ^ width <= mx - mn do width += 1 end
	consider(3, 0, 2 + egbits(mn, 0) + 6 + #res * width, function(w) put(w, 3, 2); eg0(w, mn); put(w, width, 6); for _, r in res do put(w, r - mn, width) end end)
	return best
end
local function residuals(codes: { number }, n: number): { number }
	local out, prev = {}, 0
	local lo, hi = -math.floor(n / 2), math.ceil(n / 2) - 1
	for _, c in codes do
		local r = c - prev
		if r > hi then r -= n elseif r < lo then r += n end
		table.insert(out, if r >= 0 then 2 * r else -2 * r - 1)
		prev = c
	end
	return out
end
do
	local w = W(); put(w, 0, 12); put(w, 0, 1); lit(w, "0")
	segs(w, { { 1, 1 } })
	put(w, 2, 2); eg0(w, 3)
	local q = math.floor((0 + 1) / 2 * (2 ^ 11 - 1) + 0.5)
	local desc = {}
	for _, col in { { { q, q, q, q }, 2048 }, { { q, q, q, q }, 2048 }, { { 4, 5, 6, 6 }, 2 ^ 40 } } do
		local best = colcost(residuals(col[1], col[2]))
		table.insert(desc, string.format("(%d,%d,%d)", best[1], best[2], best[3]))
		best[4](w)
	end
	print("G8 ", hex(withTag(finish(w), 0, 1, 0)), "aim q", q, table.concat(desc, " "))
end
-- G9
for _, v in { -2 ^ 52, 2 ^ 52 - 1 } do
	local w = W(); eg0(w, if v >= 0 then 2 * v else -2 * v - 1); local n = #w.bits
	print("G9 ", n, hex(finish(w)))
end
-- G10: first WELCOME
do
	local w = W(); lit(w, "11"); put(w, 0, 16)
	segs(w, {}); segs(w, { { 0, 1 } }); segs(w, {})
	align(w)
	put(w, 1, 3); eg0(w, 0)
	eg0(w, 1); put(w, 0, 1) -- ns index, layout
	local b = buffer.create(8); buffer.writef64(b, 0, 1000.5)
	put(w, buffer.readu32(b, 0), 32); put(w, buffer.readu32(b, 4), 32)
	put(w, 20, 6); put(w, math.max(math.ceil(500 / 20), 25), 8)
	put(w, K0, 32); put(w, K1, 32); put(w, 1024, 15); put(w, 0, 32)
	put(w, 0, 8); put(w, 0, 6); put(w, 0, 1); put(w, 0, 4)
	print("G10", hex(finish(w)))
end
-- G11
do
	local w = W(); lit(w, "0")
	segs(w, {}); segs(w, { { 0, 1 } }); segs(w, {})
	align(w)
	put(w, 2, 3); eg0(w, 0)
	print("G11", hex(finish(w)))
end
-- PERM
do
	local seed = bxor(bxor(0x12345678, 0x158b86ab), 1)
	if seed == 0 then seed = 0x9E3779B9 end
	local x = seed
	local function xs() x = bxor(x, lshift(x, 13)); x = bxor(x, rshift(x, 17)); x = bxor(x, lshift(x, 5)); return x end
	local p = { 0, 1, 2, 3, 4 }
	for i = 4, 1, -1 do local j = xs() % (i + 1); p[i + 1], p[j + 1] = p[j + 1], p[i + 1] end
	print("PERM", hex(p))
end
-- DERIVE
do
	local S0, S1 = 0x03020100, 0x07060504
	local key = hsip(S0, S1, { 8, 9, 10, 11, 12, 13, 14, 15, 1 }, 2, 4, 8)
	local ps = hsip(S0, S1, { 0x10, 0x11, 0x12, 0x13, 2 }, 2, 4, 8)
	local seed = u32of(ps, 1); if seed == 0 then seed = 1 end
	print("DERIVE", hex(key), string.format("0x%08x", seed), "hi32", string.format("0x%08x", u32of(ps, 5)))
	-- layout seed for G10's permutation nonce 0 at S = 0 (identity: seed = nonce = 0 -> 0 replaced by 1?)
end
-- W1, W2: up ids 3 bits; chat site 3, buy literal site 4
do
	local w = W(); put(w, 0, 1); lit(w, "0"); put(w, 0, 8)
	segs(w, { { 1, 1 } })
	put(w, 3, 3); eg0(w, 0); put(w, 2, 8); table.insert(w.tail, "gg")
	print("W1 ", hex(withTag(finish(w), 0, 0, 0)))
	local v = W(); put(v, 0, 1); lit(v, "0"); put(v, 0, 8)
	segs(v, { { 1, 1 } })
	put(v, 4, 3); eg0(v, 0); put(v, 0, 4); put(v, 0, 1)
	print("W2 ", hex(withTag(finish(v), 0, 0, 0)))
end
-- Sizes: REPORT alone (counts), BEACON alone, both; up reliable header 10 bits
local function eglen(x) local z = 0 while 2 ^ (z + 1) <= x + 1 do z += 1 end return 2 * z + 1 end
local function ctl(rows: { { number } }) -- each: {type, bits of fields}
	local bits = 10 + eglen(1) + eglen(0) + eglen(#rows - 1)
	for _, r in rows do bits += 3 + eglen(0) + r[2] end
	return math.ceil(bits / 8) + 4
end
local function rep(a, b, c, d) return eglen(a) + eglen(b) + eglen(c) + eglen(d) end
print("SIZES REPORT(0,0,1,0)", ctl({ { 5, rep(0, 0, 1, 0) } }), "REPORT(1,1,0,0)", ctl({ { 5, rep(1, 1, 0, 0) } }),
	"REPORT(60x4)", ctl({ { 5, rep(60, 60, 60, 60) } }), "BEACON", ctl({ { 6, 16 } }), "both(1,1,0,0)", ctl({ { 5, rep(1, 1, 0, 0) }, { 6, 16 } }),
	"both(60x4)", ctl({ { 5, rep(60, 60, 60, 60) }, { 6, 16 } }))
-- REKEY chunk size alone in a down reliable frame (tick unchanged): header 1 + toc 7 -> align, chunk 3+1+64
print("REKEY frame alone bytes", math.ceil((1 + 1 + 5 + 1) / 8) + math.ceil((3 + 1 + 64) / 8))
-- RATE alone: epoch 64 + stateRate 6 + delay 8 = 78 bits
print("RATE frame alone bytes", math.ceil((1 + 1 + 5 + 1) / 8) + math.ceil((3 + 1 + 78) / 8))
