--!strict
-- Claim 9: "Clock beacon: one 66-slope fit per 5 s per player" (v5-integrity.md §6, v5-changes.md:551; CPU
-- unmeasured). The fit: Theil-Sen slope over the last 12 window minima (5 s apart): the median of the 66 pairwise
-- slopes. Cases per fit:
--   table.sort      : build the 66 slopes in a reused array, table.sort, take the median (baseline)
--   quickselect     : the same slopes, median by quickselect
--   generated       : windows 5 s apart, so slope(i, j) = (y_j - y_i) / (5 (j - i)); the 66 pairs and their
--                     divisors are build-time constants, unrolled, then quickselect
-- plus the per-beacon window update (min of arrival - stamp).
-- Run: luau -O2 clock_fit.luau ; luau -O2 --codegen clock_fit.luau
local H = require("./harness")

local W = 12
local ys = table.create(W, 0)
local function fill(seed: number)
	for i = 1, W do ys[i] = 0.05 + 0.0002 * 5 * i + ((i * 7919 + seed) % 97) / 97 * 0.03 end
end
local slopes = table.create(66, 0)
local function sortFit(): number
	local k = 0
	for i = 1, W - 1 do
		for j = i + 1, W do
			k += 1
			slopes[k] = (ys[j] - ys[i]) / (5 * (j - i))
		end
	end
	table.sort(slopes)
	return (slopes[33] + slopes[34]) / 2
