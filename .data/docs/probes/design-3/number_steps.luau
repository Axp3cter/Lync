-- Design draft 3: the t.number step-count rule (§3.3) against review-2 n1's failing cases.
-- Rule (v5.md §3.3, draft 3.1): r = (max - min) / step must lie within 1e-9 * max(1, r) of an integer n, else the
-- declaration is refused (numberStep). Encode: q = min(floor((v - min) / step + 0.5), n). Checks every grid point.
-- Also t.angle(step): n = round(2*pi/step) under the same tolerance, else ceil (review-3 m5).
local function steps(min: number, max: number, step: number): number?
	local r = (max - min) / step
	local n = math.round(r)
	return if math.abs(r - n) <= 1e-9 * math.max(1, r) then n else nil
end
local cases = {
	{ -2048, 2048, 0.1 }, { 0, 1, 0.1 }, { 0, 100, 0.01 }, { -1, 1, 0.001 }, { 0, 0.3, 0.1 },
	{ 0, 1, 1 / 3 }, { 0, 0.7, 0.1 }, { 0, 2.3, 0.1 }, { -512, 512, 0.05 }, { 0, 1, 0.3 },
}
for _, c in cases do
	local min, max, step = c[1], c[2], c[3]
	local n = steps(min, max, step)
	if not n then
		print(string.format("t.number(%g, %g, %g): (max - min) / step = %.17g -> numberStep (declaration error)",
			min, max, step, (max - min) / step))
		continue
	end
	local worst = 0
	for i = 0, n do
		local v = math.min(min + i * step, max)
		local q = math.min(math.floor((v - min) / step + 0.5), n)
		worst = math.max(worst, math.abs(min + q * step - v))
	end
	local qmax = math.min(math.floor((max - min) / step + 0.5), n)
	print(string.format("t.number(%g, %g, %g): steps %d, bits %d, q(max) %d, max error at grid points %.3g",
		min, max, step, n, math.ceil(math.log(n + 1, 2)), qmax, worst))
end
for _, c in { { "math.rad(1)", math.rad(1) }, { "2*pi/1000", 2 * math.pi / 1000 }, { "2*pi/256", 2 * math.pi / 256 },
	{ "0.3", 0.3 } } do
	local r = 2 * math.pi / c[2]
	local n = math.round(r)
	if math.abs(r - n) > 1e-9 * math.max(1, r) then
		n = math.ceil(r)
	end
	print(string.format("t.angle(%s): 2pi/step = %.17g -> n = %d", c[1], r, n))
end
