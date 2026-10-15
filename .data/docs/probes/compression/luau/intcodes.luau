--!strict
-- Q3/Q6 decode (and some encode) cost of integer and entropy codes in Luau.
-- Every decoder is checked against the source values before it is timed.
--
-- Run (interpreted, as on Roblox clients):  luau -O2 intcodes.luau
-- Run (native, as on servers with --!native): luau -O2 --codegen intcodes.luau
-- Two value distributions: "small" (prediction residuals, mean ~1.2, like pos_pred60)
-- and "medium" (20 Hz deltas, mean ~20, like pos_delta20). Both zigzagged, >= 0.

local N = 1024
local ITER = 400
local clock = os.clock

local function bench(name: string, f: () -> number, expect: number)
	local got = f()
	assert(got == expect, `{name}: checksum {got} ~= {expect}`)
	local best = math.huge
	for _ = 1, 5 do
		local t = clock()
		for _ = 1, ITER do
			f()
		end
		local dt = (clock() - t) / ITER
		if dt < best then
			best = dt
		end
	end
	print(string.format("  %-34s %7.1f ns/value", name, best / N * 1e9))
end

-- deterministic generator (xorshift32), so runs are comparable
local seed = 12345
local function rnd(): number
	seed = bit32.bxor(seed, bit32.lshift(seed, 13))
	seed = bit32.bxor(seed, bit32.rshift(seed, 17))
	seed = bit32.bxor(seed, bit32.lshift(seed, 5))
	return seed / 4294967296
end

local function geometric(mean: number): number
	-- discrete exponential with the given mean
	return math.floor(-math.log(1 - rnd()) * mean)
end

local function makeValues(kind: string): { number }
	local v = table.create(N, 0)
	for i = 1, N do
		if kind == "small" then
			v[i] = if rnd() < 0.45 then 0 else 1 + geometric(1.6)
			if rnd() < 0.01 then
				v[i] = 20 + geometric(30)
			end
		else
			v[i] = geometric(20)
		end
	end
	return v
end

------------------------------------------------------------------------------
-- encoders (not timed except where noted)
------------------------------------------------------------------------------

local function encLEB(vals: { number }, b: buffer): number
	local o = 0
	for i = 1, #vals do
		local v = vals[i]
		while v >= 128 do
			buffer.writeu8(b, o, bit32.bor(bit32.band(v, 127), 128))
			o += 1
			v = bit32.rshift(v, 7)
		end
		buffer.writeu8(b, o, v)
		o += 1
	end
	return o
end

-- PrefixVarint: unary length in low bits of byte 0 (1..4 bytes here; values < 2^28)
local function encPrefix(vals: { number }, b: buffer): number
	local o = 0
	for i = 1, #vals do
		local v = vals[i]
		if v < 128 then
			buffer.writeu8(b, o, v * 2)
			o += 1
		elseif v < 16384 then
			buffer.writeu16(b, o, v * 4 + 1)
			o += 2
		elseif v < 2097152 then
			local w = v * 8 + 3
			buffer.writeu16(b, o, bit32.band(w, 0xFFFF))
			buffer.writeu8(b, o + 2, bit32.rshift(w, 16))
			o += 3
		else
			buffer.writeu32(b, o, v * 16 + 7)
			o += 4
		end
	end
	return o
end

-- vu128-style: < 0xF0 in one byte, else 0xF0|(n-1) then n bytes
local function encVu(vals: { number }, b: buffer): number
	local o = 0
	for i = 1, #vals do
		local v = vals[i]
		if v < 0xF0 then
			buffer.writeu8(b, o, v)
			o += 1
		elseif v < 65536 then
			buffer.writeu8(b, o, 0xF1)
			buffer.writeu16(b, o + 1, v)
			o += 3
		else
			buffer.writeu8(b, o, 0xF3)
			buffer.writeu32(b, o + 1, v)
			o += 5
		end
	end
	return o
end

local function nbytes(v: number): number
	return if v < 256 then 1 elseif v < 65536 then 2 elseif v < 16777216 then 3 else 4
end

