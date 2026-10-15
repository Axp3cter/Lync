--!optimize 2
-- `acked` CPU: per-viewer predicted column blocks against a shared per-tick history, versus the core's
-- encode-once byte-aligned pieces copied per viewer. Shooter-like row: x, y, z (16-bit quantizer codes),
-- yaw (12-bit angle), pitch (8), hp (7), anim (3), weapon (4), 4 bools; slot 7 bits (128 slots).
-- Server path (run with --codegen for native): per viewer, for each selected row, three baseline lookups
-- in the history ring, Unity's guarded linear prediction on x, y, z, yaw, pitch ("unchanged" on the rest),
-- wrapped residual and zigzag; then per column the reference encoder's search over modes 0-3 and every k,
-- then the bit writes. Client path (interpreted): parse the block (12-bit lookup table EG decode), rebuild
-- each code from its prediction, store it in the per-record baseline store.
-- Usage: luau -O2 [--codegen] acked_cost.luau

local R = 99 -- records, all selected (100-player shooter at 20 Hz under acked: every row fits)
local VIEWERS = 100
local H = 32
local F = 12
local BITS = { 16, 16, 16, 12, 8, 7, 3, 4, 1, 1, 1, 1 }
local LIN = { true, true, true, true, true, false, false, false, false, false, false, false }
local N = {}
for f = 1, F do
	N[f] = 2 ^ BITS[f]
end
local TICKS = 40

-- shared history: H ticks x R records x F codes, f64
local hist = buffer.create(H * R * F * 8)
math.randomseed(5)
local cur = table.create(R * F, 0)
for r = 0, R - 1 do
	for f = 1, F do
		cur[r * F + f] = math.random(0, N[f] - 1)
	end
end
local function stepWorld()
	for r = 0, R - 1 do
		for f = 1, 5 do
			local i = r * F + f
			cur[i] = (cur[i] + math.random(-12, 14)) % N[f]
		end
		if math.random() < 0.05 then
			cur[r * F + 6] = math.random(0, 127)
		end
		for f = 9, 12 do
			if math.random() < 0.02 then
				cur[r * F + f] = 1 - cur[r * F + f]
			end
		end
	end
end
local function writeHist(T)
	local base = (T % H) * R * F
	for r = 0, R - 1 do
		for f = 1, F do
			buffer.writef64(hist, (base + r * F + f - 1) * 8, cur[r * F + f])
		end
	end
end
for T = 0, H - 1 do
	stepWorld()
	writeHist(T)
end
local NOW = H - 1

-- per viewer per record: three acked ticks (newest first), u32
local ackedTicks = buffer.create(VIEWERS * R * 3 * 4)
for v = 0, VIEWERS - 1 do
	for r = 0, R - 1 do
		local o = (v * R + r) * 12
		buffer.writeu32(ackedTicks, o, NOW - 3)
		buffer.writeu32(ackedTicks, o + 4, NOW - 4)
		buffer.writeu32(ackedTicks, o + 8, NOW - 5)
	end
end

local function wrapd(d, n)
	d = d % n
	if d >= (n + 1) // 2 then
		return d - n
	end
	return d
end

