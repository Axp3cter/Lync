--!strict
-- M5 byte cost: the column coder's mode and k are free choices any decoder accepts (v5.md §4.3, §4.8). If a build
-- fixed a column's mode by seed instead of taking the fewest bits, what does the column cost? Per pattern: bits of
-- the reference choice, and the mean over modes 1-3 (each at its best k) of the extra bits. 64 rows, 200 trials.
local function bitlen(x: number): number local z = 0; while x > 0 do x = x // 2; z += 1 end; return z end
local function eg0(x: number): number return 2 * (bitlen(x + 1) - 1) + 1 end
local function egk(u: number, k: number): number return eg0(u // 2 ^ k) + k end
local function zig(v: number): number return if v >= 0 then 2 * v else -2 * v - 1 end
local function modes(codes: { number }, n: number): (number, number, number, number)
	local z, prev = {}, 0
	local lo, hi = -(n // 2), math.ceil(n / 2) - 1
	for i, c in codes do local r = c - prev; if r > hi then r -= n elseif r < lo then r += n end; z[i] = zig(r); prev = c end
	local allZero = true
	for _, v in z do if v ~= 0 then allZero = false end end
	local m1, m2 = math.huge, math.huge
	for k = 0, 15 do local s = 6; for _, v in z do s += egk(v, k) end; m1 = math.min(m1, s) end
	for k = 0, 15 do
		local m, gap, body = 0, 0, 0
		for _, v in z do if v == 0 then gap += 1 else body += eg0(gap) + egk(v - 1, k); m += 1; gap = 0 end end
		m2 = math.min(m2, 6 + eg0(m) + body)
	end
	local mn, mx = math.huge, 0
	for _, v in z do mn = math.min(mn, v); mx = math.max(mx, v) end
	local m3 = 2 + eg0(mn) + 6 + #z * bitlen(mx - mn)
	local best = if allZero then 2 else math.min(m1, m2, m3)
	return best, m1, m2, m3
end
local state = 0x1234567
local function u(): number state = bit32.bxor(state, bit32.lshift(state, 13)); state = bit32.bxor(state, bit32.rshift(state, 17)); state = bit32.bxor(state, bit32.lshift(state, 5)); return state end
local function int(lo: number, hi: number): number return lo + u() % (hi - lo + 1) end
local gen = {
	constant = function(n: number) local t = {}; for i = 1, 64 do t[i] = 3 % n end; return t end,
	sparse10 = function(n: number) local t, v = {}, 0; for i = 1, 64 do if u() / 4294967296 < 0.1 then v = int(0, n - 1) end; t[i] = v end; return t end,
	walk = function(n: number) local t, v = {}, 0; for i = 1, 64 do v = math.clamp(v + int(-1, 1), 0, n - 1); t[i] = v end; return t end,
	uniform = function(n: number) local t = {}; for i = 1, 64 do t[i] = int(0, n - 1) end; return t end,
}
print("n     pattern    reference  mean extra if the mode is fixed per build (modes 1-3, best k each)")
for _, n in { 32, 4096 } do
	for _, name in { "constant", "sparse10", "walk", "uniform" } do
		local sb, se = 0, 0
		for _ = 1, 200 do
			local best, m1, m2, m3 = modes(gen[name](n), n)
			sb += best; se += ((m1 - best) + (m2 - best) + (m3 - best)) / 3
		end
		print(string.format("%-5d %-10s %8.1f   +%.1f bits (+%.0f%%)", n, name, sb / 200, se / 200, 100 * se / sb))
	end
end