local function writeN(b: buffer, o: number, v: number, n: number)
	if n == 1 then
		buffer.writeu8(b, o, v)
	elseif n == 2 then
		buffer.writeu16(b, o, v)
	elseif n == 3 then
		buffer.writeu16(b, o, bit32.band(v, 0xFFFF))
		buffer.writeu8(b, o + 2, bit32.rshift(v, 16))
	else
		buffer.writeu32(b, o, v)
	end
end

local function encGroup(vals: { number }, b: buffer): number
	local o = 0
	for i = 1, #vals, 4 do
		local tagAt = o
		o += 1
		local tag = 0
		for j = 0, 3 do
			local v = vals[i + j]
			local n = nbytes(v)
			tag = bit32.bor(tag, bit32.lshift(n - 1, 2 * j))
			writeN(b, o, v, n)
			o += n
		end
		buffer.writeu8(b, tagAt, tag)
	end
	return o
end

-- Stream VByte: control bytes in `c`, data in `b`
local function encSVB(vals: { number }, c: buffer, b: buffer): number
	local o = 0
	for i = 1, #vals, 4 do
		local tag = 0
		for j = 0, 3 do
			local v = vals[i + j]
			local n = nbytes(v)
			tag = bit32.bor(tag, bit32.lshift(n - 1, 2 * j))
			writeN(b, o, v, n)
			o += n
		end
		buffer.writeu8(c, (i - 1) // 4, tag)
	end
	return o
end

-- LSB-first bit writer (accumulator); returns a writer closure set
local function bitWriter(b: buffer)
	local acc, nb, o = 0, 0, 0
	local function w(v: number, bits: number)
		-- bits <= 24 per call keeps acc within 32 bits
		while bits > 24 do
			w(bit32.band(v, 0xFFFFFF), 24)
			v = v // 16777216
			bits -= 24
		end
		acc = bit32.bor(acc, bit32.lshift(v, nb))
		nb += bits
		while nb >= 8 do
			buffer.writeu8(b, o, bit32.band(acc, 255))
			o += 1
			acc = bit32.rshift(acc, 8)
			nb -= 8
		end
	end
	local function done(): number
		if nb > 0 then
			buffer.writeu8(b, o, acc)
			o += 1
		end
		return o
	end
	return w, done
end

-- LSB-friendly Exp-Golomb order k: n zeros, a one, then the low n+k bits of v + 2^k
local function encEG(vals: { number }, b: buffer, k: number): number
	local w, done = bitWriter(b)
	for i = 1, #vals do
		local u = vals[i] + bit32.lshift(1, k)
		local len = 0
		while bit32.rshift(u, len + 1) > 0 do
			len += 1
		end -- len = floor(log2 u)
		local n = len - k
		w(bit32.lshift(1, n), n + 1)
		w(u - bit32.lshift(1, len), len)
	end
	return done()
end


-- inlined accumulator encoder (what a generated server encoder would look like)
local function encEGFast(vals: { number }, b: buffer, k: number): number
	local acc, nb, o = 0, 0, 0
	local twoK = bit32.lshift(1, k)
	for i = 1, #vals do
		local u = vals[i] + twoK
		local len = 31 - bit32.countlz(u) -- floor(log2 u)
		local n = len - k
		-- n zeros, a one, then the low `len` bits of u: as one field of 2n+1+k bits
		local code = bit32.lshift(bit32.band(u, bit32.lshift(1, len) - 1), n + 1) + bit32.lshift(1, n)
		local bits = 2 * n + 1 + k
		if bits <= 24 then
			acc = bit32.bor(acc, bit32.lshift(code, nb))
			nb += bits
		else -- rare long code: prefix then value
			acc = bit32.bor(acc, bit32.lshift(bit32.lshift(1, n), nb))
			nb += n + 1
			while nb >= 8 do
				buffer.writeu8(b, o, bit32.band(acc, 255))
				o += 1
				acc = bit32.rshift(acc, 8)
				nb -= 8
			end
			acc = bit32.bor(acc, bit32.lshift(bit32.band(u, bit32.lshift(1, len) - 1), nb))
			nb += len
		end
		while nb >= 8 do
			buffer.writeu8(b, o, bit32.band(acc, 255))
			o += 1
			acc = bit32.rshift(acc, 8)
			nb -= 8
		end
	end
	if nb > 0 then
		buffer.writeu8(b, o, acc)
		o += 1
	end
	return o
end

-- Rice k: q zeros then a one, then k low bits
local function encRice(vals: { number }, b: buffer, k: number): number
	local w, done = bitWriter(b)
	for i = 1, #vals do
		local v = vals[i]
		local q = bit32.rshift(v, k)
		while q >= 24 do
			w(0, 24)
			q -= 24
		end
		w(bit32.lshift(1, q), q + 1)
		w(bit32.band(v, bit32.lshift(1, k) - 1), k)
	end
	return done()
end

local function encFixedBits(vals: { number }, b: buffer, width: number): number
	local w, done = bitWriter(b)
	for i = 1, #vals do
		w(vals[i], width)
	end
	return done()
end

-- The v5 attempt's class code: 4-bit class, then that many bits
local CLASS_W = { 0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 53 }
local function encClass(vals: { number }, b: buffer): number
	local w, done = bitWriter(b)
	for i = 1, #vals do
		local v = vals[i]
		for c = 1, 16 do
			if v < 2 ^ CLASS_W[c] then
				w(c - 1, 4)
				w(v, CLASS_W[c])
				break
			end
		end
	end
	return done()
end

-- Unity bucket model: canonical Huffman over 16 buckets, then raw offset bits
local U_SIZE = { 0, 0, 1, 2, 3, 4, 6, 8, 10, 12, 15, 18, 21, 24, 27, 32 }
local U_OFF = { 0, 1, 2, 4, 8, 16, 32, 96, 352, 1376, 5472, 38240, 300384, 2397536, 19174752, 153392480 }
local U_LEN = { 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 6, 6, 6 }
-- canonical codes (assigned in length order), stored bit-reversed for LSB-first reading
local U_CODE = table.create(16, 0)
local U_LUT_B = buffer.create(64) -- 6-bit peek -> bucket (0-based)
do
	local code, prevLen = 0, U_LEN[1]
	for s = 1, 16 do
		local len = U_LEN[s]
		code = bit32.lshift(code, len - prevLen)
		prevLen = len
		-- reverse `len` bits
		local r = 0
		for i = 0, len - 1 do
			if bit32.btest(code, bit32.lshift(1, i)) then
				r = bit32.bor(r, bit32.lshift(1, len - 1 - i))
			end
		end
		U_CODE[s] = r
		for fill = 0, 63, bit32.lshift(1, len) do
			buffer.writeu8(U_LUT_B, fill + r, s - 1)
		end
		code += 1
	end
end
local function encUnity(vals: { number }, b: buffer): number
	local w, done = bitWriter(b)
	for i = 1, #vals do
		local v = vals[i]
		local s = 16
		while U_OFF[s] > v do
			s -= 1
		end
		w(U_CODE[s], U_LEN[s])
		w(v - U_OFF[s], U_SIZE[s])
	end
	return done()
end

------------------------------------------------------------------------------
-- decoders (timed). Each returns the sum of decoded values as a checksum.
------------------------------------------------------------------------------

local function decU8(b: buffer, n: number): number
	local s, o = 0, 0
	for _ = 1, n do
		s += buffer.readu8(b, o)
		o += 1
	end
	return s
end

local function decU16(b: buffer, n: number): number
	local s, o = 0, 0
	for _ = 1, n do
		s += buffer.readu16(b, o)
		o += 2
	end
	return s
end

local function decLEB(b: buffer, n: number): number
	local s, o = 0, 0
	for _ = 1, n do
		local by = buffer.readu8(b, o)
		o += 1
		if by < 128 then
			s += by
		else
			local v, sh = bit32.band(by, 127), 7
			repeat
				by = buffer.readu8(b, o)
				o += 1
				v += bit32.lshift(bit32.band(by, 127), sh)
				sh += 7
			until by < 128
			s += v
		end
	end
	return s
end

local function decPrefix(b: buffer, n: number): number
	local s, o = 0, 0
	for _ = 1, n do
		local by = buffer.readu8(b, o)
		if bit32.band(by, 1) == 0 then
			s += bit32.rshift(by, 1)
			o += 1
		elseif bit32.band(by, 2) == 0 then
			s += bit32.rshift(buffer.readu16(b, o), 2)
			o += 2
		elseif bit32.band(by, 4) == 0 then
			s += bit32.rshift(buffer.readu32(b, o), 3) % 2097152
			o += 3
		else
			s += bit32.rshift(buffer.readu32(b, o), 4)
			o += 4
		end
	end
	return s
end

local function decVu(b: buffer, n: number): number
	local s, o = 0, 0
	for _ = 1, n do
		local by = buffer.readu8(b, o)
		if by < 0xF0 then
			s += by
			o += 1
		elseif by == 0xF1 then
			s += buffer.readu16(b, o + 1)
			o += 3
		else
			s += buffer.readu32(b, o + 1)
			o += 5
		end
	end
	return s
end

local MASKS = { 0xFF, 0xFFFF, 0xFFFFFF, 0xFFFFFFFF }
local function decGroup(b: buffer, n: number): number
	local s, o = 0, 0
	for _ = 1, n, 4 do
		local tag = buffer.readu8(b, o)
		o += 1
		for _ = 1, 4 do
			local len = bit32.band(tag, 3) + 1
			s += bit32.band(buffer.readu32(b, o), MASKS[len])
			o += len
			tag = bit32.rshift(tag, 2)
		end
	end
	return s
end

local function decSVB(c: buffer, b: buffer, n: number): number
	local s, o = 0, 0
	for g = 0, n // 4 - 1 do
		local tag = buffer.readu8(c, g)
		for _ = 1, 4 do
			local len = bit32.band(tag, 3) + 1
			s += bit32.band(buffer.readu32(b, o), MASKS[len])
			o += len
			tag = bit32.rshift(tag, 2)
		end
	end
	return s
end

-- absolute-position bit reader: w = readu32 at p>>3 shifted by p&7 (>= 25 valid bits)
local function decEG(b: buffer, n: number, k: number): number
	local s, p = 0, 0
	local twoK = bit32.lshift(1, k)
	for _ = 1, n do
		local w = bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7))
		local z = bit32.countrz(w)
		local len = z + k
		if 2 * z + 1 + k <= 25 then
			s += bit32.band(bit32.rshift(w, z + 1), bit32.lshift(1, len) - 1) + bit32.lshift(1, len) - twoK
			p += 2 * z + 1 + k
		else -- long code: prefix and value read separately
			p += z + 1
			local v = 0
			if len > 0 then
				v = bit32.band(
					bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7)),
					bit32.lshift(1, math.min(len, 24)) - 1
				)
			end
			s += v + bit32.lshift(1, len) - twoK
			p += len
		end
	end
	return s
