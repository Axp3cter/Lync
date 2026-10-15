--!strict
-- Claim 11(d): rotating union variant and list-enum order per build was kept out on "a permutation can turn
-- DELTA and RUNS columns into PACKED ... <= 2 bits per column worse; do not permute them" (client-security.md
-- §3.4, a draft-wire figure; R14). Re-derived for v5's column coder (v5.md §4.3): per column the cheapest of
-- mode 0 (all zero), 1 (EG-k), 2 (sparse) and 3 (frame of reference), every k, on residuals = code - previous
-- row's code wrapped modulo the item count and zigzagged. Bits of one column block, identity order against the
-- mean and worst over 200 random permutations of the item indices, per value pattern. Single rows write
-- u(ceil(log2 n)) whatever the order, so they are unaffected.
-- Run: luau -O2 enum_rotation.luau
local function bitlen(x: number): number
	local n = 0
	while x > 0 do x = x // 2; n += 1 end
	return n
end
local function eg0(x: number): number return 2 * bitlen(x + 1) - 1 end
local function egk(u: number, k: number): number return eg0(u // 2 ^ k) + k end
local function zz(r: number): number return if r >= 0 then 2 * r else -2 * r - 1 end

local function columnBits(codes: { number }, n: number): number
	local rows = #codes
	local u = table.create(rows, 0)
	local prev, half = 0, n // 2
	local allzero = true
	for i = 1, rows do
		local r = codes[i] - prev
		if r >= n - half then r -= n elseif r < -half then r += n end
		u[i] = zz(r)
		if u[i] ~= 0 then allzero = false end
		prev = codes[i]
	end
	if allzero then return 2 end
	local best = math.huge
	for k = 0, 15 do
		local m1, m2, nz, gap = 6, 6, 0, 0
		local pairs = 0
		for i = 1, rows do
			m1 += egk(u[i], k)
			if u[i] == 0 then
				gap += 1
			else
				pairs += eg0(gap) + egk(u[i] - 1, k)
				nz += 1
				gap = 0
			end
		end
		m2 += eg0(nz) + pairs
		best = math.min(best, m1, m2)
	end
	local lo, hi = math.huge, 0
	for i = 1, rows do lo = math.min(lo, u[i]); hi = math.max(hi, u[i]) end
	best = math.min(best, 2 + eg0(lo) + 6 + rows * bitlen(hi - lo))
	return best
end

local seed = 7
local function rnd(n: number): number
	seed = (seed * 48271) % 2147483647
	return seed % n
end
local function patterns(n: number, rows: number): { [string]: { number } }
	local p: { [string]: { number } } = {}
	local c, sp, walk, asc, rnd2, runs = {}, {}, {}, {}, {}, {}
	local w = rnd(n)
	for i = 1, rows do
		c[i] = 3 % n
		sp[i] = if rnd(10) == 0 then rnd(n) else 0
		if rnd(3) == 0 then w = math.clamp(w + (if rnd(2) == 0 then -1 else 1), 0, n - 1) end
		walk[i] = w
		asc[i] = math.min(n - 1, (i - 1) * n // rows)
		rnd2[i] = rnd(n)
		runs[i] = ((i - 1) // 8) % n
	end
	p["constant"], p["10% sparse"], p["+-1 walk"], p["ascending"], p["uniform random"], p["runs of 8, +1 steps"] = c, sp, walk, asc, rnd2, runs
	return p
end
print("items n | rows | pattern | identity bits | permuted mean | permuted max | mean delta (bits per column)")
for _, n in { 4, 8, 32 } do
	for _, rows in { 8, 64 } do
		local pats = patterns(n, rows)
		local names = {}
		for name in pats do table.insert(names, name) end
		table.sort(names)
		for _, name in names do
			local codes = pats[name]
			local id = columnBits(codes, n)
			local sum, mx = 0, 0
			for _ = 1, 200 do
				local perm = table.create(n, 0)
				for i = 1, n do perm[i] = i - 1 end
				for i = n, 2, -1 do
					local j = rnd(i) + 1
					perm[i], perm[j] = perm[j], perm[i]
				end
				local pc = table.create(rows, 0)
				for i = 1, rows do pc[i] = perm[codes[i] + 1] end
				local b = columnBits(pc, n)
				sum += b
				mx = math.max(mx, b)
			end
			print(string.format("%3d | %3d | %-20s | %5d | %8.1f | %5d | %+6.1f", n, rows, name, id, sum / 200, mx, sum / 200 - id))
		end
	end
end
