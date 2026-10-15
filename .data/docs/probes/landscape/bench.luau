--!native
--!optimize 2
local N = 1000 -- symbols / fields per frame
local ITER = 2000
local clock = os.clock
local function bench(name: string, f: () -> ())
	f()
	local t = clock()
	for _ = 1, ITER do f() end
	local dt = clock() - t
	print(string.format("%-34s %8.1f ns/item  %7.2f us/frame", name, dt / ITER / N * 1e9, dt / ITER * 1e6))
end
local b = buffer.create(16384)
local vals = table.create(N, 0)
for i = 1, N do vals[i] = math.random(0, 1023) end

bench("writeu16 aligned", function()
	local o = 0
	for i = 1, N do buffer.writeu16(b, o, vals[i]); o += 2 end
end)
bench("readu16 aligned", function()
	local o, s = 0, 0
	for i = 1, N do s += buffer.readu16(b, o); o += 2 end
end)
bench("writebits 10-bit", function()
	local o = 0
	for i = 1, N do buffer.writebits(b, o, 10, vals[i]); o += 10 end
end)
bench("readbits 10-bit", function()
	local o, s = 0, 0
	for i = 1, N do s += buffer.readbits(b, o, 10); o += 10 end
end)
bench("manual bit accum 10-bit write", function()
	local acc, nb, o = 0, 0, 0
	for i = 1, N do
		acc = bit32.bor(acc, bit32.lshift(vals[i], nb)); nb += 10
		if nb >= 32 then
			buffer.writeu32(b, o, acc); o += 4; nb -= 32
			acc = bit32.rshift(vals[i], 10 - nb)
		end
	end
	if nb > 0 then buffer.writeu32(b, o, acc) end
end)
bench("LEB128 varint write", function()
	local o = 0
	for i = 1, N do
		local v = vals[i] * 37
		while v >= 128 do buffer.writeu8(b, o, bit32.bor(bit32.band(v, 127), 128)); o += 1; v = bit32.rshift(v, 7) end
		buffer.writeu8(b, o, v); o += 1
	end
end)
bench("LEB128 varint read", function()
	local o, s = 0, 0
	for i = 1, N do
		local v, sh = 0, 0
		while true do
			local by = buffer.readu8(b, o); o += 1
			v += bit32.lshift(bit32.band(by, 127), sh)
			if by < 128 then break end
			sh += 7
		end
		s += v
	end
end)
-- table-driven static Huffman decode: 11-bit peek table -> (sym, len)
local TB = 11
local symT = buffer.create(2^TB) ; local lenT = buffer.create(2^TB)
for i = 0, 2^TB - 1 do buffer.writeu8(symT, i, i % 256); buffer.writeu8(lenT, i, 1 + (i % 11)) end
bench("Huffman decode (LUT, readbits)", function()
	local o, s = 0, 0
	local mask = 2^TB - 1
	for i = 1, N do
		local peek = buffer.readbits(b, o, TB)
		s += buffer.readu8(symT, peek)
		o += buffer.readu8(lenT, peek)
	end
end)
-- rANS decode, 12-bit probabilities, byte-wise renorm, alias-free cumfreq LUT
local PB = 12
local M = 2^PB
local slot2sym = buffer.create(M)
local freq = buffer.create(256 * 2); local cum = buffer.create(256 * 2)
do local c = 0
	for s = 0, 255 do local f = 16; buffer.writeu16(freq, s*2, f); buffer.writeu16(cum, s*2, c); for k = c, c+f-1 do buffer.writeu8(slot2sym, k, s) end; c += f end
end
bench("rANS decode (12-bit LUT)", function()
	local x = 0x800000 -- state
	local o, s = 0, 0
	for i = 1, N do
		local slot = bit32.band(x, M - 1)
		local sym = buffer.readu8(slot2sym, slot)
		local f = buffer.readu16(freq, sym * 2)
		x = f * bit32.rshift(x, PB) + slot - buffer.readu16(cum, sym * 2)
		while x < 0x800000 do x = bit32.bor(bit32.lshift(x, 8), buffer.readu8(b, o)); o += 1 end
		s += sym
	end
end)
bench("rANS encode (12-bit)", function()
	local x = 0x800000
	local o = 0
	for i = N, 1, -1 do
		local sym = vals[i] % 256
		local f = buffer.readu16(freq, sym * 2)
		local xmax = f * 2^(23 - PB + 8) -- ((L >> PB) << 8) * f
		while x >= xmax do buffer.writeu8(b, o, bit32.band(x, 255)); o += 1; x = bit32.rshift(x, 8) end
		x = (x // f) * M + (x % f) + buffer.readu16(cum, sym * 2)
	end
end)
-- LZ-ish: hash-chain-less greedy match search over 1000 bytes (min-match 4) cost estimate
bench("LZ4-style greedy compress (per byte)", function()
	local ht = table.create(4096, -1)
	local i, n = 0, N - 4
	while i < n do
		local w = buffer.readu32(b, i)
		local h = bit32.rshift(bit32.band(w * 2654435761 // 1, 0xFFFFFFFF), 20) + 1
		local cand = ht[h]; ht[h] = i
		if cand >= 0 and buffer.readu32(b, cand) == w then
			local l = 4
			while i + l < N and buffer.readu8(b, cand + l) == buffer.readu8(b, i + l) do l += 1 end
			i += l
		else
			i += 1
		end
	end
end)