end

local function decRice(b: buffer, n: number, k: number): number
	local s, p = 0, 0
	local mask = bit32.lshift(1, k) - 1
	for _ = 1, n do
		local w = bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7))
		local q = bit32.countrz(w)
		if q + 1 + k <= 25 then
			s += bit32.lshift(q, k) + bit32.band(bit32.rshift(w, q + 1), mask)
			p += q + 1 + k
		else -- long unary run: count zeros 24 bits at a time
			q = 0
			while true do
				w = bit32.band(bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7)), 0xFFFFFF)
				if w ~= 0 then
					break
				end
				q += 24
				p += 24
			end
			local z = bit32.countrz(w)
			q += z
			p += z + 1
			s += q * 2 ^ k + bit32.band(bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7)), mask)
			p += k
		end
	end
	return s
end

-- same code, arithmetic instead of bit32 where possible (cheaper in the interpreter)
local POW2 = table.create(33, 0)
for i = 0, 32 do
	POW2[i + 1] = 2 ^ i
end
local function decEGArith(b: buffer, n: number, k: number): number
	local s, p = 0, 0
	local twoK = 2 ^ k
	for _ = 1, n do
		local w = buffer.readu32(b, p // 8) // POW2[p % 8 + 1]
		local z = bit32.countrz(w)
		local len = z + k
		local used = 2 * z + 1 + k
		if used <= 25 then
			local top = POW2[len + 1]
			s += w // POW2[z + 2] % top + top - twoK
			p += used
		else
			p += z + 1
			local v = 0
			if len > 0 then
				v = buffer.readu32(b, p // 8) // POW2[p % 8 + 1] % POW2[math.min(len, 24) + 1]
			end
			s += v + POW2[len + 1] - twoK
			p += len
		end
	end
	return s
end

local function decFixedBits(b: buffer, n: number, width: number): number
	local s, p = 0, 0
	local mask = bit32.lshift(1, width) - 1
	for _ = 1, n do
		s += bit32.band(bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7)), mask)
		p += width
	end
	return s
