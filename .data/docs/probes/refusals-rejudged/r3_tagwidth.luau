--!strict
-- R28: keyless acceptance against tag width, frame budgets and the number of tag-input variants per count.
-- candidates/s = v * (R * 5 + U * 3)  (v5.md §4.5: 5 counts per reliable frame, 3 extensions per unreliable frame;
-- v = 1 today, 2 with U7's caller bit, 4 with U7's bit and the identity bit, client-self-checks.md U7).
-- Acceptance is a Poisson process at candidates * 2^-w per second (each candidate independent).
-- M13 chance tagVariant (generation-methods.md M13): failing frames/s * (N - 1) * k * 2^-w, k = 5 reliable, 3 unreliable.
local function fmt(sec: number): string
	if sec < 3600 then return string.format("%.1f s", sec) end
	if sec < 86400 * 2 then return string.format("%.1f h", sec / 3600) end
	if sec < 86400 * 365 * 2 then return string.format("%.1f days", sec / 86400) end
	return string.format("%.2e years", sec / (86400 * 365.25))
end
print(string.format("%-5s %-26s %-3s %12s %16s %14s", "width", "budgets (R, U frames/s)", "v", "cand/s", "per acceptance", "P(>=1 in 24 h)"))
for _, w in { 16, 32, 64 } do
	for _, bud in { { 120, 240, "defaults" }, { 1000, 1000, "range maxima" } } do
		for _, v in { 1, 2, 4 } do
			local cand = v * ((bud[1] :: number) * 5 + (bud[2] :: number) * 3)
			local rate = cand * 2 ^ -w
			print(string.format("%-5d %-26s %-3d %12d %16s %14.3g", w, string.format("%d, %d (%s)", bud[1] :: number, bud[2] :: number, bud[3] :: string),
				v, cand, fmt(1 / rate), 1 - math.exp(-rate * 86400)))
		end
	end
end
print("-- failing tag checks per acceptance (32 bits, defaults, v = 1): frames per acceptance = 2^32 / (1320 / 360)")
print(string.format("   %.3g tagMismatch occurrences per accepted frame", 2 ^ 32 / (1320 / 360)))
print("-- M13 chance tagVariant at the default frame budgets (120 R + 240 U failing frames/s)")
for _, w in { 32, 64 } do
	for _, n in { 2, 16, 64, 256 } do
		local rate = (120 * 5 + 240 * 3) * (n - 1) * 2 ^ -w
		print(string.format("   width %d, N = %3d: one per %s", w, n, fmt(1 / rate)))
	end
end
print("-- upstream framing, busy model (70 frames/s; 374 B/s at 16 bits, v5.md §4.1)")
for _, w in { 16, 32, 64 } do
	print(string.format("   width %d: %d B/s", w, 374 + 70 * (w - 16) // 8))
end