local function tdiv16(x)
	if x >= 0 then
		return x // 16
	end
	return -((-x) // 16)
end

local function hget(T, r, f)
	return buffer.readf64(hist, (((T % H) * R + r) * F + f - 1) * 8)
end

-- bit writer
local out = buffer.create(4096)
local acc, nacc, pos = 0, 0, 0
-- 32-bit accumulator writer, LSB first (the bit order of v5.md section 4.1)
local function wbits(v, n) -- n <= 32, v < 2^n
	acc = bit32.bor(acc, bit32.lshift(v, nacc))
	local t = nacc + n
	if t >= 32 then
		buffer.writeu32(out, pos, acc)
		pos += 4
		acc = bit32.rshift(v, 32 - nacc)
		nacc = t - 32
	else
		nacc = t
	end
end
local function wlong(v, n)
	if n <= 32 then
		wbits(v, n)
		return
	end
	local low = v % 4294967296
	wbits(low, 32)
	wbits((v - low) / 4294967296, n - 32)
end
local function blen(q)
	return 32 - bit32.countlz(q)
end
local function wEG(v, k) -- v < 2^31
	local q = bit32.rshift(v, k) + 1
	local z = 31 - bit32.countlz(q)
	local pz = bit32.lshift(1, z)
	if z > 15 then
		wbits(pz, z + 1)
		wbits(q - pz, z)
		if k > 0 then
			wbits(bit32.band(v, bit32.lshift(1, k) - 1), k)
		end
		return
	end
	local word = bit32.bor(bit32.lshift(q - pz, z + 1), pz)
	local len = 2 * z + 1
	if k == 0 then
		wbits(word, len)
	elseif len + k <= 32 then
		wbits(bit32.bor(word, bit32.lshift(bit32.band(v, bit32.lshift(1, k) - 1), len)), len + k)
	else
		wbits(word, len)
		wbits(bit32.band(v, bit32.lshift(1, k) - 1), k)
	end
end
local function flush()
	while nacc > 0 do
		buffer.writeu8(out, pos, acc % 256)
		pos += 1
		acc = acc // 256
		nacc = math.max(0, nacc - 8)
	end
	acc, nacc = 0, 0
end

local POW = table.create(64, 0)
for i = 0, 63 do
	POW[i + 1] = 2 ^ i
end
local costK = table.create(16, 0)
local costS = table.create(16, 0)
local cL1, cD1, cLS, cDS = table.create(34, 0), table.create(34, 0), table.create(34, 0), table.create(34, 0)
-- EG-k bits of v: 2 * blen(v + 2^k) - k - 1 (blen(floor(v / 2^k) + 1) = blen(v + 2^k) - k); codes < 2^31 here
local function encodeColumn(vals, n)
	local nz, lo, hi, gapBits, last = 0, math.huge, -math.huge, 0, 0
	-- exact EG-k cost for every k from O(1) work per value: with L = blen(v) and r the length of v's top
	-- run of one bits, EG-k(v) = k + 1 for k >= L, else 2L - k - 1 + 2 * [k >= L - r] (the carry of v + 2^k)
	for k = 1, 34 do
		cL1[k], cD1[k], cLS[k], cDS[k] = 0, 0, 0, 0
	end
	for i = 1, n do
		local v = vals[i]
		if v < lo then
			lo = v
		end
		if v > hi then
			hi = v
		end
		local Lv = 32 - bit32.countlz(v)
		cL1[Lv + 1] += 1
		if Lv > 0 then
			local rv = Lv - (32 - bit32.countlz(bit32.bxor(v, POW[Lv + 1] - 1)))
			cD1[Lv - rv + 1] += 1
			cD1[Lv + 1] -= 1
		end
		if v ~= 0 then
			nz += 1
			local g = i - 1 - last
			gapBits += 2 * (32 - bit32.countlz(g + 1)) - 1
			last = i
			local u = v - 1
			local Lu = 32 - bit32.countlz(u)
			cLS[Lu + 1] += 1
			if Lu > 0 then
				local ru = Lu - (32 - bit32.countlz(bit32.bxor(u, POW[Lu + 1] - 1)))
				cDS[Lu - ru + 1] += 1
				cDS[Lu + 1] -= 1
			end
		end
	end
	-- fold: cost(k) = (k+1) * #{L <= k} + sum_{L > k} cnt[L] (2L - k - 1) + 2 * carry(k)
	local below1, belowS, carry1, carryS = 0, 0, 0, 0
	local sum1, sumS, cnt1Above, cntSAbove = 0, 0, n, nz
	for Lb = 0, 32 do
		sum1 += cL1[Lb + 1] * (2 * Lb)
		sumS += cLS[Lb + 1] * (2 * Lb)
	end
	for k = 0, 15 do
		below1 += cL1[k + 1]
		belowS += cLS[k + 1]
		sum1 -= cL1[k + 1] * (2 * k)
		sumS -= cLS[k + 1] * (2 * k)
		cnt1Above = n - below1
		cntSAbove = nz - belowS
		carry1 += cD1[k + 1]
		carryS += cDS[k + 1]
		costK[k + 1] = (k + 1) * below1 + sum1 - (k + 1) * cnt1Above + 2 * carry1
		costS[k + 1] = (k + 1) * belowS + sumS - (k + 1) * cntSAbove + 2 * carryS
	end
	if nz == 0 then
		wbits(0, 2)
		return
	end
	local bestK, best, spK, spBest = 0, math.huge, 0, math.huge
	for k = 0, 15 do
		if costK[k + 1] < best then
			best, bestK = costK[k + 1], k
		end
		if costS[k + 1] < spBest then
			spBest, spK = costS[k + 1], k
		end
	end
	best += 6
	spBest += 6 + 2 * (32 - bit32.countlz(nz + 1)) - 1 + gapBits
	local width = 32 - bit32.countlz(hi - lo)
	local forCost = 2 + 2 * (32 - bit32.countlz(lo + 1)) - 1 + 6 + n * width
	if best <= spBest and best <= forCost then
		wbits(1, 2)
		wbits(bestK, 4)
		for i = 1, n do
			wEG(vals[i], bestK)
		end
	elseif spBest <= forCost then
		wbits(2, 2)
		wbits(spK, 4)
		wEG(nz, 0)
		last = 0
		for i = 1, n do
			local v = vals[i]
			if v ~= 0 then
				wEG(i - 1 - last, 0)
				wEG(v - 1, spK)
				last = i
			end
		end
	else
		wbits(3, 2)
		wEG(lo, 0)
		wbits(width, 6)
		for i = 1, n do
			wlong(vals[i] - lo, width)
		end
	end
end

local cols = {}
for c = 1, F + 1 do
	cols[c] = table.create(R, 0)
end
local function encodeViewer(v, T)
	pos, acc, nacc = 0, 0, 0
	wbits(0, 28) -- frame header + toc
	wEG(R - 1, 0)
	wbits(3, 2) -- reference triple: nb = 3, three baselines (ages of record 0; every record shares it here)
	do
		local o = v * R * 12
		local t0, t1, t2 = buffer.readu32(ackedTicks, o), buffer.readu32(ackedTicks, o + 4), buffer.readu32(ackedTicks, o + 8)
		wEG(T - t0 - 1, 0)
		wEG(t0 - t1 - 1, 0)
		wEG(t1 - t2 - 1, 0)
	end
	local slotCol = cols[F + 1]
	local prevSlot = 0
	for r = 0, R - 1 do
		local o = (v * R + r) * 12
		local t0 = buffer.readu32(ackedTicks, o)
		local t1 = buffer.readu32(ackedTicks, o + 4)
		local t2 = buffer.readu32(ackedTicks, o + 8)
		local a0, a1, a2 = T - t0, t0 - t1, t1 - t2
		local af, pf = (16 * a0) // a1, (16 * a1) // a2
		local d = r - prevSlot
		slotCol[r + 1] = if d >= 0 then 2 * d else -2 * d - 1
		prevSlot = r
		for f = 1, F do
			local n = N[f]
			local b0 = hget(t0, r, f)
			local p = b0
			if LIN[f] then
				local b1 = hget(t1, r, f)
				local b2 = hget(t2, r, f)
				local d01 = wrapd(b0 - b1, n)
				local pb = b1 + tdiv16(wrapd(b1 - b2, n) * pf)
				if math.abs(wrapd(b0 - pb, n)) < math.abs(d01) then
					p = (b0 + tdiv16(d01 * af)) % n
				end
			end
			local c = cur[r * F + f]
			local e
			if n == 2 then
				e = if c == p then 0 else 1
			else
				local w = wrapd(c - p, n)
				e = if w >= 0 then 2 * w else -2 * w - 1
			end
			cols[f][r + 1] = e
		end
	end
	encodeColumn(slotCol, R)
	wbits(0, 2) -- own column: mode 0
	for f = 1, F do
		encodeColumn(cols[f], R)
	end
	flush()
	return pos
end

-- core baseline: encode once per record into a 12-byte piece, copy per viewer
local pieces = buffer.create(R * 12)
local frame = buffer.create(1200)
local function copyViewer()
	local p = 4
	for r = 0, R - 1 do
		buffer.copy(frame, p, pieces, r * 12, 12)
		p += 12
	end
	return p
end

-- client decode: 12-bit LUT of (zeros) for EG-0 prefix, from a 32-bit window
local inb = buffer.create(4096 + 8)
local function readWindow(bp)
	local byte = bp // 8
	return (buffer.readu32(inb, byte) // 2 ^ (bp % 8)) % 16777216 -- 24 bits, LSB first
end
local store = table.create(R * F, 0)
local function decodeClient(T)
	local bp = 28
	local function rbits(n)
		local v = 0
		local got = 0
		while got < n do
			local take = math.min(16, n - got)
			local w = readWindow(bp)
			v += (w % 2 ^ take) * 2 ^ got
			bp += take
			got += take
		end
		return v
	end
	local function rEG(k)
		local w = readWindow(bp)
		local z = if w == 0 then 24 else bit32.countrz(w)
		bp += z + 1
		local q = 2 ^ z + rbits(z) - 1
		if k > 0 then
			q = q * 2 ^ k + rbits(k)
		end
		return q
	end
	local n = rEG(0) + 1
	local nb = rbits(2)
	local A0, A1, A2 = rEG(0) + 1, rEG(0) + 1, rEG(0) + 1
	local function readColumn(dst)
		local mode = rbits(2)
		if mode == 0 then
			for i = 1, n do
				dst[i] = 0
			end
		elseif mode == 1 then
			local k = rbits(4)
			for i = 1, n do
				dst[i] = rEG(k)
			end
		elseif mode == 2 then
			local k = rbits(4)
			local m = rEG(0)
			for i = 1, n do
				dst[i] = 0
			end
			local at = 0
			for _ = 1, m do
				at += rEG(0) + 1
				dst[at] = rEG(k) + 1
			end
		else
			local lo = rEG(0)
			local width = rbits(6)
			for i = 1, n do
				dst[i] = lo + rbits(width)
			end
		end
	end
	local slotCol = cols[F + 1]
	readColumn(slotCol)
	local _own = rbits(2)
	for f = 1, F do
		readColumn(cols[f])
	end
	-- rebuild codes from predictions (client keeps its baselines in `hist`-shaped store here)
	local t0, t1, t2 = T - A0, T - A0 - A1, T - A0 - A1 - A2
	local af, pf = (16 * A0) // A1, (16 * A1) // A2
	local slot = 0
	for i = 1, n do
		local e0 = slotCol[i]
		slot += if e0 % 2 == 0 then e0 // 2 else -(e0 + 1) // 2
		local r = slot
		for f = 1, F do
			local nn = N[f]
			local b0 = hget(t0, r, f)
			local p = b0
			if LIN[f] then
				local b1 = hget(t1, r, f)
				local b2 = hget(t2, r, f)
				local d01 = wrapd(b0 - b1, nn)
				local pb = b1 + tdiv16(wrapd(b1 - b2, nn) * pf)
				if math.abs(wrapd(b0 - pb, nn)) < math.abs(d01) then
					p = (b0 + tdiv16(d01 * af)) % nn
				end
			end
			local e = cols[f][i]
			local c
			if nn == 2 then
				c = if e == 0 then p else 1 - p
			else
				local w = if e % 2 == 0 then e // 2 else -(e + 1) // 2
				c = (p + w) % nn
			end
			store[r * F + f] = c
		end
	end
	return n, nb
end

local function bench(name, reps, fn)
	local best = math.huge
	for _ = 1, 7 do
		local t = os.clock()
		for i = 1, reps do
			fn(i)
		end
		best = math.min(best, os.clock() - t)
	end
	return best / reps
end

stepWorld()
local T = NOW + 1
writeHist(T)
local bytes = encodeViewer(0, T)
buffer.copy(inb, 0, out, 0, bytes)
local n = decodeClient(T)
-- verify round trip
for r = 0, R - 1 do
	for f = 1, F do
		assert(store[r * F + f] == cur[r * F + f], "round trip mismatch")
	end
end
print(string.format("rows %d, fields %d, block %d B (core pieces %d B); round trip ok (%d rows)", R, F, bytes,
	4 + 1 + R * 12, n))
local tEnc = bench("encode", 20, function(i)
	encodeViewer(i % VIEWERS, T)
end)
local tCopy = bench("copy", 2000, function()
	copyViewer()
end)
local tDec = bench("decode", 20, function()
	decodeClient(T)
end)
print(string.format("server encode per viewer: %.1f us (%.1f ns per row); core copy per viewer %.2f us (%.1f ns per row)",
	tEnc * 1e6, tEnc * 1e9 / R, tCopy * 1e6, tCopy * 1e9 / R))
print(string.format("at %d viewers x %d rows x 20 Hz: acked %.1f ms/s, core copy %.2f ms/s", VIEWERS, R,
	tEnc * VIEWERS * 20 * 1e3, tCopy * VIEWERS * 20 * 1e3))
print(string.format("client decode + rebuild per frame: %.1f us (%.1f ns per row); 20 Hz: %.2f ms/s, 60 Hz: %.2f ms/s",
	tDec * 1e6, tDec * 1e9 / R, tDec * 20 * 1e3, tDec * 60 * 1e3))