end

local function decReadbits(b: buffer, n: number, width: number): number
	local s, p = 0, 0
	for _ = 1, n do
		s += buffer.readbits(b, p, width)
		p += width
	end
	return s
end


-- table-driven Exp-Golomb: a 12-bit peek resolves every code of <= 12 bits in one lookup
local LUT_BITS = 12
local function makeEGLut(k: number): (buffer, buffer)
	local vals = buffer.create(2 ^ LUT_BITS * 2)
	local lens = buffer.create(2 ^ LUT_BITS)
	for peek = 0, 2 ^ LUT_BITS - 1 do
		local z = bit32.countrz(peek)
		local used = 2 * z + 1 + k
		if peek ~= 0 and used <= LUT_BITS then
			local len = z + k
			local v = bit32.band(bit32.rshift(peek, z + 1), bit32.lshift(1, len) - 1) + bit32.lshift(1, len) - bit32.lshift(1, k)
			buffer.writeu16(vals, peek * 2, v)
			buffer.writeu8(lens, peek, used)
		end
	end
	return vals, lens
end

local function decEGLut(b: buffer, n: number, k: number, vals: buffer, lens: buffer): number
	local s, p = 0, 0
	local twoK = bit32.lshift(1, k)
	for _ = 1, n do
		local w = bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7))
		local peek = bit32.band(w, 4095)
		local used = buffer.readu8(lens, peek)
		if used > 0 then
			s += buffer.readu16(vals, peek * 2)
			p += used
		else
			local z = bit32.countrz(w)
			local len = z + k
			s += bit32.band(bit32.rshift(w, z + 1), bit32.lshift(1, len) - 1) + bit32.lshift(1, len) - twoK
			p += 2 * z + 1 + k
		end
	end
	return s
