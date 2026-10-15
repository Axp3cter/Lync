--!strict
-- Claims 5, 6 and 11(e): per-viewer encoding costs cited against low-order watermarks (v5-changes.md:115, :561;
-- R17), decoys (v5-integrity.md §8, v5-changes.md:554) and per-viewer slot permutation (v5-changes.md:114,
-- :566; R15).
-- Part A, `:newest()` rows (absolute rows, encoded once per state tick, copied per viewer): one row is slot u6,
-- position 3 x u18, rotation flag+u2+3 x u9 = 90 bits in 12 bytes. Per viewer, 32 of 64 rows:
--   copy               : encode-once, buffer.copy per row (baseline: what every viewer costs now)
--   re-encode + mark   : per-viewer re-encode from cached codes with a watermark in the low bit of x, y, z
--   copy + mark patch  : copy, then XOR the 3 low bits at their known bit offsets (generated offsets)
--   copy + slot patch  : copy, then rewrite the 6-bit slot from a per-viewer permutation (R15)
-- Part B, decoys in a reliable partition state chunk (column-coded, v5.md §4.3; 5 int columns, 19 changed
-- records of 64): per viewer with d decoys mixed in, d = 1, 16, 256:
--   copy               : encode-once copy (viewers without decoys)
--   re-encode, full k  : the per-viewer re-encode the design specifies (zero / EG-k with every k costed)
--   re-encode, shared k: the same, reusing the shared chunk's per-column k-cost sums and adding the decoy rows'
--                        and their neighbours' deltas (a cheaper implementation), then writing
--   behaviour + diff   : the per-viewer behaviour call and diff (v5-integrity.md §8's 236 ns figure)
-- Run: luau -O2 per_viewer.luau ; luau -O2 --codegen per_viewer.luau
local H = require("./harness")
local bor, band, bxor, lshift, rshift, countlz = bit32.bor, bit32.band, bit32.bxor, bit32.lshift, bit32.rshift, bit32.countlz
local writeu32, readu8, writeu8 = buffer.writeu32, buffer.readu8, buffer.writeu8

------------------------------------------------------------------ Part A
local R = 64
local codes = table.create(R) :: { { number } }
for i = 1, R do
	codes[i] = { i - 1, (i * 4099) % 131073, (i * 911) % 131073, (i * 7919) % 131073, 0, i % 4, (i * 3) % 512, (i * 5) % 512, (i * 7) % 512 }
end
local function encRow(b: buffer, o: number, c: { number }, mark: number)
	local slot, x, y, z, flag, idx, a, bb, cc = c[1], bxor(c[2], mark), bxor(c[3], mark), bxor(c[4], mark), c[5], c[6], c[7], c[8], c[9]
	writeu32(b, o, bor(slot, lshift(x, 6), lshift(band(y, 0xff), 24)))
	writeu32(b, o + 4, bor(rshift(y, 8), lshift(z, 10), lshift(flag, 28), lshift(idx, 29), lshift(band(a, 1), 31)))
	writeu32(b, o + 8, bor(rshift(a, 1), lshift(bb, 8), lshift(cc, 17)))
end
local shared = buffer.create(R * 12)
for i = 1, R do encRow(shared, (i - 1) * 12, codes[i], 0) end
local sel = table.create(32, 0)
for j = 1, 32 do sel[j] = (j * 2 - 1) % R end -- the scheduler's 32 rows for this viewer
local out = buffer.create(32 * 12)
local viewerMarks = table.create(32, 0)
for j = 1, 32 do viewerMarks[j] = (j * 5) % 2 end -- one watermark bit per row from the viewer's pattern
local viewerSlots = table.create(R, 0)
for s = 0, R - 1 do viewerSlots[s + 1] = (s * 37 + 11) % R end

-- check: patching the copy gives the same bytes as re-encoding with the mark
do
	local a, b2 = buffer.create(32 * 12), buffer.create(32 * 12)
	for j = 1, 32 do
		local s = sel[j]
		encRow(a, (j - 1) * 12, codes[s + 1], viewerMarks[j])
		buffer.copy(b2, (j - 1) * 12, shared, s * 12, 12)
		if viewerMarks[j] == 1 then
			local o = (j - 1) * 12
			writeu8(b2, o, bxor(readu8(b2, o), 0x40)); writeu8(b2, o + 3, bxor(readu8(b2, o + 3), 0x01)); writeu8(b2, o + 5, bxor(readu8(b2, o + 5), 0x04))
		end
	end
	assert(buffer.tostring(a) == buffer.tostring(b2), "mark patch differs from re-encode")
	print("check: copy + mark patch equals a per-viewer re-encode with the mark")
end

local NA = 20000
H.compare("newest rows: one viewer's 32 rows per state tick (time per viewer)", NA, {
	{ name = "copy (encode-once)", fn = function(n)
		for _ = 1, n do
			for j = 1, 32 do buffer.copy(out, (j - 1) * 12, shared, sel[j] * 12, 12) end
		end
		return readu8(out, 0)
	end },
	{ name = "re-encode + mark", fn = function(n)
		for _ = 1, n do
			for j = 1, 32 do encRow(out, (j - 1) * 12, codes[sel[j] + 1], viewerMarks[j]) end
		end
		return readu8(out, 0)
	end },
	{ name = "copy + mark patch", fn = function(n)
		for _ = 1, n do
			for j = 1, 32 do
				local o = (j - 1) * 12
				buffer.copy(out, o, shared, sel[j] * 12, 12)
				if viewerMarks[j] == 1 then
					writeu8(out, o, bxor(readu8(out, o), 0x40))
					writeu8(out, o + 3, bxor(readu8(out, o + 3), 0x01))
					writeu8(out, o + 5, bxor(readu8(out, o + 5), 0x04))
				end
			end
		end
		return readu8(out, 0)
	end },
	{ name = "copy + slot patch (R15)", fn = function(n)
		for _ = 1, n do
			for j = 1, 32 do
				local o = (j - 1) * 12
				local s = sel[j]
				buffer.copy(out, o, shared, s * 12, 12)
				writeu8(out, o, bor(band(readu8(out, o), 0xC0), viewerSlots[s + 1]))
			end
		end
		return readu8(out, 0)
	end },
})

------------------------------------------------------------------ Part B: column coder
type Wr = { b: buffer, pos: number, acc: number, n: number }
local function put(w: Wr, v: number, width: number)
	-- v < 2^width, width <= 32
	if width == 0 then return end
	local n = w.n
	w.acc = bor(w.acc, lshift(v, n))
	n += width
	if n >= 32 then
		writeu32(w.b, w.pos, w.acc)
		w.pos += 4
		n -= 32
		w.acc = if n > 0 then rshift(v, width - n) else 0
	end
	w.n = n
end
local function bitlen(x: number): number
	return 32 - countlz(x)
end
local function egk(w: Wr, u: number, k: number)
	local q = rshift(u, k) + 1
	local z = bitlen(q) - 1
	put(w, 0, z)
	put(w, 1, 1)
	put(w, q - lshift(1, z), z)
	put(w, band(u, lshift(1, k) - 1), k)
end
local function zz(r: number): number
	return if r >= 0 then 2 * r else -2 * r - 1
end
local function egcost(u: number, k: number): number
	return 2 * (bitlen(rshift(u, k) + 1) - 1) + 1 + k
end
-- residual column of codes on [0, n)
local function residuals(col: { number }, rows: number, n: number, out: { number })
	local prev = 0
	local half = n // 2
	for i = 1, rows do
		local r = col[i] - prev
		if r >= n - half then r -= n elseif r < -half then r += n end
		out[i] = zz(r)
		prev = col[i]
	end
end
local K = 16
-- full search: cost every k; mode 0 when all zero
local function choose(u: { number }, rows: number, costs: { number }): number
	local allzero = true
	for k = 0, K - 1 do costs[k + 1] = 0 end
	for i = 1, rows do
		local x = u[i]
		if x ~= 0 then allzero = false end
		for k = 0, K - 1 do costs[k + 1] += egcost(x, k) end
	end
	if allzero then return -1 end
	local best, bk = math.huge, 0
	for k = 0, K - 1 do
		if costs[k + 1] < best then best, bk = costs[k + 1], k end
	end
	return bk
end
local function writeCol(w: Wr, u: { number }, rows: number, k: number)
	if k < 0 then put(w, 0, 2); return end
	put(w, 1, 2); put(w, k, 4)
	for i = 1, rows do egk(w, u[i], k) end
end

local COLS = 5
local NCODE = { 101, 1024, 65536, 2, 8 } -- health, ammo, score, team, flags code counts
local REAL = 19
local realCols = table.create(COLS) :: { { number } }
for c = 1, COLS do
	realCols[c] = table.create(REAL, 0)
	for i = 1, REAL do realCols[c][i] = (i * (c * 7 + 3) + c) % NCODE[c] end
end
local maxD = 256
local decoyCols = table.create(COLS) :: { { number } }
for c = 1, COLS do
	decoyCols[c] = table.create(maxD, 0)
	for i = 1, maxD do decoyCols[c][i] = (i * 13 + c * 5) % NCODE[c] end
end
-- the shared chunk's residuals and per-k costs, computed once per flush for every viewer
local sharedU = table.create(COLS) :: { { number } }
local sharedCost = table.create(COLS) :: { { number } }
for c = 1, COLS do
	sharedU[c] = table.create(REAL, 0)
	residuals(realCols[c], REAL, NCODE[c], sharedU[c])
	sharedCost[c] = table.create(K, 0)
	choose(sharedU[c], REAL, sharedCost[c])
end
local chunkW: Wr = { b = buffer.create(65536), pos = 0, acc = 0, n = 0 }
local function encodeShared(w: Wr)
	w.pos, w.acc, w.n = 0, 0, 0
	for c = 1, COLS do
		local costs = table.create(K, 0)
		local k = choose(sharedU[c], REAL, costs)
		writeCol(w, sharedU[c], REAL, k)
	end
	writeu32(w.b, w.pos, w.acc)
	return w.pos + 4
end
local sharedLen = encodeShared(chunkW)
local sharedBuf = buffer.create(sharedLen)
buffer.copy(sharedBuf, 0, chunkW.b, 0, sharedLen)

-- per-viewer chunk: the real rows with the viewer's d decoys interleaved (decoy j after real row j*REAL//d + 1)
local mixed = table.create(COLS) :: { { number } }
local mixedU = table.create(COLS) :: { { number } }
for c = 1, COLS do
	mixed[c] = table.create(REAL + maxD, 0)
	mixedU[c] = table.create(REAL + maxD, 0)
end
local function mix(d: number): number
	-- slot order: decoys take pool slots spread among the real ones
	local rows = 0
	local ri, di = 1, 1
	while ri <= REAL or di <= d do
		local takeDecoy = di <= d and (ri > REAL or (di - 1) * REAL < (ri - 1) * d)
		rows += 1
		for c = 1, COLS do
			mixed[c][rows] = if takeDecoy then decoyCols[c][di] else realCols[c][ri]
		end
		if takeDecoy then di += 1 else ri += 1 end
	end
	return rows
end
local vW: Wr = { b = buffer.create(65536), pos = 0, acc = 0, n = 0 }
local costs = table.create(K, 0)
local function reencodeFull(d: number): number
	local rows = mix(d)
	vW.pos, vW.acc, vW.n = 0, 0, 0
	for c = 1, COLS do
		residuals(mixed[c], rows, NCODE[c], mixedU[c])
		local k = choose(mixedU[c], rows, costs)
		writeCol(vW, mixedU[c], rows, k)
	end
	return vW.pos
end
-- shared-k variant: the k costs of the mixed column = shared costs - removed residuals + new residuals.
-- With d decoys inserted, the residuals that change are the d decoy rows and the real row after each decoy run.
-- This implementation recomputes residuals (O(rows)) but costs k only over the changed rows (O(changed x K)).
local isDecoyRow = table.create(REAL + maxD, false)
local function reencodeSharedK(d: number): number
	local rows = mix(d)
	-- mark which mixed rows are decoys, and which real rows follow a decoy (their residual changed)
	local ri, di = 1, 1
	for r = 1, rows do
		local takeDecoy = di <= d and (ri > REAL or (di - 1) * REAL < (ri - 1) * d)
		isDecoyRow[r] = takeDecoy
		if takeDecoy then di += 1 else ri += 1 end
	end
	vW.pos, vW.acc, vW.n = 0, 0, 0
	for c = 1, COLS do
		local u = mixedU[c]
		residuals(mixed[c], rows, NCODE[c], u)
		for k = 1, K do costs[k] = sharedCost[c][k] end
		local sU = sharedU[c]
		local rr = 0
		local allzero = true
		for r = 1, rows do
			local x = u[r]
			if x ~= 0 then allzero = false end
			if isDecoyRow[r] then
				for k = 0, K - 1 do costs[k + 1] += egcost(x, k) end
			else
				rr += 1
				if r > 1 and isDecoyRow[r - 1] then
					local old = sU[rr]
					for k = 0, K - 1 do costs[k + 1] += egcost(x, k) - egcost(old, k) end
				end
			end
		end
		local bk = -1
		if not allzero then
			local best = math.huge
			for k = 0, K - 1 do
				if costs[k + 1] < best then best, bk = costs[k + 1], k end
			end
		end
		writeCol(vW, u, rows, bk)
	end
	return vW.pos
end
-- check: both re-encoders choose the same k, so they write the same bytes
for _, d in { 1, 16, 256 } do
	local a = reencodeFull(d)
	local sa = buffer.readstring(vW.b, 0, a)
	local b2 = reencodeSharedK(d)
	assert(a == b2 and buffer.readstring(vW.b, 0, b2) == sa, "shared-k re-encode differs at d " .. d)
end
print("check: shared-k re-encode writes the same bytes as the full search at d = 1, 16, 256")

-- behaviour + diff (the design's per-viewer per-state-tick call), as in review-redundancy-2/integrity_state
local prev = { name = "Decoy", team = "red", health = 100, x = 1, y = 2, z = 3 }
local function behaviour(viewer: number, tick: number): { [number]: any }?
	return { [9000 + viewer] = { name = "Decoy", team = "red", health = 100, x = tick % 7, y = 2, z = 3 } }
end

local vout = buffer.create(65536)
for _, d in { 1, 16, 256 } do
	H.compare(string.format("decoys: one viewer's partition state chunk per flush, %d real changed rows + %d decoys, 5 columns", REAL, d), math.max(200, 40000 // (d + 19)), {
		{ name = "copy (no decoys)", fn = function(n)
			for _ = 1, n do buffer.copy(vout, 0, sharedBuf, 0, sharedLen) end
			return sharedLen
		end },
		{ name = "re-encode, full k search", fn = function(n)
			local s = 0
			for _ = 1, n do s += reencodeFull(d) end
			return s
		end },
		{ name = "re-encode, shared k costs", fn = function(n)
			local s = 0
			for _ = 1, n do s += reencodeSharedK(d) end
			return s
		end },
		{ name = "behaviour + diff (1 decoy)", fn = function(n)
			local ch = 0
			for i = 1, n do
				local res = behaviour(i % 100, i)
				if res then
					for _, rec in res do
						for f, v in rec do
							if prev[f] ~= v then ch += 1 end
						end
					end
				end
			end
			return ch
		end },
	})
end
print(string.format("shared chunk %d B; per-viewer chunk bytes: d=1 %d B, d=16 %d B, d=256 %d B", sharedLen, reencodeFull(1) + 4, reencodeFull(16) + 4, reencodeFull(256) + 4))
print("sink", H.sink)
