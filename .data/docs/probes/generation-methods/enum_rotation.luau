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

-- xorshift32 as in v5.md §4.5 (the CLI has no Roblox Random)
local state = 0x12345678
local function nextU32(): number
	state = bit32.bxor(state, bit32.lshift(state, 13))
	state = bit32.bxor(state, bit32.rshift(state, 17))
	state = bit32.bxor(state, bit32.lshift(state, 5))
	return state
end
local rng = {
	NextInteger = function(_, lo: number, hi: number): number return lo + nextU32() % (hi - lo + 1) end,
	NextNumber = function(_): number return nextU32() / 4294967296 end,
}
local function perm(n: number): { number }
	local p: { [number]: number } = {}
	for i = 0, n - 1 do p[i] = i end
	for i = n - 1, 1, -1 do local j = rng:NextInteger(0, i); p[i], p[j] = p[j], p[i] end
	return p
end
local ROWS = 64
local patterns = {
	constant = function(n: number) local t = {}; for i = 1, ROWS do t[i] = 3 % n end; return t end,
	sparse10 = function(n: number) local t, v = {}, 0; for i = 1, ROWS do if rng:NextNumber() < 0.1 then v = rng:NextInteger(0, n - 1) end; t[i] = v end; return t end,
	sequential = function(n: number) local t = {}; for i = 1, ROWS do t[i] = (i - 1) % n end; return t end,
	walk = function(n: number) local t, v = {}, 0; for i = 1, ROWS do v = math.clamp(v + rng:NextInteger(-1, 1), 0, n - 1); t[i] = v end; return t end,
	uniform = function(n: number) local t = {}; for i = 1, ROWS do t[i] = rng:NextInteger(0, n - 1) end; return t end,
}
local order = { "constant", "sparse10", "sequential", "walk", "uniform" }
print("n   pattern     identity  permuted(mean of 200)  offset(random c per trial)")
for _, n in { 4, 8, 32 } do
	for _, name in order do
		local idSum, permSum, offSum, trials = 0, 0, 0, 200
		for _ = 1, trials do
			local codes = patterns[name](n)
			idSum += columnBits(codes, n)
			local p = perm(n)
			local cOff = rng:NextInteger(0, n - 1)
			local pc, oc = {}, {}
			for i, c in codes do pc[i] = p[c]; oc[i] = (c + cOff) % n end
			permSum += columnBits(pc, n)
			offSum += columnBits(oc, n)
		end
		print(string.format("%-3d %-11s %8.1f  %8.1f              %8.1f", n, name, idSum / trials, permSum / trials, offSum / trials))
	end
end
