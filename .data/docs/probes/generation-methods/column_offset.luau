--!strict
-- Bits of one v5 integer column (v5.md §4.3) over 64 rows of an n-code enum or union index,
-- with identity order, a random per-build permutation of the codes, and a constant per-build offset.
-- Modes: 0 zero, 1 EG-k (k 0..15), 2 sparse, 3 frame of reference; reference encoder = fewest bits.
local function bitlen(x: number): number
	local z = 0
	while x > 0 do x = x // 2; z += 1 end
	return z
end
local function eg0(x: number): number -- EG-0 of x >= 0
	local z = bitlen(x + 1) - 1
	return 2 * z + 1
end
local function egk(u: number, k: number): number
	return eg0(u // 2 ^ k) + k
end
local function zig(v: number): number
	return if v >= 0 then 2 * v else -2 * v - 1
end
local function residuals(codes: { number }, n: number): { number }
	local out, prev = {}, 0
	local lo, hi = -(n // 2), math.ceil(n / 2) - 1
	for i, c in codes do
		local r = c - prev
		if r > hi then r -= n elseif r < lo then r += n end
		out[i] = zig(r)
		prev = c
	end
	return out
end
local function columnBits(codes: { number }, n: number): number
	local z = residuals(codes, n)
	local allZero = true
	for _, v in z do if v ~= 0 then allZero = false end end
	if allZero then return 2 end
	local best = math.huge
	for k = 0, 15 do -- mode 1
		local s = 2 + 4
		for _, v in z do s += egk(v, k) end
		best = math.min(best, s)
	end
	for k = 0, 15 do -- mode 2 sparse
		local s, m, gap = 2 + 4, 0, 0
		local body = 0
		for _, v in z do
			if v == 0 then gap += 1 else body += eg0(gap) + egk(v - 1, k); m += 1; gap = 0 end
		end
		best = math.min(best, s + eg0(m) + body)
	end
	local mn, mx = math.huge, 0 -- mode 3
	for _, v in z do mn = math.min(mn, v); mx = math.max(mx, v) end
	best = math.min(best, 2 + eg0(mn) + 6 + #z * bitlen(mx - mn))
	return best
end

-- (functions above are enum_rotation.luau's v5 column model, copied unchanged)
-- M3 under the column coder: a per-build offset c applied to every code, mod n, with
--   (A) the first row's residual against 0 (v5.md §4.3 today), and
--   (B) the first row's residual against c (the baseline offset too).
-- Claim checked: (B) gives the identical residual stream, so identical bits, for every pattern and every c.
local function residualsFrom(codes: { number }, n: number, base: number): { number }
	local out, prev = {}, base
	local lo, hi = -(n // 2), math.ceil(n / 2) - 1
	for i, c in codes do
		local r = c - prev
		if r > hi then r -= n elseif r < lo then r += n end
		out[i] = zig(r)
		prev = c
	end
	return out
end
local state = 0x2545F491
local function nextU32(): number
	state = bit32.bxor(state, bit32.lshift(state, 13)); state = bit32.bxor(state, bit32.rshift(state, 17)); state = bit32.bxor(state, bit32.lshift(state, 5))
	return state
end
local function int(lo: number, hi: number): number return lo + nextU32() % (hi - lo + 1) end
local ROWS = 64
local gen = {
	constant = function(n: number) local t = {}; for i = 1, ROWS do t[i] = 3 % n end; return t end,
	sparse10 = function(n: number) local t, v = {}, 0; for i = 1, ROWS do if nextU32() / 4294967296 < 0.1 then v = int(0, n - 1) end; t[i] = v end; return t end,
	sequential = function(n: number) local t = {}; for i = 1, ROWS do t[i] = (i - 1) % n end; return t end,
	walk = function(n: number) local t, v = {}, 0; for i = 1, ROWS do v = math.clamp(v + int(-1, 1), 0, n - 1); t[i] = v end; return t end,
	uniform = function(n: number) local t = {}; for i = 1, ROWS do t[i] = int(0, n - 1) end; return t end,
}
local function bitsOf(z: { number }): number
	-- columnBits recomputes residuals from codes; feed it codes whose residual-against-0 stream equals z instead:
	-- rebuild codes from z under base 0 is not needed, so score z directly with the same mode costs.
	local allZero = true
	for _, v in z do if v ~= 0 then allZero = false end end
	if allZero then return 2 end
	local best = math.huge
	for k = 0, 15 do local s = 6; for _, v in z do s += egk(v, k) end; best = math.min(best, s) end
	for k = 0, 15 do
		local m, gap, body = 0, 0, 0
		for _, v in z do if v == 0 then gap += 1 else body += eg0(gap) + egk(v - 1, k); m += 1; gap = 0 end end
		best = math.min(best, 6 + eg0(m) + body)
	end
	local mn, mx = math.huge, 0
	for _, v in z do mn = math.min(mn, v); mx = math.max(mx, v) end
	return math.min(best, 2 + eg0(mn) + 6 + #z * bitlen(mx - mn))
end
print("n    pattern     identity  offset,base0  offset,base c   (mean bits over 200 trials, 64 rows)")
for _, n in { 4, 8, 32, 101, 4096 } do
	for _, name in { "constant", "sparse10", "sequential", "walk", "uniform" } do
		local sI, sA, sB = 0, 0, 0
		for _ = 1, 200 do
			local codes = gen[name](n)
			local c = int(0, n - 1)
			local oc = {}
			for i, v in codes do oc[i] = (v + c) % n end
			local zI = residualsFrom(codes, n, 0)
			local zA = residualsFrom(oc, n, 0)
			local zB = residualsFrom(oc, n, c)
			for i = 1, #zI do assert(zI[i] == zB[i], "base-c residuals differ") end
			assert(bitsOf(zI) == columnBits(codes, n), "model mismatch")
			sI += bitsOf(zI); sA += bitsOf(zA); sB += bitsOf(zB)
		end
		print(string.format("%-4d %-11s %8.1f  %10.1f  %12.1f", n, name, sI / 200, sA / 200, sB / 200))
	end
end
print("base-c residual streams equal identity's in every trial: ok")
-- exact offset arithmetic up to n = 2^53: (q + c) mod n without forming q + c >= 2^53
local function addMod(q: number, c: number, n: number): number return if q >= n - c then q - (n - c) else q + c end
local function subMod(w: number, c: number, n: number): number return if w < c then w + (n - c) else w - c end
for _, n in { 2 ^ 53, 2 ^ 53 - 1, 2 ^ 52 + 1 } do
	for _, q in { 0, 1, n - 2, n - 1, math.floor(n / 2) } do
		for _, c in { 1, n - 1, math.floor(n / 3) } do
			local w = addMod(q, c, n)
			assert(w >= 0 and w < n and w == math.floor(w), "range")
			assert(subMod(w, c, n) == q, "inverse " .. n .. " " .. q .. " " .. c)
		end
	end
end
print("addMod/subMod exact at n = 2^53, 2^53-1, 2^52+1: ok")