end

local CW_B = buffer.create(16)
for i = 1, 16 do
	buffer.writeu8(CW_B, i - 1, CLASS_W[i])
end
local function decClass(b: buffer, n: number): number
	local s, p = 0, 0
	for _ = 1, n do
		local w = bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7))
		local width = buffer.readu8(CW_B, bit32.band(w, 15))
		if width <= 21 then
			s += bit32.band(bit32.rshift(w, 4), bit32.lshift(1, width) - 1)
		else
			local q = p + 4
			s += buffer.readbits(b, q, 24) + buffer.readbits(b, q + 24, width - 24) * 16777216
		end
		p += 4 + width
	end
	return s
end

local U_SIZE_B, U_LEN_B, U_OFF_B = buffer.create(16), buffer.create(16), buffer.create(64)
for i = 1, 16 do
	buffer.writeu8(U_SIZE_B, i - 1, U_SIZE[i])
	buffer.writeu8(U_LEN_B, i - 1, U_LEN[i])
	buffer.writeu32(U_OFF_B, (i - 1) * 4, U_OFF[i])
end
local function decUnity(b: buffer, n: number): number
	local s, p = 0, 0
	for _ = 1, n do
		local w = bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7))
		local sym = buffer.readu8(U_LUT_B, bit32.band(w, 63))
		local len = buffer.readu8(U_LEN_B, sym)
		local size = buffer.readu8(U_SIZE_B, sym)
		p += len
		if size > 0 then
			s += buffer.readu32(U_OFF_B, sym * 4)
				+ bit32.band(bit32.rshift(buffer.readu32(b, bit32.rshift(p, 3)), bit32.band(p, 7)), bit32.lshift(1, size) - 1)
			p += size
		else
			s += buffer.readu32(U_OFF_B, sym * 4)
		end
	end
	return s
end

------------------------------------------------------------------------------
-- run
------------------------------------------------------------------------------

local function sum(v: { number }): number
	local s = 0
	for i = 1, #v do
		s += v[i]
	end
	return s
end