end
local function select(a: { number }, n: number, kth: number): number
	local lo, hi = 1, n
	while lo < hi do
		local p = a[(lo + hi) // 2]
		local i, j = lo, hi
		while i <= j do
			while a[i] < p do i += 1 end
			while a[j] > p do j -= 1 end
			if i <= j then a[i], a[j] = a[j], a[i]; i += 1; j -= 1 end
		end
		if kth <= j then hi = j elseif kth >= i then lo = i else return a[kth] end
	end
	return a[lo]
end
local function qsFit(): number
	local k = 0
	for i = 1, W - 1 do
		for j = i + 1, W do
			k += 1
			slopes[k] = (ys[j] - ys[i]) / (5 * (j - i))
		end
	end
	local lo = select(slopes, 66, 33)
	-- the 34th smallest is the minimum of the elements after position 33 once 33 is placed
	local hi = math.huge
	for t = 34, 66 do if slopes[t] < hi then hi = slopes[t] end end
	return (lo + hi) / 2
end
-- generated: the 66 slope lines with constant divisors (a build emits these from W = 12 and the 5 s window)
local function genFit(): number
	local y, s = ys, slopes
	s[1] = (y[2] - y[1]) * 0.2; s[2] = (y[3] - y[1]) * 0.1; s[3] = (y[4] - y[1]) * (1 / 15); s[4] = (y[5] - y[1]) * 0.05
	s[5] = (y[6] - y[1]) * 0.04; s[6] = (y[7] - y[1]) * (1 / 30); s[7] = (y[8] - y[1]) * (1 / 35); s[8] = (y[9] - y[1]) * 0.025
	s[9] = (y[10] - y[1]) * (1 / 45); s[10] = (y[11] - y[1]) * 0.02; s[11] = (y[12] - y[1]) * (1 / 55)
	s[12] = (y[3] - y[2]) * 0.2; s[13] = (y[4] - y[2]) * 0.1; s[14] = (y[5] - y[2]) * (1 / 15); s[15] = (y[6] - y[2]) * 0.05
	s[16] = (y[7] - y[2]) * 0.04; s[17] = (y[8] - y[2]) * (1 / 30); s[18] = (y[9] - y[2]) * (1 / 35); s[19] = (y[10] - y[2]) * 0.025
	s[20] = (y[11] - y[2]) * (1 / 45); s[21] = (y[12] - y[2]) * 0.02
	s[22] = (y[4] - y[3]) * 0.2; s[23] = (y[5] - y[3]) * 0.1; s[24] = (y[6] - y[3]) * (1 / 15); s[25] = (y[7] - y[3]) * 0.05
	s[26] = (y[8] - y[3]) * 0.04; s[27] = (y[9] - y[3]) * (1 / 30); s[28] = (y[10] - y[3]) * (1 / 35); s[29] = (y[11] - y[3]) * 0.025
	s[30] = (y[12] - y[3]) * (1 / 45)
	s[31] = (y[5] - y[4]) * 0.2; s[32] = (y[6] - y[4]) * 0.1; s[33] = (y[7] - y[4]) * (1 / 15); s[34] = (y[8] - y[4]) * 0.05
	s[35] = (y[9] - y[4]) * 0.04; s[36] = (y[10] - y[4]) * (1 / 30); s[37] = (y[11] - y[4]) * (1 / 35); s[38] = (y[12] - y[4]) * 0.025
	s[39] = (y[6] - y[5]) * 0.2; s[40] = (y[7] - y[5]) * 0.1; s[41] = (y[8] - y[5]) * (1 / 15); s[42] = (y[9] - y[5]) * 0.05
	s[43] = (y[10] - y[5]) * 0.04; s[44] = (y[11] - y[5]) * (1 / 30); s[45] = (y[12] - y[5]) * (1 / 35)
	s[46] = (y[7] - y[6]) * 0.2; s[47] = (y[8] - y[6]) * 0.1; s[48] = (y[9] - y[6]) * (1 / 15); s[49] = (y[10] - y[6]) * 0.05
	s[50] = (y[11] - y[6]) * 0.04; s[51] = (y[12] - y[6]) * (1 / 30)
	s[52] = (y[8] - y[7]) * 0.2; s[53] = (y[9] - y[7]) * 0.1; s[54] = (y[10] - y[7]) * (1 / 15); s[55] = (y[11] - y[7]) * 0.05
	s[56] = (y[12] - y[7]) * 0.04
	s[57] = (y[9] - y[8]) * 0.2; s[58] = (y[10] - y[8]) * 0.1; s[59] = (y[11] - y[8]) * (1 / 15); s[60] = (y[12] - y[8]) * 0.05
	s[61] = (y[10] - y[9]) * 0.2; s[62] = (y[11] - y[9]) * 0.1; s[63] = (y[12] - y[9]) * (1 / 15)
	s[64] = (y[11] - y[10]) * 0.2; s[65] = (y[12] - y[10]) * 0.1
	s[66] = (y[12] - y[11]) * 0.2
	local lo = select(s, 66, 33)
	local hi = math.huge
	for t = 34, 66 do if s[t] < hi then hi = s[t] end end
	return (lo + hi) / 2
end
for seed = 1, 50 do
	fill(seed)
	local a = sortFit(); fill(seed)
	local b = qsFit(); fill(seed)
	local c = genFit()
	assert(math.abs(a - b) < 1e-15 and math.abs(a - c) < 1e-12, "fits disagree at seed " .. seed)
end
print("check: the three fits agree on 50 inputs")

local mins = table.create(W, math.huge)
local N = 100000
local r = H.compare("one Theil-Sen fit over 12 windows (66 slopes)", N, {
	{ name = "table.sort median", fn = function(n)
		local s = 0
		for i = 1, n do fill(i % 64); s += sortFit() end
		return s
	end },
	{ name = "quickselect median", fn = function(n)
		local s = 0
		for i = 1, n do fill(i % 64); s += qsFit() end
		return s
	end },
	{ name = "generated pairs + quickselect", fn = function(n)
		local s = 0
		for i = 1, n do fill(i % 64); s += genFit() end
		return s
	end },
	{ name = "fill only (input setup)", fn = function(n)
		for i = 1, n do fill(i % 64) end
		return ys[1]
	end },
	{ name = "per-beacon window min update", fn = function(n)
		local s = 0
		for i = 1, n do
			local w = i % W + 1
			local o = (i % 1000) * 0.0001 + 0.05
			if o < mins[w] then mins[w] = o end
			s += mins[w]
		end
		return s
	end },
})
for _, name in { "table.sort median", "quickselect median", "generated pairs + quickselect" } do
	local fit = r[name] - r["fill only (input setup)"]
	print(string.format("%-30s %.0f ns per fit; 100 players at one fit per 5 s: %.1f us/s (%.4f%% of a core)", name, fit, fit * 20 / 1000, fit * 20 / 1e7))
end
print("sink", H.sink)
