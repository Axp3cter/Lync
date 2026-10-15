--!strict
-- Theil-Sen over 12 window minima spaced 5 s (design/v5-integrity.md §6): the fitted slope when the series holds
-- one level shift of h seconds between window k and k + 1 and no noise. Shows which of the consecutive fits a single
-- step moves, and by how much (slope / h, in 1/s). Run: luau -O2 step_response.luau
local NWIN, WIN = 12, 5
local function theilSen(ys: { number }): number
	local s = {}
	for i = 1, NWIN - 1 do
		for j = i + 1, NWIN do table.insert(s, (ys[j] - ys[i]) / (WIN * (j - i))) end
	end
	table.sort(s)
	return (s[33] + s[34]) / 2
end
print("k  straddling pairs  slope/h (1/s)  step h (s) giving |slope| = 0.01   = 0.0068")
for k = 1, NWIN - 1 do
	local ys = {}
	for i = 1, NWIN do ys[i] = i > k and 1 or 0 end
	local m = theilSen(ys)
	local h1 = m > 0 and string.format("%.3f", 0.01 / m) or "never"
	local h2 = m > 0 and string.format("%.3f", 0.0068 / m) or "never"
	print(string.format("%2d  %16d  %13.5f  %33s  %8s", k, k * (NWIN - k), m, h1, h2))
end