for _, kind in { "small", "medium" } do
	local vals = makeValues(kind)
	local expect = sum(vals)
	local maxv = 0
	for i = 1, N do
		maxv = math.max(maxv, vals[i])
	end
	local width = 1
	while 2 ^ width <= maxv do
		width += 1
	end
	local k = if kind == "small" then 0 else 4
	local kr = if kind == "small" then 0 else 4
	print(`{kind}: N={N}, mean={expect / N}, max={maxv}, EG k={k}, Rice k={kr}, FOR width={width}`)

	local bLEB = buffer.create(8 * N)
	local nLEB = encLEB(vals, bLEB)
	local bPre = buffer.create(8 * N)
	local nPre = encPrefix(vals, bPre)
	local bVu = buffer.create(8 * N)
	local nVu = encVu(vals, bVu)
	local bGrp = buffer.create(8 * N)
	local nGrp = encGroup(vals, bGrp)
	local cSVB, bSVB = buffer.create(N // 4), buffer.create(8 * N)
	local nSVB = encSVB(vals, cSVB, bSVB) + N // 4
	local bEG = buffer.create(8 * N)
	local nEG = encEG(vals, bEG, k)
	local bRice = buffer.create(8 * N)
	local nRice = encRice(vals, bRice, kr)
	local bFix = buffer.create(8 * N)
	local nFix = encFixedBits(vals, bFix, width)
	local bCls = buffer.create(8 * N)
	local nCls = encClass(vals, bCls)
	local bUni = buffer.create(8 * N)
	local nUni = encUnity(vals, bUni)
	local b8 = buffer.create(N + 4)
	local b16 = buffer.create(2 * N + 4)
	for i = 1, N do
		buffer.writeu8(b8, i - 1, math.min(vals[i], 255))
		buffer.writeu16(b16, 2 * (i - 1), vals[i])
	end
	local e8 = 0
	for i = 1, N do
		e8 += math.min(vals[i], 255)
	end
	print(
		string.format(
			"  sizes (bytes): LEB %d  Prefix %d  vu128 %d  Group %d  SVB %d  EG %d  Rice %d  FOR %d  Class %d  Unity %d",
			nLEB, nPre, nVu, nGrp, nSVB, nEG, nRice, nFix, nCls, nUni
		)
	)
	bench("readu8 (baseline, clamped)", function()
		return decU8(b8, N)
	end, e8)
	bench("readu16 (baseline)", function()
		return decU16(b16, N)
	end, expect)
	bench("LEB128", function()
		return decLEB(bLEB, N)
	end, expect)
	bench("PrefixVarint", function()
		return decPrefix(bPre, N)
	end, expect)
	bench("vu128", function()
		return decVu(bVu, N)
	end, expect)
	bench("GroupVarint", function()
		return decGroup(bGrp, N)
	end, expect)
	bench("StreamVByte", function()
		return decSVB(cSVB, bSVB, N)
	end, expect)
	bench(`Exp-Golomb k={k} (countrz)`, function()
		return decEG(bEG, N, k)
	end, expect)
	local egVals, egLens = makeEGLut(k)
	bench(`Exp-Golomb k={k} (12-bit LUT)`, function()
		return decEGLut(bEG, N, k, egVals, egLens)
	end, expect)
	bench(`Exp-Golomb k={k} (arith ops)`, function()
		return decEGArith(bEG, N, k)
	end, expect)
	bench(`Rice k={kr} (countrz)`, function()
		return decRice(bRice, N, kr)
	end, expect)
	bench(`FOR {width}-bit (readu32 window)`, function()
		return decFixedBits(bFix, N, width)
	end, expect)
	bench(`FOR {width}-bit (buffer.readbits)`, function()
		return decReadbits(bFix, N, width)
	end, expect)
	bench("ClassCode (v5 attempt)", function()
		return decClass(bCls, N)
	end, expect)
	bench("Unity bucket Huffman", function()
		return decUnity(bUni, N)
	end, expect)
	-- encode side (server, often native)
	bench(`encode Exp-Golomb k={k}`, function()
		encEG(vals, bEG, k)
		return expect
	end, expect)
	do
		local chk = buffer.create(8 * N)
		local nfast = encEGFast(vals, chk, k)
		assert(nfast == nEG and buffer.readstring(chk, 0, nfast) == buffer.readstring(bEG, 0, nEG), "fast EG encoder differs")
	end
	bench(`encode Exp-Golomb k={k} (inlined)`, function()
		encEGFast(vals, bEG, k)
		return expect
	end, expect)
	bench("encode LEB128", function()
		encLEB(vals, bLEB)
		return expect
	end, expect)
end
