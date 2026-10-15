--!strict
-- Q6: cost per symbol of static canonical Huffman and static rANS in Luau, with a
-- round-trip check before timing. Alphabet: 256 byte symbols with a skewed
-- (geometric, mean ~6) distribution, like the bytes of a varint residual frame.
--
--   luau -O2 entropy.luau            (interpreted: Roblox clients)
--   luau -O2 --codegen entropy.luau  (native: Roblox servers with --!native)

local N = 2048 -- symbols per "frame"
local ITER = 300
local clock = os.clock

local seed = 777
local function rnd(): number
	seed = bit32.bxor(seed, bit32.lshift(seed, 13))
	seed = bit32.bxor(seed, bit32.rshift(seed, 17))
	seed = bit32.bxor(seed, bit32.lshift(seed, 5))
	return seed / 4294967296
end

local syms = buffer.create(N)
local counts = table.create(256, 0)
for i = 0, N - 1 do
	local s = math.min(255, math.floor(-math.log(1 - rnd()) * 6))
	buffer.writeu8(syms, i, s)
	counts[s + 1] += 1
end

local function timeit(name: string, f: () -> ())
	f()
	local best = math.huge
	for _ = 1, 5 do
		local t = clock()
		for _ = 1, ITER do
			f()
		end
		best = math.min(best, (clock() - t) / ITER)
	end
	print(string.format("  %-40s %7.1f ns/symbol", name, best / N * 1e9))
end

------------------------------------------------------------------------------
-- canonical Huffman, length-limited by frequency flooring (max length <= 12)
------------------------------------------------------------------------------
local freq = table.create(256, 0)
do
	local floor = math.max(1, N // 1500)
	for s = 1, 256 do
		freq[s] = math.max(counts[s], floor)
	end
end

local function huffLengths(fr: { number }): { number }
	-- O(n^2) Huffman is fine for 256 symbols
	local nodes = {}
	for s = 1, #fr do
		table.insert(nodes, { w = fr[s], syms = { s } })
	end
	local len = table.create(#fr, 0)
	while #nodes > 1 do
		table.sort(nodes, function(a, b)
			return a.w < b.w
		end)
		local a = table.remove(nodes, 1)
		local b = table.remove(nodes, 1)
		local merged = { w = a.w + b.w, syms = {} }
		for _, s in a.syms do
			len[s] += 1
			table.insert(merged.syms, s)
		end
		for _, s in b.syms do
			len[s] += 1
			table.insert(merged.syms, s)
		end
		table.insert(nodes, merged)
	end
	return len
end

local hlen = huffLengths(freq)
local maxLen = 0
for s = 1, 256 do
	maxLen = math.max(maxLen, hlen[s])
end
assert(maxLen <= 12, `max Huffman length {maxLen}`)
local TB = maxLen

-- canonical codes, bit-reversed for an LSB-first stream
local hcode = table.create(256, 0)
do
	local order = table.create(256, 0)
	for s = 1, 256 do
		order[s] = s
	end
	table.sort(order, function(a, b)
		return hlen[a] < hlen[b] or (hlen[a] == hlen[b] and a < b)
	end)
	local code, prev = 0, hlen[order[1]]
	for _, s in order do
		code = bit32.lshift(code, hlen[s] - prev)
		prev = hlen[s]
		local r = 0
		for i = 0, hlen[s] - 1 do
			if bit32.btest(code, bit32.lshift(1, i)) then
				r = bit32.bor(r, bit32.lshift(1, hlen[s] - 1 - i))
			end
		end
		hcode[s] = r
		code += 1
	end
end
-- decode LUT: TB-bit peek -> symbol, length
local lutSym = buffer.create(bit32.lshift(1, TB))
local lutLen = buffer.create(bit32.lshift(1, TB))
for s = 1, 256 do
	for fill = hcode[s], bit32.lshift(1, TB) - 1, bit32.lshift(1, hlen[s]) do
		buffer.writeu8(lutSym, fill, s - 1)
		buffer.writeu8(lutLen, fill, hlen[s])
	end
end

local hbuf = buffer.create(N * 2 + 8)
local hbits = 0
local function huffEncode()
	local acc, nb, o = 0, 0, 0
	for i = 0, N - 1 do
		local s = buffer.readu8(syms, i) + 1
		acc = bit32.bor(acc, bit32.lshift(hcode[s], nb))
		nb += hlen[s]
		if nb >= 16 then
			buffer.writeu16(hbuf, o, bit32.band(acc, 0xFFFF))
			o += 2
			acc = bit32.rshift(acc, 16)
			nb -= 16
		end
	end
	buffer.writeu32(hbuf, o, acc)
	hbits = o * 8 + nb
end

local out = buffer.create(N)
local function huffDecode()
	local p = 0
	local mask = bit32.lshift(1, TB) - 1
	for i = 0, N - 1 do
		local w = bit32.rshift(buffer.readu32(hbuf, bit32.rshift(p, 3)), bit32.band(p, 7))
		local peek = bit32.band(w, mask)
		buffer.writeu8(out, i, buffer.readu8(lutSym, peek))
		p += buffer.readu8(lutLen, peek)
	end
end

------------------------------------------------------------------------------
-- static rANS (Giesen rans_byte layout): 12-bit probabilities, L = 2^23
------------------------------------------------------------------------------
local PB = 12
local M = bit32.lshift(1, PB)
local RANS_L = bit32.lshift(1, 23)
local rfreq = buffer.create(256 * 2)
local rstart = buffer.create(256 * 2)
local slot2sym = buffer.create(M)
do
	-- normalise counts to sum M, every symbol >= 1
	local total = 0
	for s = 1, 256 do
		total += freq[s]
	end
	local f = table.create(256, 0)
	local sum = 0
	for s = 1, 256 do
		f[s] = math.max(1, math.floor(freq[s] / total * M))
		sum += f[s]
	end
	-- fix rounding on the most frequent symbol
	local big = 1
	for s = 2, 256 do
		if f[s] > f[big] then
			big = s
		end
	end
	f[big] += M - sum
	local c = 0
	for s = 1, 256 do
		buffer.writeu16(rfreq, (s - 1) * 2, f[s])
		buffer.writeu16(rstart, (s - 1) * 2, c)
		for k = c, c + f[s] - 1 do
			buffer.writeu8(slot2sym, k, s - 1)
		end
		c += f[s]
	end
	assert(c == M)
end

local rbuf = buffer.create(N * 2 + 16)
local rStartOff = 0
local function ransEncode()
	-- encode symbols in reverse, emitting bytes backwards from the end of rbuf
	local x = RANS_L
	local o = buffer.len(rbuf)
	for i = N - 1, 0, -1 do
		local s = buffer.readu8(syms, i)
		local f = buffer.readu16(rfreq, s * 2)
		local xmax = f * 2 ^ (23 - PB + 8) -- ((L >> PB) << 8) * f
		while x >= xmax do
			o -= 1
			buffer.writeu8(rbuf, o, bit32.band(x, 255))
			x = bit32.rshift(x, 8)
		end
		x = (x // f) * M + (x % f) + buffer.readu16(rstart, s * 2)
	end
	o -= 4
	buffer.writeu32(rbuf, o, x)
	rStartOff = o
end

local function ransDecode()
	local o = rStartOff
	local x = buffer.readu32(rbuf, o)
	o += 4
	for i = 0, N - 1 do
		local slot = bit32.band(x, M - 1)
		local s = buffer.readu8(slot2sym, slot)
		x = buffer.readu16(rfreq, s * 2) * bit32.rshift(x, PB) + slot - buffer.readu16(rstart, s * 2)
		while x < RANS_L do
			x = bit32.bor(bit32.lshift(x, 8), buffer.readu8(rbuf, o))
			o += 1
		end
		buffer.writeu8(out, i, s)
	end
end

------------------------------------------------------------------------------
-- verify, then time
------------------------------------------------------------------------------
local H0 = 0
for s = 1, 256 do
	if counts[s] > 0 then
		H0 -= counts[s] * math.log(counts[s] / N, 2)
	end
end

huffEncode()
huffDecode()
assert(buffer.tostring(out) == buffer.tostring(syms), "Huffman round trip failed")
buffer.fill(out, 0, 0)
ransEncode()
ransDecode()
assert(buffer.tostring(out) == buffer.tostring(syms), "rANS round trip failed")
print(
	string.format(
		"N=%d symbols, H0 = %.0f bytes, Huffman %.0f bytes (max len %d), rANS %d bytes",
		N,
		H0 / 8,
		hbits / 8,
		TB,
		buffer.len(rbuf) - rStartOff
	)
)
timeit("raw copy (readu8 + writeu8) baseline", function()
	for i = 0, N - 1 do
		buffer.writeu8(out, i, buffer.readu8(syms, i))
	end
end)
timeit("static Huffman decode (LUT)", huffDecode)
timeit("static Huffman encode", huffEncode)
timeit("static rANS decode", ransDecode)
timeit("static rANS encode", ransEncode)
